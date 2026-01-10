defmodule PpClient do
  import Record
  defrecord(:zip_file, extract(:zip_file, from_lib: "stdlib/include/zip.hrl"))
  @app_version Mix.Project.config()[:version]

  def app_version(), do: @app_version

  def main(_) do
    {:ok, _} = Application.ensure_all_started(:elixir)
    extract_priv!()

    start()
    IO.puts("PP Client started.")

    receive do
      :stop -> :stop
    end
  end

  def start, do: Application.ensure_all_started(:pp_client)
  def stop, do: System.halt(0)

  defp extract_priv!() do
    archive_dir = Path.join(tmp_path(), "escript")
    extracted_path = Path.join(archive_dir, "extracted")
    in_archive_priv_path = ~c"pp_client/priv"

    # In dev we want to extract fresh directory on every boot
    if app_version() =~ "-dev" do
      File.rm_rf!(archive_dir)
    end

    # When temporary directory is cleaned by the OS, the directories
    # may be left in place, so we use a regular file (extracted) to
    # check if the extracted archive is already available
    if not File.exists?(extracted_path) do
      {:ok, sections} = :escript.extract(:escript.script_name(), [])
      archive = Keyword.fetch!(sections, :archive)

      file_filter = fn zip_file(name: name) ->
        List.starts_with?(name, in_archive_priv_path)
      end

      opts = [cwd: String.to_charlist(archive_dir), file_filter: file_filter]

      with {:error, error} <- :zip.extract(archive, opts) do
        raise "pp_client failed to extract archive files, reason: #{inspect(error)}"
      end

      File.touch!(extracted_path)
    end

    priv_dir = Path.join(archive_dir, in_archive_priv_path)
    Application.put_env(:pp_client, :priv_dir, priv_dir, persistent: true)
  end

  def tmp_path do
    tmp_dir = System.tmp_dir!() |> Path.expand()
    Path.join([tmp_dir, "pp_client", app_version()])
  end

  def priv_path() do
    Application.get_env(:pp_client, :priv_dir) || Application.app_dir(:pp_client, "priv")
  end

  @doc false
  def static_from(), do: Path.join(priv_path(), "static")
end
