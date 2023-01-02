defmodule EdgeOsCloudWeb.TeamLive.NewEdgeComponent do
  use EdgeOsCloudWeb, :live_component
  require Logger
  alias EdgeOsCloud.Accounts

  @impl true
  def update(%{team: team} = assigns, socket) do
    changeset = Accounts.change_team(team)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl true
  def handle_event("validate", %{"team" => team_params}, socket) do
    changeset =
      socket.assigns.team
      |> Accounts.change_team(team_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"team" => team_params}, socket) do
    # see if the users in admins are legit
    {team_params, socket, admins_error} = confirm_valid_users("admins", team_params, socket)
    # see if the users in members are legit
    {team_params, socket, members_error} = confirm_valid_users("members", team_params, socket)

    team_params = fill_in_user_as_admin_member_if_empty(socket, team_params)
    save_team(socket, socket.assigns.action, team_params, admins_error or members_error)
  end

  defp confirm_valid_users(field, team_params, socket) do
    if is_nil(team_params[field]) do
      {team_params, socket, false}
    else
      case email_str_to_user_ids(team_params[field]) do
        {:ok, user_ids} ->
          {Map.put(team_params, field, user_ids), socket, false}

        {:exist_not, does_not_exist} ->
          message = "#{inspect does_not_exist} in #{field} field is not a user, please sign up first"
          Logger.error(message)
          {team_params, put_flash(socket, :error, message), true}
      end
    end
  end

  defp email_str_to_user_ids(eamil_strs) do
    emails = String.downcase(eamil_strs) |> String.split(",", trim: true) |> Enum.map(fn x -> String.trim(x) end)
    email_id_map = EdgeOsCloud.Accounts.emails_to_user_ids(emails)
    does_not_exist = Enum.filter(email_id_map, fn {_k, v} -> is_nil(v) end) |> Enum.map(fn {k, _v} -> k end)

    if length(does_not_exist) != 0 do
      {:exist_not, does_not_exist}
    else
      {:ok, email_id_map |> Enum.map(fn {_k, v} -> v end)}
    end
  end

  def list_user_emails(nil) do
    []
  end

  def list_user_emails(id_list) do
    Enum.reduce(EdgeOsCloud.Accounts.get_user_emails(id_list), fn x, acc -> "#{acc},\n#{x}" end)
  end

  defp fill_in_user_as_admin_member_if_empty(socket, team_params) do
    %{current_user: user} = socket.assigns

    # add user admin id in if there is no value there
    team_params = if (is_list(team_params["admins"]) and length(team_params["admins"])) == 0 or is_nil(team_params["admins"]) do
      Map.put(team_params, "admins", [user.id])
    else
      team_params
    end

    # add user member id in if there is no value there
    team_params = if (is_list(team_params["members"]) and length(team_params["members"])) == 0 or is_nil(team_params["members"]) do
      Map.put(team_params, "members", [user.id])
    else
      team_params
    end

    team_params
  end

  defp save_team(socket, :edit, team_params, error_happend) do
    if error_happend do
      {:noreply,
         socket
         |> push_redirect(to: Routes.team_index_path(socket, :edit, socket.assigns.team))}
    else
      case Accounts.update_team(socket.assigns.team, team_params) do
        {:ok, _team} ->
          {:noreply,
           socket
           |> put_flash(:info, "Team updated successfully")
           |> push_redirect(to: socket.assigns.return_to)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :changeset, changeset)}
      end
    end
  end

  defp save_team(socket, :new, team_params, error_happend) do
    if error_happend do
      {:noreply,
         socket
         |> push_redirect(to: Routes.team_index_path(socket, :new))}
    else
      case Accounts.create_team(team_params) do
        {:ok, _team} ->
          {:noreply,
           socket
           |> put_flash(:info, "Team created successfully")
           |> push_redirect(to: socket.assigns.return_to)}

        {:error, %Ecto.Changeset{} = changeset} ->
          Logger.error("error creating new team: #{inspect changeset}")
          {:noreply, assign(socket, changeset: changeset)}
      end
    end
  end
end
