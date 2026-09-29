defmodule PpClientWeb.CmdPortLive.Index do
  use PpClientWeb, :live_view

  alias PpClient.CmdPortManager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(PpClient.PubSub, "cmd_ports")
    end

    {:ok,
     socket
     |> assign(:page_title, "Cmd Ports")
     |> load_cmd_ports()}
  end

  @impl true
  def handle_event("stop", %{"name" => name}, socket) do
    {:noreply, run(socket, name, &CmdPortManager.stop/1, "stopped")}
  end

  def handle_event("start", %{"name" => name}, socket) do
    {:noreply, run(socket, name, &CmdPortManager.start/1, "started")}
  end

  def handle_event("restart", %{"name" => name}, socket) do
    {:noreply, run(socket, name, &CmdPortManager.restart/1, "restarted")}
  end

  @impl true
  def handle_info({:cmd_port_updated, _}, socket), do: {:noreply, load_cmd_ports(socket)}

  defp run(socket, name, action, done) do
    socket =
      case action.(name) do
        :ok -> put_flash(socket, :info, "#{name} #{done}")
        {:error, reason} -> put_flash(socket, :error, "#{name}: #{error_text(reason)}")
      end

    load_cmd_ports(socket)
  end

  defp error_text(:not_found), do: "no such command"
  defp error_text(:already_running), do: "already running"
  defp error_text(:executable_not_found), do: "executable not found"

  defp load_cmd_ports(socket) do
    cmd_ports = CmdPortManager.list()

    socket
    |> assign(:cmd_ports, cmd_ports)
    |> assign(:cmd_ports_empty?, cmd_ports == [])
  end

  defp command_line(%{cmd: cmd, args: args}), do: Enum.join([cmd | args], " ")

  defp status_badge(:running), do: {"badge-success", "Running"}
  defp status_badge(:halted), do: {"badge-ghost", "Stopped"}
  defp status_badge(:stopped), do: {"badge-warning", "Restarting"}
end
