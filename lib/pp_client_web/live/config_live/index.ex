defmodule PpClientWeb.ConfigLive.Index do
  @moduledoc """
  The config file page: import a `pp.exs`, or see what one exported now would say.

  Everything the other admin pages edit lives in ETS and is gone at the next
  boot, so this is where a session's work is made durable — and the only page
  that writes every table at once.

  The preview is redacted and the download is not. Nothing on this page holds a
  credential: the uploaded file is read, applied and dropped inside the one
  event, and the copy with the real values is built per request by
  `PpClientWeb.ConfigController`. Assigns are written to the log whole when a
  LiveView crashes, and a whole configuration is a lot to leak.
  """
  use PpClientWeb, :live_view

  alias PpClient.Config

  @topics ~w(endpoints servers profiles conditions dns_records)
  @updates [
    :endpoint_updated,
    :server_updated,
    :profile_updated,
    :condition_updated,
    :dns_record_updated
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Enum.each(@topics, &Phoenix.PubSub.subscribe(PpClient.PubSub, &1))
    end

    socket =
      socket
      |> assign(:page_title, "Config File")
      |> assign(:import_error, nil)
      # `accept: :any` because `allow_upload/3` only takes extensions it has a
      # MIME type for and `.exs` has none. Nothing is lost: what makes a file
      # importable is that it evaluates to a configuration, which is checked on
      # the way in and reported in full when it does not.
      |> allow_upload(:config, accept: :any, max_entries: 1, max_file_size: 1_000_000)
      |> load_preview()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, assign(socket, :import_error, nil)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :config, ref)}
  end

  def handle_event("import", _params, socket) do
    uploaded =
      consume_uploaded_entries(socket, :config, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end)

    case uploaded do
      [source] -> {:noreply, import_source(socket, source)}
      [] -> {:noreply, put_flash(socket, :error, "Choose a pp.exs to import first")}
    end
  end

  @impl true
  def handle_info({update, _payload}, socket) when update in @updates do
    {:noreply, load_preview(socket)}
  end

  defp import_source(socket, source) do
    with {:ok, config} <- Config.eval_string(source),
         {:ok, summary} <- Config.replace(config) do
      {kind, message} = summarize(summary)

      socket
      |> assign(:import_error, nil)
      |> put_flash(kind, message)
      |> load_preview()
    else
      # Shown on the page rather than in a flash: what comes back from a config
      # file that does not hold up is a compile message naming a line, too long
      # and too useful to read out of a toast that fades.
      {:error, message} -> assign(socket, :import_error, message)
    end
  end

  defp summarize(summary) do
    counts =
      "#{summary.endpoints} endpoints, #{summary.servers} servers, #{summary.profiles} profiles, " <>
        "#{summary.conditions} conditions, #{summary.dns} DNS records"

    case summary.failed_endpoints do
      [] ->
        {:info, "Imported #{counts}"}

      failed ->
        ports = Enum.map_join(failed, ", ", fn {port, reason} -> "#{port} (#{reason})" end)
        {:error, "Imported #{counts}, but these ports would not bind: #{ports}"}
    end
  end

  defp load_preview(socket), do: assign(socket, :preview, Config.dump(redact: true))

  defp upload_error_message(:too_large), do: "That file is too large"
  defp upload_error_message(:too_many_files), do: "One file at a time"
  defp upload_error_message(error), do: "Upload failed: #{error}"
end
