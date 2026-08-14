defmodule PpClientWeb.ConfigController do
  @moduledoc """
  Downloads the running configuration as a `pp.exs`.

  A plain request rather than something the config LiveView does, because a
  LiveView cannot hand the browser a file — and because this is the one copy that
  carries the real credentials, which is exactly what should not be sitting in a
  LiveView's assigns. The page renders a redacted preview and links here.
  """
  use PpClientWeb, :controller

  def export(conn, _params) do
    send_download(conn, {:binary, PpClient.Config.dump()},
      filename: "pp.exs",
      content_type: "text/plain",
      charset: "utf-8"
    )
  end
end
