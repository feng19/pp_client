defmodule PpClientWeb.ServerLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.ProfileManager
  alias PpClient.Redact
  alias PpClient.Schemas.ServerSchema
  alias PpClient.ServerManager

  @secret_keys ~w(password encrypt_key)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "servers")
    end

    socket =
      socket
      |> assign(:page_title, "Servers")
      |> assign(:search_query, "")
      |> assign(:servers_empty?, false)
      |> assign(:form, nil)
      |> assign(:secret_params, %{})
      |> assign(:editing_name, nil)
      |> assign(:delete_name, nil)
      |> stream_configure(:servers, dom_id: fn server -> "server-#{server.name}" end)
      |> load_servers()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Servers")
    |> assign(:form, nil)
    |> assign(:secret_params, %{})
    |> assign(:editing_name, nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = ServerSchema.changeset(%ServerSchema{type: "socks5"})

    socket
    |> assign(:page_title, "New Server")
    |> assign(:form, redacted_form(changeset))
    |> assign(:secret_params, %{})
    |> assign(:editing_name, nil)
  end

  defp apply_action(socket, :edit, %{"name" => name}) do
    case ServerManager.get_server(name) do
      {:ok, server} ->
        schema = ServerSchema.from_proxy_server(server)
        changeset = ServerSchema.changeset(schema)

        socket
        |> assign(:page_title, "Edit Server")
        |> assign(:form, redacted_form(changeset))
        |> assign(:secret_params, secret_params(schema))
        |> assign(:editing_name, server.name)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "No such server")
        |> push_navigate(to: ~p"/admin/servers")
    end
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_servers()

    {:noreply, socket}
  end

  def handle_event("validate", %{"server_schema" => params}, socket) do
    changeset =
      %ServerSchema{}
      |> ServerSchema.changeset(params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:form, redacted_form(changeset))
      |> assign(:secret_params, Redact.form_params(Map.take(params, @secret_keys)))

    {:noreply, socket}
  end

  def handle_event("save", %{"server_schema" => params}, socket) do
    changeset = ServerSchema.changeset(%ServerSchema{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        server = ServerSchema.to_proxy_server(schema)

        case save_server(socket, server) do
          {:ok, _server} ->
            socket =
              socket
              |> put_flash(:info, "Server saved")
              |> push_navigate(to: ~p"/admin/servers")
              |> load_servers()

            {:noreply, socket}

          {:error, :already_exists} ->
            {:noreply, put_flash(socket, :error, "A server with that name already exists")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        socket =
          socket
          |> assign(:form, redacted_form(changeset))
          |> assign(:secret_params, Redact.form_params(Map.take(params, @secret_keys)))

        {:noreply, socket}
    end
  end

  def handle_event("toggle_enable", %{"name" => name}, socket) do
    case ServerManager.get_server(name) do
      {:ok, server} ->
        result =
          if server.enable do
            ServerManager.disable_server(name)
          else
            ServerManager.enable_server(name)
          end

        case result do
          {:ok, updated} ->
            socket =
              socket
              |> put_flash(:info, disable_notice(updated))
              |> load_servers()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such server")}
    end
  end

  def handle_event("delete_confirm", %{"name" => name}, socket) do
    {:noreply, assign(socket, :delete_name, name)}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, :delete_name, nil)}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case ServerManager.delete_server(name) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Server deleted")
          |> assign(:delete_name, nil)
          |> load_servers()

        broadcast_change()
        {:noreply, socket}

      {:error, {:in_use, profiles}} ->
        socket =
          socket
          |> put_flash(
            :error,
            "Still used by #{Enum.join(profiles, ", ")} — remove the reference first"
          )
          |> assign(:delete_name, nil)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:server_updated, _server}, socket) do
    {:noreply, load_servers(socket)}
  end

  # `to_form/1` copies the submitted params onto the form struct, credentials and
  # all, and a LiveView's assigns are written to the log whole when the process
  # crashes. The credential inputs render from `@secret_params` rather than from
  # the form, so nothing reads the copy the form keeps — see `Redact.params/1`.
  defp redacted_form(changeset) do
    form = to_form(changeset)
    %{form | params: Redact.params(form.params)}
  end

  # Disabling is not blocked the way deleting is, but a profile left with no
  # enabled server fails at connect time with nothing on screen to explain it —
  # so say which profiles just lost their last one.
  defp disable_notice(%{enable: false, name: name}) do
    case Enum.filter(ServerManager.references(name), &stranded?/1) do
      [] -> "Status updated"
      profiles -> "Disabled. #{Enum.join(profiles, ", ")} now have no enabled server"
    end
  end

  defp disable_notice(_server), do: "Status updated"

  defp stranded?(profile_name) do
    case ProfileManager.get_profile(profile_name) do
      {:ok, %{type: :remote, servers: servers}} ->
        servers |> ServerManager.fetch_many() |> Enum.all?(&(not &1.enable))

      _other ->
        false
    end
  end

  defp secret_params(%ServerSchema{} = schema) do
    Redact.form_params(%{"password" => schema.password, "encrypt_key" => schema.encrypt_key})
  end

  # The name is the ETS key, so renaming one means dropping the old server and
  # inserting the new one — same as profiles. Every profile pointing at the old
  # name is rewritten to the new one, so a rename never strands a reference.
  defp save_server(socket, server) do
    editing_name = socket.assigns.editing_name

    cond do
      is_nil(editing_name) ->
        insert_server(server)

      editing_name == server.name ->
        server |> ServerManager.update_server() |> broadcast_on_ok()

      ServerManager.exists?(server.name) ->
        {:error, :already_exists}

      true ->
        referring = ServerManager.references(editing_name)

        with {:ok, _server} = result <- insert_server(server) do
          rename_references(referring, editing_name, server.name)
          ServerManager.delete_server(editing_name)
          result
        end
    end
  end

  defp insert_server(server) do
    if ServerManager.exists?(server.name) do
      {:error, :already_exists}
    else
      server |> ServerManager.add_server() |> broadcast_on_ok()
    end
  end

  defp rename_references([], _old_name, _new_name), do: :ok

  defp rename_references(profile_names, old_name, new_name) do
    Enum.each(profile_names, fn profile_name ->
      with {:ok, profile} <- ProfileManager.get_profile(profile_name) do
        servers = Enum.map(profile.servers, &if(&1 == old_name, do: new_name, else: &1))
        ProfileManager.update_profile(%{profile | servers: servers})
      end
    end)

    Phoenix.PubSub.broadcast(PpClient.PubSub, "profiles", {:profile_updated, nil})
  end

  defp broadcast_on_ok({:ok, _server} = result) do
    broadcast_change()
    result
  end

  defp broadcast_on_ok(result), do: result

  # A stream drives the desktop table. The mobile cards render the same servers
  # from a plain assign instead: LiveView binds a stream to one container, so a
  # second `phx-update="stream"` container never receives the reset and keeps
  # showing servers that were filtered out or deleted.
  defp load_servers(socket) do
    servers = ServerManager.all_servers()
    filtered = filter_servers(servers, socket.assigns)

    socket
    |> assign(:servers_empty?, filtered == [])
    |> assign(:servers, filtered)
    |> stream(:servers, filtered, reset: true)
  end

  defp filter_servers(servers, %{search_query: query}) do
    servers
    |> filter_by_search(query)
    |> Enum.sort_by(& &1.name)
  end

  defp filter_by_search(servers, ""), do: servers

  defp filter_by_search(servers, query) do
    query = String.downcase(query)

    Enum.filter(servers, fn server ->
      String.contains?(String.downcase(server.name), query) ||
        String.contains?(server.type, query) ||
        String.contains?(String.downcase(endpoint_label(server)), query)
    end)
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(PpClient.PubSub, "servers", {:server_updated, nil})
  end

  defp type_label("exps"), do: "EXPS"
  defp type_label("cf-workers"), do: "CF Workers"
  defp type_label("socks5"), do: "SOCKS5"
  defp type_label(type), do: to_string(type)

  # The endpoint is the part of a server worth showing in a list; the credential
  # next to it in `opts` is not.
  defp endpoint_label(%{type: "socks5", opts: opts}), do: "#{opts[:host]}:#{opts[:port]}"
  defp endpoint_label(%{opts: opts}), do: to_string(opts[:uri])
end
