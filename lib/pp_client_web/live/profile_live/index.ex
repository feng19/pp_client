defmodule PpClientWeb.ProfileLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.ProfileManager
  alias PpClient.Schemas.ProfileSchema
  alias PpClient.ServerManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "profiles")
      # The picker lists the servers, so it has to follow them being added,
      # renamed or removed on the Servers page.
      Phoenix.PubSub.subscribe(PpClient.PubSub, "servers")
    end

    socket =
      socket
      |> assign(:page_title, "Profiles")
      |> assign(:search_query, "")
      |> assign(:profiles_empty?, false)
      |> assign(:form, nil)
      |> assign(:delete_name, nil)
      |> assign(:servers, ServerManager.all_servers())
      |> stream_configure(:profiles, dom_id: fn profile -> "profile-#{profile.name}" end)
      |> load_profiles()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Profiles")
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = ProfileSchema.changeset(%ProfileSchema{}, %{})

    socket
    |> assign(:page_title, "New Profile")
    |> assign(:form, to_form(changeset))
    |> assign(:editing_name, nil)
  end

  defp apply_action(socket, :edit, %{"name" => name}) do
    case ProfileManager.get_profile(name) do
      {:ok, profile} ->
        changeset =
          profile
          |> ProfileSchema.from_profile()
          |> ProfileSchema.changeset(%{})

        socket
        |> assign(:page_title, "Edit Profile")
        |> assign(:form, to_form(changeset))
        |> assign(:editing_name, name)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "No such profile")
        |> push_navigate(to: ~p"/admin/profiles")
    end
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_profiles()

    {:noreply, socket}
  end

  def handle_event("validate", %{"profile_schema" => params}, socket) do
    changeset =
      %ProfileSchema{}
      |> ProfileSchema.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"profile_schema" => params}, socket) do
    # Cast onto an empty schema, never onto the profile being edited: `cast/3`
    # skips keys the params do not carry, so loading the stored servers in first
    # would make clearing the picker silently keep them.
    changeset = ProfileSchema.changeset(%ProfileSchema{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        profile = ProfileSchema.to_profile(schema)

        case save_profile(socket, profile) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Profile saved")
              |> push_navigate(to: ~p"/admin/profiles")
              |> load_profiles()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle_enable", %{"name" => name}, socket) do
    case ProfileManager.get_profile(name) do
      {:ok, profile} ->
        result =
          if profile.enabled do
            ProfileManager.disable_profile(name)
          else
            ProfileManager.enable_profile(name)
          end

        case result do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Status updated")
              |> load_profiles()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such profile")}
    end
  end

  def handle_event("delete_confirm", %{"name" => name}, socket) do
    {:noreply, assign(socket, :delete_name, name)}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, :delete_name, nil)}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case ProfileManager.delete_profile(name) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Profile deleted")
          |> assign(:delete_name, nil)
          |> load_profiles()

        broadcast_change()
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:profile_updated, _profile}, socket) do
    {:noreply, load_profiles(socket)}
  end

  def handle_info({:server_updated, _server}, socket) do
    {:noreply, assign(socket, :servers, ServerManager.all_servers())}
  end

  defp save_profile(socket, profile) do
    editing_name = Map.get(socket.assigns, :editing_name)

    if editing_name do
      # Edit an existing profile
      if editing_name != profile.name && ProfileManager.exists?(profile.name) do
        {:error, :name_already_exists}
      else
        # A changed name means the old profile has to be deleted first
        if editing_name != profile.name do
          ProfileManager.delete_profile(editing_name)
        end

        result = ProfileManager.update_profile(profile)
        broadcast_change()
        result
      end
    else
      # Create a new profile
      if ProfileManager.exists?(profile.name) do
        {:error, :name_already_exists}
      else
        result = ProfileManager.add_profile(profile)
        broadcast_change()
        result
      end
    end
  end

  # A stream drives the desktop table. The mobile cards render the same profiles
  # from a plain assign instead: LiveView binds a stream to one container, so a
  # second `phx-update="stream"` container never receives the reset and keeps
  # showing profiles that were filtered out or deleted.
  defp load_profiles(socket) do
    profiles = ProfileManager.all_profiles()
    filtered = filter_profiles(profiles, socket.assigns)

    socket
    |> assign(:profiles_empty?, filtered == [])
    |> assign(:profiles, filtered)
    |> stream(:profiles, filtered, reset: true)
  end

  defp filter_profiles(profiles, %{search_query: query}) do
    profiles
    |> filter_by_search(query)
    |> Enum.sort_by(& &1.name)
  end

  defp filter_by_search(profiles, ""), do: profiles

  defp filter_by_search(profiles, query) do
    query = String.downcase(query)

    Enum.filter(profiles, fn profile ->
      String.contains?(String.downcase(profile.name), query) ||
        String.contains?(to_string(profile.type), query)
    end)
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(PpClient.PubSub, "profiles", {:profile_updated, nil})
  end

  defp type_label(:direct), do: "Direct"
  defp type_label(:remote), do: "Remote proxy"
  defp type_label(type), do: to_string(type)

  defp server_option(server) do
    label = if server.enable, do: server.name, else: "#{server.name} (disabled)"
    {label, server.name}
  end
end
