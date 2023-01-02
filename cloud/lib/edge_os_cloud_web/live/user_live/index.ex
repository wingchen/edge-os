defmodule EdgeOsCloudWeb.UserLive.Index do
  use EdgeOsCloudWeb, :live_view

  alias EdgeOsCloud.Accounts
  alias EdgeOsCloud.Accounts.User

  @impl true
  def mount(_params, session, socket) do
    case Map.get(session, "current_user") do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user ->
        updated_socket = 
          socket
          |> assign(:users, list_users())
          |> assign(:current_user, user)
        {:ok, updated_socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit User")
    |> assign(:user, Accounts.get_user!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New User")
    |> assign(:user, %User{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Users")
    |> assign(:user, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    {:ok, _} = Accounts.delete_user(user)

    {:noreply, assign(socket, :users, list_users())}
  end

  defp list_users do
    Accounts.list_users()
  end
end
