defmodule PpClientWeb.EndpointLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.EndpointManager
  alias PpClient.Schemas.EndpointSchema

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "endpoints")
    end

    socket =
      socket
      |> assign(:page_title, "Endpoint 管理")
      |> assign(:search_query, "")
      |> assign(:filter_status, "all")
      |> assign(:endpoints_empty?, false)
      |> assign(:form, nil)
      |> assign(:delete_port, nil)
      |> stream_configure(:endpoints, dom_id: fn endpoint -> "endpoint-#{endpoint.port}" end)
      |> load_endpoints()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Endpoint 管理")
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    changeset = EndpointSchema.changeset(%EndpointSchema{}, %{})

    socket
    |> assign(:page_title, "新建 Endpoint")
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :edit, %{"port" => port}) do
    port = String.to_integer(port)

    case EndpointManager.get_endpoint(port) do
      {:ok, endpoint} ->
        schema = EndpointSchema.from_endpoint(endpoint)
        changeset = EndpointSchema.changeset(schema, %{})

        socket
        |> assign(:page_title, "编辑 Endpoint")
        |> assign(:form, to_form(changeset))
        |> assign(:editing_port, port)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Endpoint 不存在")
        |> push_navigate(to: ~p"/admin/endpoints")
    end
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

  def handle_event("validate", %{"endpoint_schema" => params}, socket) do
    changeset =
      %EndpointSchema{}
      |> EndpointSchema.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"endpoint_schema" => params}, socket) do
    changeset = EndpointSchema.changeset(%EndpointSchema{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        endpoint = EndpointSchema.to_endpoint(schema)

        case save_endpoint(socket, endpoint) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Endpoint 保存成功")
              |> push_navigate(to: ~p"/admin/endpoints")
              |> load_endpoints()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
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
              |> put_flash(:info, "状态已更新")
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "操作失败: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Endpoint 不存在")}
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
              |> put_flash(:info, "Endpoint 已重启")
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "重启失败: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Endpoint 不存在")}
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
              |> put_flash(:info, "Endpoint 已删除")
              |> assign(:delete_port, nil)
              |> load_endpoints()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "删除失败: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Endpoint 不存在")}
    end
  end

  @impl true
  def handle_info({:endpoint_updated, _endpoint}, socket) do
    {:noreply, load_endpoints(socket)}
  end

  defp save_endpoint(socket, endpoint) do
    editing_port = Map.get(socket.assigns, :editing_port)

    if editing_port do
      # 编辑现有 endpoint
      case EndpointManager.get_endpoint(editing_port) do
        {:ok, old_endpoint} ->
          # 如果端口改变了，需要先停止旧的
          if old_endpoint.port != endpoint.port do
            EndpointManager.stop(old_endpoint)
            :ets.delete(:endpoints, old_endpoint.port)
          else
            EndpointManager.stop(old_endpoint)
          end

          result =
            if endpoint.enable do
              EndpointManager.start(endpoint)
            else
              :ets.insert(:endpoints, {endpoint.port, endpoint})
              {:ok, nil}
            end

          broadcast_change()
          result

        {:error, _} = error ->
          error
      end
    else
      # 创建新 endpoint
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

        broadcast_change()
        result
      end
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
  defp type_label(:auto), do: "自动检测"
  defp type_label(:http_to_socks5), do: "HTTP → SOCKS5"
  defp type_label(type), do: to_string(type)

  defp running?(endpoint), do: EndpointManager.running?(endpoint)
end
