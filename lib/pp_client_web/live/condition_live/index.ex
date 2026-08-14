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
      |> assign(:page_title, "Conditions")
      |> assign(:search_query, "")
      |> assign(:filter_status, "all")
      |> assign(:filter_profile, "all")
      |> assign(:conditions_empty?, false)
      |> assign(:editing_id, nil)
      |> assign(:show_new_form, false)
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
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
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

  def handle_event("show_new_form", _params, socket) do
    socket =
      socket
      |> assign(:show_new_form, true)
      |> assign(:editing_id, nil)

    {:noreply, socket}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, :show_new_form, false)}
  end

  def handle_event("save_new", params, socket) do
    condition_params = %{
      "pattern" => params["pattern"],
      "profile_name" => params["profile_name"],
      "enabled" => params["enabled"] == "true"
    }

    changeset = ConditionSchema.changeset(%ConditionSchema{}, condition_params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        condition = ConditionSchema.to_condition(schema)

        case ConditionManager.add_condition(condition) do
          {:ok, _} ->
            # Once created, clear any failure record the new condition covers
            clear_matching_failed_hosts(condition)

            socket =
              socket
              |> put_flash(:info, "Condition created")
              |> assign(:show_new_form, false)
              |> load_conditions()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid input")}
    end
  end

  def handle_event("start_edit", %{"id" => id}, socket) do
    id = String.to_integer(id)

    case ConditionManager.get_condition(id) do
      {:ok, condition} ->
        socket =
          socket
          |> assign(editing_id: id, show_new_form: false)
          |> stream_insert(:conditions, condition)

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "No such condition")}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    case socket.assigns.editing_id do
      nil ->
        {:noreply, socket}

      id ->
        case ConditionManager.get_condition(id) do
          {:ok, condition} ->
            socket =
              socket
              |> assign(:editing_id, nil)
              |> stream_insert(:conditions, condition)

            {:noreply, socket}

          {:error, _} ->
            {:noreply, assign(socket, :editing_id, nil)}
        end
    end
  end

  def handle_event("save_edit", %{"condition_id" => id_str} = params, socket) do
    id = String.to_integer(id_str)

    condition_params = %{
      "pattern" => params["pattern"],
      "profile_name" => params["profile_name"],
      "enabled" => params["enabled"] == "true"
    }

    changeset = ConditionSchema.changeset(%ConditionSchema{}, condition_params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        condition = ConditionSchema.to_condition(schema)
        condition = Map.put(condition, :id, id)

        case ConditionManager.update_condition(condition) do
          {:ok, _} ->
            socket =
              socket
              |> put_flash(:info, "Condition updated")
              |> assign(:editing_id, nil)
              |> load_conditions()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Invalid input")}
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
              |> put_flash(:info, "Status updated")
              |> load_conditions()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such condition")}
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
          |> put_flash(:info, "Condition deleted")
          |> assign(:delete_id, nil)
          |> load_conditions()

        broadcast_change()
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_connect_failed", _params, socket) do
    socket =
      socket
      |> assign(:show_connect_failed, !socket.assigns.show_connect_failed)
      |> load_connect_failed_hosts()

    {:noreply, socket}
  end

  def handle_event(
        "create_from_failed_form",
        %{
          "pattern" => pattern,
          "profile" => profile_name,
          "original-host" => original_host,
          "original-port" => original_port_str
        },
        socket
      ) do
    original_port = String.to_integer(original_port_str)

    # A profile has to be picked
    if profile_name == "" do
      {:noreply, put_flash(socket, :error, "Pick a profile")}
    else
      # Create the condition
      condition = %PpClient.Condition{
        condition: :all,
        profile_name: profile_name,
        enabled: true
      }

      # Try to compile the pattern into a regex
      condition =
        case PpClient.Condition.pattern_to_regex(pattern) do
          {:ok, regex} -> %{condition | condition: regex}
          {:error, _} -> condition
        end

      case ConditionManager.add_condition(condition) do
        {:ok, _} ->
          # Drop that failure record
          ConditionManager.clear_connect_failed(original_host, original_port)

          socket =
            socket
            |> put_flash(:info, "Condition created: #{pattern} → #{profile_name}")
            |> load_conditions()
            |> load_connect_failed_hosts()

          broadcast_change()
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("clear_failed_host", %{"host" => host, "port" => port_str}, socket) do
    port = String.to_integer(port_str)
    ConditionManager.clear_connect_failed(host, port)

    socket =
      socket
      |> put_flash(:info, "Failure record cleared")
      |> load_connect_failed_hosts()

    {:noreply, socket}
  end

  def handle_event("clear_all_failed", _params, socket) do
    # Clear every failure record
    Enum.each(socket.assigns.connect_failed_hosts, fn host ->
      ConditionManager.clear_connect_failed(host.host, host.port)
    end)

    socket =
      socket
      |> put_flash(:info, "All failure records cleared")
      |> load_connect_failed_hosts()

    {:noreply, socket}
  end

  def handle_event("refresh_cache", _params, socket) do
    PpClient.Cache.refresh()

    socket =
      socket
      |> put_flash(:info, "Cache refreshed")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:condition_updated, _condition}, socket) do
    {:noreply, load_conditions(socket)}
  end

  def handle_info({:profile_updated, _profile}, socket) do
    {:noreply, load_profiles(socket)}
  end

  defp clear_matching_failed_hosts(condition) do
    # Every host that failed to connect
    failed_hosts = ConditionManager.get_connect_failed_hosts()

    # Check each failed host against the newly created condition
    Enum.each(failed_hosts, fn host ->
      host_str = to_string(host.host)

      matches =
        case condition.condition do
          :all ->
            true

          %Regex{} = regex ->
            String.match?(host_str, regex)

          _ ->
            false
        end

      if matches do
        ConditionManager.clear_connect_failed(host.host, host.port)
      end
    end)
  end

  # A stream drives the desktop table. The mobile cards render the same
  # conditions from a plain assign instead: LiveView binds a stream to one
  # container, so a second `phx-update="stream"` container never receives the
  # reset and keeps showing conditions that were filtered out or deleted.
  defp load_conditions(socket) do
    conditions = ConditionManager.all_conditions()
    filtered = filter_conditions(conditions, socket.assigns)

    socket
    |> assign(:conditions_empty?, filtered == [])
    |> assign(:conditions, filtered)
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

  defp format_condition(:all), do: "* (matches everything)"

  defp format_condition(%Regex{} = regex) do
    # Use temporary placeholders to turn the regex back into a pattern
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
        "just now"

      diff_seconds < 3600 ->
        minutes = div(diff_seconds, 60)
        "#{minutes}m ago"

      diff_seconds < 86400 ->
        hours = div(diff_seconds, 3600)
        "#{hours}h ago"

      diff_seconds < 604_800 ->
        days = div(diff_seconds, 86400)
        "#{days}d ago"

      true ->
        Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
    end
  end

  defp format_timestamp(_), do: "unknown"
end
