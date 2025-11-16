defmodule PpClientWeb.ProfileLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.ProfileManager
  alias PpClient.Schemas.ProfileSchema

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "profiles")
    end

    socket =
      socket
      |> assign(:page_title, "Profile 管理")
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
    |> assign(:page_title, "Profile 管理")
    |> assign(:form, nil)
    |> assign(:server_forms, [])
  end

  defp apply_action(socket, :new, _params) do
    changeset = ProfileSchema.changeset(%ProfileSchema{}, %{})

    socket
    |> assign(:page_title, "新建 Profile")
    |> assign(:form, to_form(changeset))
    |> assign(:editing_name, nil)
    |> assign(:server_forms, [])
  end

  defp apply_action(socket, :edit, %{"name" => name}) do
    case ProfileManager.get_profile(name) do
      {:ok, profile} ->
        schema = ProfileSchema.from_profile(profile)
        changeset = ProfileSchema.changeset(schema, %{})

        server_forms =
          if schema.servers do
            Enum.with_index(schema.servers, fn server, idx ->
              # 将 server map 转换为字符串键的格式
              server_data =
                if is_struct(server) do
                  server
                  |> Map.from_struct()
                  |> Enum.map(fn {k, v} -> {to_string(k), v} end)
                  |> Map.new()
                else
                  # 已经是普通 map，只需转换键为字符串
                  server
                  |> Enum.map(fn {k, v} -> {to_string(k), v} end)
                  |> Map.new()
                end

              {idx, server_data}
            end)
          else
            []
          end

        socket
        |> assign(:page_title, "编辑 Profile")
        |> assign(:form, to_form(changeset))
        |> assign(:editing_name, name)
        |> assign(:server_forms, server_forms)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Profile 不存在")
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

    # 更新 server_forms 以反映服务器类型的变化
    server_forms =
      case params["servers"] do
        nil ->
          socket.assigns.server_forms

        servers_params when is_map(servers_params) ->
          servers_params
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
          |> Enum.map(fn {idx, server_data} ->
            {String.to_integer(idx), server_data}
          end)
      end

    socket =
      socket
      |> assign(:form, to_form(changeset))
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
              |> put_flash(:info, "Profile 保存成功")
              |> push_navigate(to: ~p"/admin/profiles")
              |> load_profiles()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
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
              |> put_flash(:info, "状态已更新")
              |> load_profiles()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "操作失败: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Profile 不存在")}
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
          |> put_flash(:info, "Profile 已删除")
          |> assign(:delete_name, nil)
          |> load_profiles()

        broadcast_change()
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "删除失败: #{inspect(reason)}")}
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

  defp save_profile(socket, profile) do
    editing_name = Map.get(socket.assigns, :editing_name)

    if editing_name do
      # 编辑现有 profile
      if editing_name != profile.name && ProfileManager.exists?(profile.name) do
        {:error, :name_already_exists}
      else
        # 如果名称改变了，需要先删除旧的
        if editing_name != profile.name do
          ProfileManager.delete_profile(editing_name)
        end

        result = ProfileManager.update_profile(profile)
        broadcast_change()
        result
      end
    else
      # 创建新 profile
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

  defp type_label(:direct), do: "直连"
  defp type_label(:remote), do: "远程代理"
  defp type_label(type), do: to_string(type)
end
