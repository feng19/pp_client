defmodule PpClientWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PpClientWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar sticky top-0 z-40 min-h-14 gap-2 border-b border-base-300 bg-base-100/95 px-3 backdrop-blur sm:px-6 lg:px-8">
      <div class="min-w-0 flex-1">
        <.link
          navigate={~p"/"}
          class="flex min-w-0 items-center gap-2 transition-opacity hover:opacity-80"
        >
          <img src={~p"/images/logo.svg"} width="32" height="32" alt="" class="size-8 shrink-0" />
          <span class="truncate text-base font-bold sm:text-lg">PP Client</span>
        </.link>
      </div>

      <%!-- Desktop nav --%>
      <nav class="hidden flex-none lg:block">
        <ul class="menu menu-horizontal menu-sm gap-1 px-0">
          <li :for={item <- nav_items()}>
            <.link navigate={item.path} class="whitespace-nowrap">
              <.icon name={item.icon} class="size-4" />{item.label}
            </.link>
          </li>
        </ul>
      </nav>

      <%!-- The toggle sits outside the mobile menu: it is one tap either way,
            and a segmented control reads badly as a menu entry. --%>
      <div class="flex flex-none items-center gap-1">
        <.theme_toggle />

        <div class="dropdown dropdown-end lg:hidden">
          <div tabindex="0" role="button" class="btn btn-ghost btn-square" aria-label="Open menu">
            <.icon name="hero-bars-3" class="size-6" />
          </div>
          <ul
            tabindex="0"
            class="menu dropdown-content z-50 mt-3 w-56 gap-1 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
          >
            <li :for={item <- nav_items()}>
              <.link navigate={item.path}>
                <.icon name={item.icon} class="size-5" />{item.label}
              </.link>
            </li>
          </ul>
        </div>
      </div>
    </header>

    <%!-- Page sits on base-200 so the base-100 cards on it read as raised. --%>
    <main class="min-h-[calc(100dvh-3.5rem)] bg-base-200">
      <div class="mx-auto w-full max-w-7xl px-3 py-4 sm:px-6 sm:py-6 lg:px-8">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  # Single source for both the desktop bar and the mobile menu, so the two
  # cannot drift apart.
  defp nav_items do
    [
      %{path: ~p"/admin/endpoints", label: "Endpoints", icon: "hero-signal"},
      %{path: ~p"/admin/servers", label: "Servers", icon: "hero-cloud"},
      %{path: ~p"/admin/profiles", label: "Profiles", icon: "hero-identification"},
      %{path: ~p"/admin/conditions", label: "Conditions", icon: "hero-funnel"},
      %{path: ~p"/admin/dns", label: "DNS", icon: "hero-globe-alt"},
      %{path: ~p"/admin/config", label: "Config", icon: "hero-document-text"}
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex w-[5.75rem] shrink-0 flex-row items-center rounded-full border-2 border-base-300 bg-base-300">
      <div class="absolute h-full w-1/3 rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use the system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use the light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use the dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
