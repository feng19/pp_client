defmodule PpClientWeb.ProfileLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.ProfileManager
  alias PpClient.Redact
  alias PpClient.Schemas.ProfileSchema

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "profiles")
    end

    socket =
      socket
      |> assign(:page_title, "Profiles")
      |> assign(:search_query, "")
      |> assign(:profiles_empty?, false)
      |> assign(:form, nil)
      |> assign(:delete_name, nil)
      |> assign(:server_forms, [])
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
    |> assign(:server_forms, [])
  end

  defp apply_action(socket, :new, _params) do
    changeset = ProfileSchema.changeset(%ProfileSchema{}, %{})

    # Start with one server form
    default_server = %{"type" => "socks5", "enable" => true}

    socket
    |> assign(:page_title, "New Profile")
    |> assign(:form, redacted_form(changeset))
    |> assign(:editing_name, nil)
    |> assign(:server_forms, [{0, default_server}])
  end

  defp apply_action(socket, :edit, %{"name" => name}) do
    case ProfileManager.get_profile(name) do
      {:ok, profile} ->
        schema = ProfileSchema.from_profile(profile)
        changeset = ProfileSchema.changeset(schema, %{})

        server_forms =
          if schema.servers do
            Enum.with_index(schema.servers, fn server, idx ->
              # Convert the server map to string keys
              server_data =
                if is_struct(server) do
                  server
                  |> Map.from_struct()
                  |> Enum.map(fn {k, v} -> {to_string(k), v} end)
                  |> Map.new()
                else
                  # Already a plain map, only the keys need stringifying
                  server
                  |> Enum.map(fn {k, v} -> {to_string(k), v} end)
                  |> Map.new()
                end

              {idx, Redact.form_params(server_data)}
            end)
          else
            []
          end

        socket
        |> assign(:page_title, "Edit Profile")
        |> assign(:form, redacted_form(changeset))
        |> assign(:editing_name, name)
        |> assign(:server_forms, server_forms)

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

    # Refresh server_forms so the server type change is reflected
    server_forms =
      case params["servers"] do
        nil ->
          socket.assigns.server_forms

        servers_params when is_map(servers_params) ->
          servers_params
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
          |> Enum.map(fn {idx, server_data} ->
            {String.to_integer(idx), Redact.form_params(server_data)}
          end)
      end

    socket =
      socket
      |> assign(:form, redacted_form(changeset))
      |> assign(:server_forms, server_forms)

    {:noreply, socket}
  end

  def handle_event("save", %{"profile_schema" => params}, socket) do
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
        # Refresh server_forms to keep the form state
        server_forms =
          case params["servers"] do
            nil ->
              []

            servers_params when is_map(servers_params) ->
              servers_params
              |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
              |> Enum.map(fn {idx, server_data} ->
                {String.to_integer(idx), Redact.form_params(server_data)}
              end)
          end

        socket =
          socket
          |> assign(:form, redacted_form(changeset))
          |> assign(:server_forms, server_forms)

        {:noreply, socket}
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

  def handle_event("add_server", _params, socket) do
    server_forms = socket.assigns.server_forms
    new_index = length(server_forms)
    new_server = %{"type" => "socks5", "enable" => true}

    {:noreply, assign(socket, :server_forms, server_forms ++ [{new_index, new_server}])}
  end

  def handle_event("remove_server", %{"index" => index}, socket) do
    index = String.to_integer(index)
    server_forms = Enum.reject(socket.assigns.server_forms, fn {idx, _} -> idx == index end)

    # Re-index the remaining forms
    server_forms =
      server_forms
      |> Enum.with_index(fn {_old_idx, form}, new_idx -> {new_idx, form} end)

    {:noreply, assign(socket, :server_forms, server_forms)}
  end

  @impl true
  def handle_info({:profile_updated, _profile}, socket) do
    {:noreply, load_profiles(socket)}
  end

  # `to_form/1` copies the submitted params onto the form struct, credentials and
  # all, and a LiveView's assigns are written to the log whole when the process
  # crashes. The credential inputs render from `@server_forms` rather than from
  # the form, so nothing reads the copy the form keeps — see `Redact.params/1`.
  defp redacted_form(changeset) do
    form = to_form(changeset)
    %{form | params: Redact.params(form.params)}
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

  defp load_profiles(socket) do
    profiles = ProfileManager.all_profiles()
    filtered = filter_profiles(profiles, socket.assigns)

    socket
    |> assign(:profiles_empty?, filtered == [])
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
end
