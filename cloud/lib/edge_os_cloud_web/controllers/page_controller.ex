defmodule EdgeOsCloudWeb.PageController do
  use EdgeOsCloudWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def devices(conn, _params) do
    render(conn, "devices.html")
  end
end
