defmodule PpClient do
  import Record
  defrecord(:zip_file, extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  @app_version Mix.Project.config()[:version]

  @priv_subpath "pp_client/priv"
  @in_archive_priv_path String.to_charlist(@priv_subpath)

  def app_version(), do: @app_version

  def main(_) do
    {:ok, _} = Application.ensure_all_started(:elixir)
    extract_priv!()
    cleanup_stale_data()

    start()
    IO.puts("PP(#{@app_version}) Client started.")

    receive do
      :stop -> :stop
    end
  end

  def start, do: Application.ensure_all_started(:pp_client)
  def stop, do: System.halt(0)

  defp extract_priv!() do
    archive_dir = archive_dir()
    extracted_path = extracted_path()

    # In dev we want to extract fresh directory on every boot
    if app_version() =~ "-dev" do
      File.rm_rf!(archive_dir)
    end

    # The extracted archive may be gone, or half gone: a cleaner can take the
    # files and leave the directories, or the other way round. Neither the marker
    # nor the priv directory alone is enough to tell, so we check both.
    if not priv_extracted?() do
      {:ok, sections} = :escript.extract(:escript.script_name(), [])
      archive = Keyword.fetch!(sections, :archive)

      file_filter = fn zip_file(name: name) ->
        List.starts_with?(name, @in_archive_priv_path)
      end

      opts = [cwd: String.to_charlist(archive_dir), file_filter: file_filter]

      with {:error, error} <- :zip.extract(archive, opts) do
        raise "pp_client failed to extract archive files, reason: #{inspect(error)}"
      end

      File.touch!(extracted_path)
    end

    Application.put_env(:pp_client, :priv_dir, extracted_priv_dir(), persistent: true)
  end

  @doc """
  The directory the escript unpacks `priv` into.

  This is an OS-designated *data* directory (`~/Library/Application Support` on
  macOS, `$XDG_DATA_HOME` on Linux, `%LOCALAPPDATA%` on Windows) rather than a
  temporary one: the client is long-lived, and both macOS' `periodic` and
  systemd-tmpfiles sweep `$TMPDIR` on an age basis, which took the static assets
  out from under a running client. Cache directories are swept too, so `:user_data`
  is the one that holds.
  """
  def data_path do
    Path.join(data_root(), app_version())
  end

  defp data_root(), do: :filename.basedir(:user_data, "pp_client")

  def priv_path() do
    Application.get_env(:pp_client, :priv_dir) || Application.app_dir(:pp_client, "priv")
  end

  @doc false
  def static_from() do
    ensure_priv!()
    Path.join(priv_path(), "static")
  end

  # Every release unpacks into its own versioned directory under `data_root/0`, so
  # an upgrade would otherwise leave the previous releases' priv behind for good.
  # Releases up to 0.4.0 unpacked into `$TMPDIR/pp_client` instead; that goes too.
  # Best effort: a leftover directory is harmless, a failed boot is not. Should an
  # older release still be running, `ensure_priv!/0` will unpack it again.
  defp cleanup_stale_data() do
    root = data_root()

    with {:ok, entries} <- File.ls(root) do
      for entry <- entries, entry != app_version(), do: File.rm_rf(Path.join(root, entry))
    end

    if tmp_dir = System.tmp_dir() do
      tmp_dir |> Path.expand() |> Path.join("pp_client") |> File.rm_rf()
    end

    :ok
  end

  defp archive_dir(), do: Path.join(data_path(), "escript")
  defp extracted_path(), do: Path.join(archive_dir(), "extracted")
  defp extracted_priv_dir(), do: Path.join(archive_dir(), @priv_subpath)

  # `Plug.Static` resolves `from:` on every request, which is our chance to notice
  # that the unpacked priv went missing while we were running and put it back. Only
  # meaningful under the escript — elsewhere `priv` is a real directory in the build.
  defp ensure_priv!() do
    if Application.get_env(:pp_client, :priv_dir) && not priv_extracted?() do
      :global.trans({{__MODULE__, :extract_priv}, self()}, fn ->
        if not priv_extracted?(), do: extract_priv!()
      end)
    end

    :ok
  end

  # Deliberately computed from `data_path/0` rather than read back out of
  # `priv_path/0`, so this is also answerable on the boot path, before the
  # `:priv_dir` env that `priv_path/0` reads has been put.
  defp priv_extracted?() do
    File.exists?(extracted_path()) and File.dir?(extracted_priv_dir())
  end
end
