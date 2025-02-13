defmodule EdgeOsCloudWeb.APIAuth do
  import Plug.Conn
  require Logger

  alias EdgeOsCloud.Accounts

  @doc """
  Initializes the plug options.
  """
  def init(opts), do: opts

  @doc """
  Authenticate user using Bearer token from the request header.
  """
  def call(conn, _opts) do
    case get_bearer_token(conn) do
      nil ->
        conn
        |> send_resp(404, "Not Found")
        |> halt()

      token ->
        case Accounts.get_user_via_token(token) do
          {:ok, nil} ->
            conn
            |> send_resp(404, "Not Found")
            |> halt()

          {:ok, user} ->
            put_session(conn, :current_user, user)
        end
    end
  end

  # Private helper to extract Bearer token from the Authorization header
  defp get_bearer_token(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization") do
      Logger.debug("gettinbg token of #{token}")
      token
    else
      _ -> nil
    end
  end
end
