defmodule EdgeOsCloudWeb.DashController do
  use EdgeOsCloudWeb, :controller
  require Logger

  alias EdgeOsCloud.Device

  defp memory_ration(%{"used_memory" => used_memory, "total_memory" => total_memory, "used_swap" => used_swap, "total_swap" => total_swap}) do
    [
      %{"name" => "regluar", "value" => (used_memory * 100) / total_memory},
      %{"name" => "swap", "value" => (used_swap * 100) / total_swap},
    ]
  end

  def edge(conn, %{"id" => edge_id}) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> redirect(to: "/login")

      user ->
        user_edges_ids = Device.list_active_account_edges(user.id) |> Enum.map(fn x -> x.id end)

        # NOTE: could be because edge_id is a int type
        edge_id_int = String.to_integer(edge_id)

        if edge_id_int in user_edges_ids do
          edge_statuss = Device.list_recent_edge_status(edge_id_int)
          timestamps = edge_statuss |> Enum.map(fn x -> Timex.format!(x.inserted_at, "{YYYY}-{0M}-{0D} {h24}:{m}:{s}") end)

          cpus = edge_statuss |> Enum.flat_map(fn x -> x.cpu end) |> Enum.group_by(fn x -> x["name"] end)
          memory = edge_statuss |> Enum.flat_map(fn x -> memory_ration(x.memory) end) |> Enum.group_by(fn x -> x["name"] end)
          disk = edge_statuss |> Enum.flat_map(fn x -> x.disk end) |> Enum.group_by(fn x -> x["name"] end)
          temperature = edge_statuss |> Enum.flat_map(fn x -> x.temperature end) |> Enum.group_by(fn x -> x["label"] end)
          process_count = edge_statuss |> Enum.map(fn x -> x.process_count end)

          conn
          |> assign(:current_user, user)
          |> assign(:timestamps, timestamps)
          |> assign(:cpus, cpus)
          |> assign(:memory, memory)
          |> assign(:disk, disk)
          |> assign(:temperature, temperature)
          |> assign(:process_count, process_count)
          |> render("edge.html")
        else
          conn
          |> text("cannot find the edge")
        end
    end
  end
end
