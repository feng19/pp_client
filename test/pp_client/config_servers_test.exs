defmodule PpClient.ConfigServersTest do
  @moduledoc """
  The `servers:` section of the config file, and the references profiles make
  into it.
  """
  use ExUnit.Case, async: false

  alias PpClient.ProfileManager
  alias PpClient.ServerManager

  @moduletag capture_log: true

  setup do
    on_exit(fn ->
      Enum.each(["cfg-profile"], &ProfileManager.delete_profile/1)
      Enum.each(["cfg_exps", "cfg_socks", "cfg_off"], &ServerManager.delete_server/1)
    end)

    :ok
  end

  defp write_config(dir, body) do
    path = Path.join(dir, "pp_servers.exs")
    File.write!(path, body)
    path
  end

  @tag :tmp_dir
  test "the servers: section is keyed by name and loaded at boot", %{tmp_dir: tmp_dir} do
    path =
      write_config(tmp_dir, """
      %{
        servers: [
          cfg_exps: %{
            type: "exps",
            opts: [uri: "wss://cfg.example.com/ws", encrypt_type: :once, encrypt_key: "k"]
          },
          cfg_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1088]},
          cfg_off: %{enable: false, type: "socks5", opts: [host: "127.0.0.1", port: 1089]}
        ]
      }
      """)

    assert %{servers: _} = PpClient.Application.load_config(path)

    assert {:ok, exps} = ServerManager.get_server("cfg_exps")
    assert exps.name == "cfg_exps"
    assert exps.client_type == :ws
    assert exps.opts[:uri] == "wss://cfg.example.com/ws"

    assert {:ok, socks} = ServerManager.get_server("cfg_socks")
    assert socks.client_type == :socks5

    assert {:ok, %{enable: false}} = ServerManager.get_server("cfg_off")
  end

  @tag :tmp_dir
  test "a profile keeps its server references as names", %{tmp_dir: tmp_dir} do
    path =
      write_config(tmp_dir, """
      %{
        servers: [cfg_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1088]}],
        profiles: [%{name: "cfg-profile", type: :remote, servers: [:cfg_socks, :cfg_socks]}]
      }
      """)

    PpClient.Application.load_config(path)

    assert {:ok, profile} = ProfileManager.get_profile("cfg-profile")
    # Deduplicated: a name listed twice would double that server's odds.
    assert profile.servers == ["cfg_socks"]
  end

  @tag :tmp_dir
  test "an unknown reference fails at boot, naming the profile and the reference",
       %{tmp_dir: tmp_dir} do
    path =
      write_config(tmp_dir, """
      %{
        servers: [cfg_socks: %{type: "socks5", opts: [host: "127.0.0.1", port: 1088]}],
        profiles: [%{name: "cfg-profile", type: :remote, servers: [:no_such_server]}]
      }
      """)

    assert_raise RuntimeError, ~r/"cfg-profile".*"no_such_server"/, fn ->
      PpClient.Application.load_config(path)
    end
  end

  @tag :tmp_dir
  test "a config with no servers: section loads fine", %{tmp_dir: tmp_dir} do
    path = write_config(tmp_dir, "%{web: %{server: false}}")

    assert %{web: _} = PpClient.Application.load_config(path)
  end
end
