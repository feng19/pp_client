defmodule PpClientWeb.EndpointLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.EndpointManager
  alias PpClient.ProfileManager
  alias PpClient.Schemas.EndpointSchema

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "endpoints")
    end

    socket =
      socket
      |> assign(:page_title, "Endpoints")
      |> assign(:search_query, "")
      |> assign(:filter_status, "all")
      |> assign(:endpoints_empty?, false)
      |> assign(:editing_port, nil)
      |> assign(:delete_port, nil)
      |> assign(:show_new_form, false)
      |> assign(:profiles, ProfileManager.all_profiles())
      |> stream_configure(:endpoints, dom_id: fn endpoint -> "endpoint-#{endpoint.port}" end)
      |> load_endpoints()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_endpoints()

    {:noreply, socket}
  end

  def handle_event("filter", %{"status" => status}, socket) do
    socket =
      socket
      |> assign(:filter_status, status)
      |> load_endpoints()

    {:noreply, socket}
  end

  def handle_event("show_new_form", _params, socket) do
    socket =
      socket
      |> assign(:show_new_form, true)
      |> assign(:editing_port, nil)

    {:noreply, socket}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, :show_new_form, false)}
  end

  def handle_event("save_new", params, socket) do
    # Build the params
    endpoint_params = %{
      "port" => params["port"],
      "type" => params["type"],
      "ip" => params["ip"],
      "enable" => params["enable"] == "true",
      "profile" => params["profile"]
    }

    changeset = EndpointSchema.changeset(%EndpointSchema{}, endpoint_params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        endpoint = EndpointSchema.to_endpoint(schema)

        case save_new_endpoint(endpoint) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Endpoint created")
              |> assign(:show_new_form, false)
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, :port_already_exists} ->
            socket =
              socket
              |> put_flash(:error, "Port already in use")

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid input")}
    end
  end

  def handle_event("start_edit", %{"port" => port}, socket) do
    port = String.to_integer(port)

    # Fetch the endpoint and re-insert it into the stream to force a re-render
    case EndpointManager.get_endpoint(port) do
      {:ok, endpoint} ->
        socket =
          socket
          |> assign(editing_port: port, show_new_form: false)
          |> stream_insert(:endpoints, endpoint)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No such endpoint")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    # Fetch the endpoint being edited and re-insert it into the stream to force a re-render
    case socket.assigns.editing_port do
      nil ->
        {:noreply, socket}

      port ->
        case EndpointManager.get_endpoint(port) do
          {:ok, endpoint} ->
            socket =
              socket
              |> assign(:editing_port, nil)
              |> stream_insert(:endpoints, endpoint)

            {:noreply, socket}

          {:error, _} ->
            {:noreply, assign(socket, :editing_port, nil)}
        end
    end
  end

  def handle_event("save_edit", %{"port" => port_str} = params, socket) do
    original_port = String.to_integer(port_str)

    # Build the params
    endpoint_params = %{
      "port" => params["new_port"],
      "type" => params["type"],
      "ip" => params["ip"],
      "enable" => params["enable"] == "true",
      "profile" => params["profile"]
    }

    changeset = EndpointSchema.changeset(%EndpointSchema{}, endpoint_params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        endpoint = EndpointSchema.to_endpoint(schema)

        case save_endpoint_edit(original_port, endpoint) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Endpoint updated")
              |> assign(:editing_port, nil)
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, :port_already_exists} ->
            socket =
              socket
              |> put_flash(:error, "Port already in use")

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid input")}
    end
  end

  def handle_event("toggle_enable", %{"port" => port}, socket) do
    port = String.to_integer(port)

    case EndpointManager.get_endpoint(port) do
      {:ok, endpoint} ->
        updated_endpoint = %{endpoint | enable: !endpoint.enable}

        if updated_endpoint.enable do
          EndpointManager.enable(updated_endpoint)
        else
          EndpointManager.disable(endpoint)
        end
        |> case do
          :ok ->
            socket =
              socket
              |> put_flash(:info, "Status updated")
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such endpoint")}
    end
  end

  def handle_event("restart", %{"port" => port}, socket) do
    port = String.to_integer(port)

    case EndpointManager.get_endpoint(port) do
      {:ok, endpoint} ->
        case EndpointManager.restart(endpoint) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Endpoint restarted")
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Restart failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such endpoint")}
    end
  end

  def handle_event("delete_confirm", %{"port" => port}, socket) do
    {:noreply, assign(socket, :delete_port, String.to_integer(port))}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, :delete_port, nil)}
  end

  def handle_event("delete", %{"port" => port}, socket) do
    port = String.to_integer(port)

    case EndpointManager.get_endpoint(port) do
      {:ok, endpoint} ->
        case EndpointManager.stop(endpoint) do
          :ok ->
            :ets.delete(:endpoints, port)

            socket =
              socket
              |> put_flash(:info, "Endpoint deleted")
              |> assign(:delete_port, nil)
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such endpoint")}
    end
  end

  @impl true
  def handle_info({:endpoint_updated, _endpoint}, socket) do
    {:noreply, load_endpoints(socket)}
  end

  defp save_new_endpoint(endpoint) do
    # Create a new endpoint
    if EndpointManager.exists?(endpoint.port) do
      {:error, :port_already_exists}
    else
      result =
        if endpoint.enable do
          EndpointManager.start(endpoint)
        else
          :ets.insert(:endpoints, {endpoint.port, endpoint})
          {:ok, nil}
        end

      result
    end
  end

  defp save_endpoint_edit(original_port, endpoint) do
    # Edit an existing endpoint
    case EndpointManager.get_endpoint(original_port) do
      {:ok, old_endpoint} ->
        # A changed port means the old listener has to be stopped first
        if old_endpoint.port != endpoint.port do
          # Make sure the new port is free
          if EndpointManager.exists?(endpoint.port) do
            {:error, :port_already_exists}
          else
            EndpointManager.stop(old_endpoint)
            :ets.delete(:endpoints, old_endpoint.port)

            result =
              if endpoint.enable do
                EndpointManager.start(endpoint)
              else
                :ets.insert(:endpoints, {endpoint.port, endpoint})
                {:ok, nil}
              end

            result
          end
        else
          EndpointManager.stop(old_endpoint)

          result =
            if endpoint.enable do
              EndpointManager.start(endpoint)
            else
              :ets.insert(:endpoints, {endpoint.port, endpoint})
              {:ok, nil}
            end

          result
        end

      {:error, _} = error ->
        error
    end
  end

  defp load_endpoints(socket) do
    endpoints = EndpointManager.all_endpoints()
    filtered = filter_endpoints(endpoints, socket.assigns)

    socket
    |> assign(:endpoints_empty?, filtered == [])
    |> stream(:endpoints, filtered, reset: true)
  end

  defp filter_endpoints(endpoints, %{search_query: query, filter_status: status}) do
    endpoints
    |> filter_by_search(query)
    |> filter_by_status(status)
    |> Enum.sort_by(& &1.port)
  end

  defp filter_by_search(endpoints, ""), do: endpoints

  defp filter_by_search(endpoints, query) do
    query = String.downcase(query)

    Enum.filter(endpoints, fn endpoint ->
      String.contains?(to_string(endpoint.port), query) ||
        String.contains?(to_string(endpoint.type), query)
    end)
  end

  defp filter_by_status(endpoints, "all"), do: endpoints
  defp filter_by_status(endpoints, "enabled"), do: Enum.filter(endpoints, & &1.enable)
  defp filter_by_status(endpoints, "disabled"), do: Enum.filter(endpoints, &(!&1.enable))

  defp broadcast_change do
    Phoenix.PubSub.broadcast(PpClient.PubSub, "endpoints", {:endpoint_updated, nil})
  end

  defp format_ip(ip) when is_tuple(ip) do
    ip
    |> Tuple.to_list()
    |> Enum.join(".")
  end

  defp format_ip(ip), do: to_string(ip)

  defp type_label(:socks5), do: "SOCKS5"
  defp type_label(:http), do: "HTTP"
  defp type_label(:auto), do: "Auto-detect"
  defp type_label(:http_to_socks5), do: "HTTP → SOCKS5"
  defp type_label(type), do: to_string(type)

  defp running?(endpoint), do: EndpointManager.running?(endpoint)
end
