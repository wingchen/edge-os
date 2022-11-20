defmodule EdgeOsCloudWeb.AuthController do
  use EdgeOsCloudWeb, :controller
  plug Ueberauth

  alias EdgeOsCloud.UserFromAuth
  alias EdgeOsCloud.Accounts

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "You have been logged out!")
    |> clear_session()
    |> redirect(to: "/login")
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: "/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case UserFromAuth.find_or_create(auth) do
      {:ok, user_basic_info} ->
        # look for user in db, create one if not found
        {:ok, user} = case Accounts.get_user_via_email(user_basic_info.email) do
          {:ok, nil} -> Accounts.create_user(user_basic_info)
          {:ok, u} -> Accounts.update_user(u, %{updated_at: Timex.now() |> Timex.to_naive_datetime()})
        end

        conn
        |> put_flash(:info, "Welcome to EdgeOS, #{user.name}")
        |> put_session(:current_user, user)
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: "/login")
    end
  end
end
