defmodule EdgeOsCloudWeb.TeamLive.Index do
  use EdgeOsCloudWeb, :live_view
  require Logger

  alias EdgeOsCloud.Accounts
  alias EdgeOsCloud.Accounts.Team

  @impl true
  def mount(_params, session, socket) do
    user = Map.get(session, "current_user")
    updated_socket = 
      socket
      |> assign(:teams, list_teams(user.id))
      |> assign(:current_user, user)
    {:ok, updated_socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Accounts.get_team(id) do
      nil -> socket
      team ->
        socket
        |> assign(:page_title, "Edit Team")
        |> assign(:team, team)
    end
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Team")
    |> assign(:team, %Team{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Teams")
    |> assign(:team, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    %{current_user: user} = socket.assigns

    case Accounts.get_team(id) do
      nil -> raise "the team to be deleted does not exist"
      team ->
        {:ok, _} = Accounts.delete_team(team)
    end

    {:noreply, assign(socket, :teams, list_teams(user.id))}
  end

  defp list_teams(user_id) do
    Accounts.list_teams_for_user(user_id)
  end
end
