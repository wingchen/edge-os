defmodule EdgeOsCloudWeb.Router do
  use EdgeOsCloudWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {EdgeOsCloudWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", EdgeOsCloudWeb do
    pipe_through :browser

    get "/", PageController, :index
    get "/login", PageController, :login
    get "/logout", PageController, :logout

    live "/edges", EdgeLive.Index, :index
    live "/edges/:id/edit", EdgeLive.Index, :edit
    live "/edges/:id/ssh", EdgeLive.Index, :ssh
    live "/edges/:id", EdgeLive.Show, :show

    live "/users", UserLive.Index, :index
    live "/users/:id/edit", UserLive.Index, :edit
    live "/users/:id", UserLive.Show, :show

    live "/teams", TeamLive.Index, :index
    live "/teams/new", TeamLive.Index, :new
    live "/teams/:id/edit", TeamLive.Index, :edit
    live "/teams/:id/admins", TeamLive.Index, :admins
    live "/teams/:id/members", TeamLive.Index, :members
    live "/teams/:id", TeamLive.Show, :show
  end

  scope "/auth", EdgeOsCloudWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  # Other scopes may use custom stacks.
  # scope "/api", EdgeOsCloudWeb do
  #   pipe_through :api
  # end

  # Enables LiveDashboard only for development
  #
  # If you want to use the LiveDashboard in production, you should put
  # it behind authentication and allow only admins to access it.
  # If your application does not have an admins-only section yet,
  # you can use Plug.BasicAuth to set up some basic authentication
  # as long as you are also using SSL (which you should anyway).
  if Mix.env() in [:dev, :test] do
    import Phoenix.LiveDashboard.Router

    scope "/" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EdgeOsCloudWeb.Telemetry
    end
  end

  # Enables the Swoosh mailbox preview in development.
  #
  # Note that preview only shows emails that were sent by the same
  # node running the Phoenix server.
  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
