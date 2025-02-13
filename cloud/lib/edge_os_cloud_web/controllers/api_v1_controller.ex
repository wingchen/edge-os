defmodule EdgeOsCloudWeb.APIV1Controller do
  use EdgeOsCloudWeb, :controller
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Sockets.EdgeSSHUtils

  def list_edges(conn, _params) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> put_status(404)
        |> json(%{
            "ok" => false,
            "error_message" => "never heard of it"
          })

      user ->
        filterd_user_edges = 
          Device.list_active_account_edges(user.id)
          |> Enum.map(fn ue -> %{
              "name" => ue.name,
              "edge_id" => ue.uuid,
              "status" => ue.status,
              "team" => ue.team.name
            } end)

        conn
        |> put_status(:ok)
        |> json(filterd_user_edges)
    end
  end

  defp wait_for_ssh_connection(session_id, n) when n <= 0 do
    message = "Session #{session_id} wait finished. we it's not ready"
    Logger.info(message)
    {:error, message}
  end

  defp wait_for_ssh_connection(session_id, n) do
    Logger.debug("checking again to see if Session #{session_id} ready")

    if EdgeSSHUtils.is_session_ready(session_id) do
      message = "Session #{session_id} is ready after #{n} count"
      Logger.debug(message)
      {:ok, message}
    else
      Process.sleep(3000)
      wait_for_ssh_connection(session_id, n - 1)
    end
  end

  def ssh_connect(conn, %{"edge_id" => edge_uuid}) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> put_status(404)
        |> json(%{
            "ok" => false,
            "error_message" => "never heard of it"
          })

      user ->
        case Device.get_edge_with_uuid(edge_uuid) do
          {:ok, nil} ->
            conn
            |> put_status(404)
            |> json(%{
                "ok" => false,
                "error_message" => "cannot find edge to connect to with #{edge_uuid}"
              })
          {:ok, edge} ->
            if edge.status do
              case EdgeSSHUtils.create_ssh_connection(user, edge, conn.remote_ip) do
                {:error, message} ->
                  Logger.error("connect to edge from API, with error: #{message}")
                  conn
                  |> put_status(500)
                  |> json(%{
                      "ok" => false,
                      "error_message" => message
                    })

                {:ok, session, message} ->
                  Logger.info("commanding to edge from API: #{message}")
                  cloud_url = System.get_env("PHX_HOST", "127.0.0.1")
                  random_session_hash = EdgeOsCloud.HashIdHelper.encode(session.id, UUID.uuid4()) |> String.slice(0..5) |> String.downcase()

                  # wait until it's connected
                  case wait_for_ssh_connection(session.id, 3) do
                    {:ok, _message} ->
                      conn
                      |> put_status(:ok)
                      |> json(%{
                          "ok" => true,
                          "port" => session.port,
                          "endpoint" => "#{random_session_hash}.#{cloud_url}"
                        })

                    {:error, _message} ->
                      conn
                      |> put_status(500)
                      |> json(%{
                          "ok" => false,
                          "error_message" => "edge #{edge_uuid} cannot be reached"
                        })
                  end
              end
            else
              conn
              |> put_status(404)
              |> json(%{
                  "ok" => false,
                  "error_message" => "edge #{edge_uuid} does not appear online"
                })
            end
        end
    end
  end
end
