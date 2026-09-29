defmodule PpClientWeb.CmdPortLiveTest do
  use PpClientWeb.ConnCase

  import Phoenix.LiveViewTest

  alias PpClient.CmdPortManager

  @moduletag capture_log: true

  setup do
    :ok = CmdPortManager.reload([%{name: "sleeper", cmd: "sleep", args: ["300"]}])
    on_exit(fn -> CmdPortManager.reload([]) end)
  end

  test "lists the commands", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/cmd_ports")

    assert has_element?(view, "#cmd-port-sleeper")
    assert has_element?(view, "#stop-sleeper")
  end

  test "stops, starts and restarts a command", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/cmd_ports")
    [%{os_pid: pid}] = CmdPortManager.list()

    view |> element("#stop-sleeper") |> render_click()
    assert [%{status: :halted}] = CmdPortManager.list()
    assert has_element?(view, "#start-sleeper")
    refute has_element?(view, "#stop-sleeper")

    view |> element("#start-sleeper") |> render_click()
    assert [%{status: :running, os_pid: started}] = CmdPortManager.list()
    assert started != pid

    view |> element("#restart-sleeper") |> render_click()
    assert [%{status: :running, os_pid: restarted}] = CmdPortManager.list()
    assert restarted != started
  end

  test "a stopped command is not restarted by itself" do
    :ok = CmdPortManager.stop("sleeper")
    Process.sleep(2_500)
    assert [%{status: :halted}] = CmdPortManager.list()
  end

  test "an unknown name is an error" do
    assert {:error, :not_found} = CmdPortManager.stop("nope")
  end
end
