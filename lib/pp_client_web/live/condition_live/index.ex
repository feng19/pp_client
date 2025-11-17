defmodule PpClientWeb.ConditionLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.ConditionManager
  alias PpClient.ProfileManager
  alias PpClient.Schemas.ConditionSchema

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "conditions")
      Phoenix.PubSub.subscribe(PpClient.PubSub, "profiles")
    end

    socket =
      socket
      |> assign(:page_title, "Condition 管理")
      |> assign(:search_query, "")
      |> assign(:filter_status, "all")
      |> assign(:filter_profile, "all")
      |> assign(:conditions_empty?, false)
      |> assign(:form, nil)
      |> assign(:delete_id, nil)
      |> assign(:available_profiles, [])
      |> assign(:connect_failed_hosts, [])
      |> assign(:show_connect_failed, false)
      |> stream_configure(:conditions, dom_id: fn condition -> "condition-#{condition.id}" end)
      |> load_conditions()
      |> load_profiles()
      |> load_connect_failed_hosts()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Condition 管理")
    |> assign(:form, nil)
  end

  defp apply_action(socket, :new, _params) do
    default_attrs = %{pattern: "*.example.com"}
    changeset = ConditionSchema.changeset(%ConditionSchema{}, default_attrs)

    socket
    |> assign(:page_title, "新建 Condition")
    |> assign(:form, to_form(changeset))
    |> assign(:editing_id, nil)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    id = String.to_integer(id)

    case ConditionManager.get_condition(id) do
      {:ok, condition} ->
        schema = ConditionSchema.from_condition(condition)
        changeset = ConditionSchema.changeset(schema, %{})

        socket
        |> assign(:page_title, "编辑 Condition")
        |> assign(:form, to_form(changeset))
        |> assign(:editing_id, id)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Condition 不存在")
        |> push_navigate(to: ~p"/admin/conditions")
    end
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_conditions()

    {:noreply, socket}
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    socket =
      socket
      |> assign(:filter_status, status)
      |> load_conditions()

    {:noreply, socket}
  end

  def handle_event("filter_profile", %{"profile" => profile}, socket) do
    socket =
      socket
      |> assign(:filter_profile, profile)
      |> load_conditions()

    {:noreply, socket}
  end

  def handle_event("validate", %{"condition_schema" => params}, socket) do
    changeset =
      %ConditionSchema{}
      |> ConditionSchema.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"condition_schema" => params}, socket) do
    changeset = ConditionSchema.changeset(%ConditionSchema{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        condition = ConditionSchema.to_condition(schema)

        case save_condition(socket, condition) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Condition 保存成功")
              |> push_navigate(to: ~p"/admin/conditions")
              |> load_conditions()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "保存失败: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("toggle_enable", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case ConditionManager.get_condition(id) do
      {:ok, condition} ->
        result =
          if condition.enabled do
            ConditionManager.disable_condition(id)
          else
            ConditionManager.enable_condition(id)
          end

        case result do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "状态已更新")
              |> load_conditions()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "操作失败: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Condition 不存在")}
    end
  end

  def handle_event("delete_confirm", %{"id" => id}, socket) do
    {:noreply, assign(socket, :delete_id, String.to_integer(id))}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, :delete_id, nil)}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case ConditionManager.delete_condition(id) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Condition 已删除")
          |> assign(:delete_id, nil)
          |> load_conditions()

        broadcast_change()
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "删除失败: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_connect_failed", _params, socket) do
    socket =
      socket
      |> assign(:show_connect_failed, !socket.assigns.show_connect_failed)
      |> load_connect_failed_hosts()

    {:noreply, socket}
  end

  def handle_event("create_from_failed", %{"host" => host, "port" => port_str}, socket) do
    port = String.to_integer(port_str)
    host_str = to_string(host)

    # 创建匹配模式，使用主机名
    pattern = "*.#{host_str}"

    # 获取第一个可用的 profile，如果没有则提示用户
    case socket.assigns.available_profiles do
      [] ->
        {:noreply, put_flash(socket, :error, "请先创建至少一个 Profile")}

      [first_profile | _] ->
        # 创建 condition
        condition = %PpClient.Condition{
          condition: :all,
          profile_name: first_profile,
          enabled: true
        }

        # 尝试将 pattern 转换为 regex
        condition =
          case PpClient.Condition.pattern_to_regex(pattern) do
            {:ok, regex} -> %{condition | condition: regex}
            {:error, _} -> condition
          end

        case ConditionManager.add_condition(condition) do
          {:ok, _} ->
            # 清除该失败记录
            ConditionManager.clear_connect_failed(host, port)

            socket =
              socket
              |> put_flash(:info, "已从 #{host_str}:#{port} 创建 Condition")
              |> load_conditions()
              |> load_connect_failed_hosts()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "创建失败: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("clear_failed_host", %{"host" => host, "port" => port_str}, socket) do
    port = String.to_integer(port_str)
    ConditionManager.clear_connect_failed(host, port)

    socket =
      socket
      |> put_flash(:info, "已清除失败记录")
      |> load_connect_failed_hosts()

    {:noreply, socket}
  end

  def handle_event("clear_all_failed", _params, socket) do
    # 清除所有失败记录
    Enum.each(socket.assigns.connect_failed_hosts, fn host ->
      ConditionManager.clear_connect_failed(host.host, host.port)
    end)

    socket =
      socket
      |> put_flash(:info, "已清除所有失败记录")
      |> load_connect_failed_hosts()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:condition_updated, _condition}, socket) do
    {:noreply, load_conditions(socket)}
  end

  def handle_info({:profile_updated, _profile}, socket) do
    {:noreply, load_profiles(socket)}
  end

  defp save_condition(socket, condition) do
    editing_id = Map.get(socket.assigns, :editing_id)

    if editing_id do
      # 编辑现有 condition
      condition = Map.put(condition, :id, editing_id)
      result = ConditionManager.update_condition(condition)
      broadcast_change()
      result
    else
      # 创建新 condition
      result = ConditionManager.add_condition(condition)
      broadcast_change()
      result
    end
  end

  defp load_conditions(socket) do
    conditions = ConditionManager.all_conditions()
    filtered = filter_conditions(conditions, socket.assigns)

    socket
    |> assign(:conditions_empty?, filtered == [])
    |> stream(:conditions, filtered, reset: true)
  end

  defp load_profiles(socket) do
    profiles = ProfileManager.all_profiles()
    profile_names = Enum.map(profiles, & &1.name)

    assign(socket, :available_profiles, profile_names)
  end

  defp load_connect_failed_hosts(socket) do
    hosts = ConditionManager.get_connect_failed_hosts()
    assign(socket, :connect_failed_hosts, hosts)
  end

  defp filter_conditions(conditions, assigns) do
    conditions
    |> filter_by_search(assigns.search_query)
    |> filter_by_status(assigns.filter_status)
    |> filter_by_profile(assigns.filter_profile)
    |> Enum.sort_by(& &1.id)
  end

  defp filter_by_search(conditions, ""), do: conditions

  defp filter_by_search(conditions, query) do
    query = String.downcase(query)

    Enum.filter(conditions, fn condition ->
      pattern_str =
        case condition.condition do
          :all -> "*"
          %Regex{source: source} -> source
        end

      String.contains?(String.downcase(pattern_str), query) ||
        String.contains?(String.downcase(condition.profile_name), query)
    end)
  end

  defp filter_by_status(conditions, "all"), do: conditions
  defp filter_by_status(conditions, "enabled"), do: Enum.filter(conditions, & &1.enabled)
  defp filter_by_status(conditions, "disabled"), do: Enum.filter(conditions, &(!&1.enabled))

  defp filter_by_profile(conditions, "all"), do: conditions

  defp filter_by_profile(conditions, profile_name) do
    Enum.filter(conditions, &(&1.profile_name == profile_name))
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(PpClient.PubSub, "conditions", {:condition_updated, nil})
  end

  defp format_condition(:all), do: "* (匹配所有)"

  defp format_condition(%Regex{} = regex) do
    # 使用临时占位符来正确转换 regex 回 pattern
    regex.source
    |> String.trim_leading("^")
    |> String.trim_trailing("$")
    |> String.replace("\\.", "<<<DOT>>>")
    |> String.replace(".*", "*")
    |> String.replace(".", "?")
    |> String.replace("<<<DOT>>>", ".")
    |> String.slice(0, 50)
  end

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    datetime = DateTime.from_unix!(timestamp)
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)

    cond do
      diff_seconds < 60 ->
        "刚刚"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes} 分钟前"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours} 小时前"

      diff_seconds < 604_800 ->
        days = div(diff_seconds, 86400)
        "#{days} 天前"

      true ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
    end
  end

  defp format_timestamp(_), do: "未知"
end
