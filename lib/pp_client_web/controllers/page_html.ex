defmodule PpClientWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PpClientWeb, :html

  embed_templates "page_html/*"

  # The landing page is a directory of the admin sections.
  defp sections do
    [
      %{
        path: ~p"/admin/endpoints",
        label: "Endpoints",
        icon: "hero-signal",
        blurb: "The local SOCKS5 and HTTP listeners clients connect to."
      },
      %{
        path: ~p"/admin/servers",
        label: "Servers",
        icon: "hero-cloud",
        blurb: "Upstream proxies that profiles route traffic through."
      },
      %{
        path: ~p"/admin/profiles",
        label: "Profiles",
        icon: "hero-identification",
        blurb: "Named routes: direct, or through a pool of servers."
      },
      %{
        path: ~p"/admin/conditions",
        label: "Conditions",
        icon: "hero-funnel",
        blurb: "Host patterns that pick the profile for a connection."
      },
      %{
        path: ~p"/admin/dns",
        label: "DNS Records",
        icon: "hero-globe-alt",
        blurb: "Domain to IP overrides used when dialling a server."
      },
      %{
        path: ~p"/admin/config",
        label: "Config File",
        icon: "hero-document-text",
        blurb: "Download the running setup as pp.exs, or import one over it."
      }
    ]
  end
end
