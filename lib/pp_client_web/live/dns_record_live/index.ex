defmodule PpClientWeb.DnsRecordLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.DnsRecord
  alias PpClient.DnsRecordManager
  alias PpClient.Schemas.DnsRecordSchema

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "dns_records")
    end

    socket =
      socket
      |> assign(:page_title, "DNS Records")
      |> assign(:search_query, "")
      |> assign(:records_empty?, false)
      |> assign(:form, nil)
      |> assign(:editing_domain, nil)
      |> assign(:delete_domain, nil)
      |> stream_configure(:dns_records, dom_id: fn record -> "dns-#{record.domain}" end)
      |> load_records()

    {:ok, socket}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    socket =
      socket
      |> assign(:search_query, query)
      |> load_records()

    {:noreply, socket}
  end

  def handle_event("new", _params, socket) do
    changeset = DnsRecordSchema.changeset(%DnsRecordSchema{})

    socket =
      socket
      |> assign(:form, to_form(changeset))
      |> assign(:editing_domain, nil)

    {:noreply, socket}
  end

  def handle_event("edit", %{"domain" => domain}, socket) do
    case DnsRecordManager.get_record(domain) do
      {:ok, record} ->
        changeset =
          record
          |> DnsRecordSchema.from_dns_record()
          |> DnsRecordSchema.changeset()

        socket =
          socket
          |> assign(:form, to_form(changeset))
          |> assign(:editing_domain, record.domain)

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such DNS record")}
    end
  end

  def handle_event("cancel", _params, socket) do
    socket =
      socket
      |> assign(:form, nil)
      |> assign(:editing_domain, nil)

    {:noreply, socket}
  end

  def handle_event("validate", %{"dns_record_schema" => params}, socket) do
    changeset =
      %DnsRecordSchema{}
      |> DnsRecordSchema.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"dns_record_schema" => params}, socket) do
    changeset = DnsRecordSchema.changeset(%DnsRecordSchema{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, schema} ->
        record = DnsRecordSchema.to_dns_record(schema)

        case save_record(socket, record) do
          {:ok, _record} ->
            socket =
              socket
              |> put_flash(:info, "DNS record saved")
              |> assign(:form, nil)
              |> assign(:editing_domain, nil)
              |> load_records()

            {:noreply, socket}

          {:error, :already_exists} ->
            {:noreply, put_flash(socket, :error, "A record for that domain already exists")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Save failed: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle_enable", %{"domain" => domain}, socket) do
    case DnsRecordManager.get_record(domain) do
      {:ok, record} ->
        result =
          if record.enable do
            DnsRecordManager.disable_record(domain)
          else
            DnsRecordManager.enable_record(domain)
          end

        case result do
          {:ok, _record} ->
            socket =
              socket
              |> put_flash(:info, "Status updated")
              |> load_records()

            broadcast_change()
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Action failed: #{inspect(reason)}")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such DNS record")}
    end
  end

  def handle_event("delete_confirm", %{"domain" => domain}, socket) do
    {:noreply, assign(socket, :delete_domain, domain)}
  end

  def handle_event("delete_cancel", _params, socket) do
    {:noreply, assign(socket, :delete_domain, nil)}
  end

  def handle_event("delete", %{"domain" => domain}, socket) do
    case DnsRecordManager.delete_record(domain) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "DNS record deleted")
          |> assign(:delete_domain, nil)
          |> load_records()

        broadcast_change()
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:dns_record_updated, _record}, socket) do
    {:noreply, load_records(socket)}
  end

  # The domain is the ETS key, so renaming one means dropping the old record and
  # inserting the new one — same as profiles.
  defp save_record(socket, record) do
    editing_domain = socket.assigns.editing_domain

    cond do
      is_nil(editing_domain) ->
        insert_record(record)

      editing_domain == record.domain ->
        record |> DnsRecordManager.update_record() |> broadcast_on_ok()

      DnsRecordManager.exists?(record.domain) ->
        {:error, :already_exists}

      true ->
        DnsRecordManager.delete_record(editing_domain)
        insert_record(record)
    end
  end

  defp insert_record(record) do
    if DnsRecordManager.exists?(record.domain) do
      {:error, :already_exists}
    else
      record |> DnsRecordManager.add_record() |> broadcast_on_ok()
    end
  end

  defp broadcast_on_ok({:ok, _record} = result) do
    broadcast_change()
    result
  end

  defp broadcast_on_ok(result), do: result

  # A stream drives the desktop table. The mobile cards render the same records
  # from a plain assign instead: LiveView binds a stream to one container, so a
  # second `phx-update="stream"` container never receives the reset and keeps
  # showing records that were filtered out or deleted.
  defp load_records(socket) do
    records = DnsRecordManager.all_records()
    filtered = filter_records(records, socket.assigns)

    socket
    |> assign(:records_empty?, filtered == [])
    |> assign(:records, filtered)
    |> stream(:dns_records, filtered, reset: true)
  end

  defp filter_records(records, %{search_query: query}) do
    records
    |> filter_by_search(query)
    |> Enum.sort_by(& &1.domain)
  end

  defp filter_by_search(records, ""), do: records

  defp filter_by_search(records, query) do
    query = String.downcase(query)

    Enum.filter(records, fn record ->
      String.contains?(record.domain, query) ||
        String.contains?(format_ip(record), query)
    end)
  end

  defp broadcast_change do
    Phoenix.PubSub.broadcast(PpClient.PubSub, "dns_records", {:dns_record_updated, nil})
  end

  defp format_ip(%DnsRecord{ip: ip}), do: DnsRecord.format_ip(ip)
end
