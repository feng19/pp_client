defmodule PpClientWeb.Router do
  use PpClientWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PpClientWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PpClientWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/admin", PpClientWeb do
    pipe_through :browser

    live "/endpoints", EndpointLive.Index, :index
    live "/endpoints/new", EndpointLive.Index, :new
    live "/endpoints/:port/edit", EndpointLive.Index, :edit

    live "/profiles", ProfileLive.Index, :index
    live "/profiles/new", ProfileLive.Index, :new
    live "/profiles/:name/edit", ProfileLive.Index, :edit
  end

  # Other scopes may use custom stacks.
  # scope "/api", PpClientWeb do
  #   pipe_through :api
  # end
end
