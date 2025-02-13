defmodule EdgeOsCloud.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias EdgeOsCloud.Repo

  alias EdgeOsCloud.Accounts.User
  alias EdgeOsCloud.Accounts.UserAction
  alias EdgeOsCloud.Accounts.UserAPITokens

  require Logger

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  def get_user_via_email(email) do
    query = from u in User,
          where: u.email == ^email,
          select: u

    case Repo.all(query) do
      [user] -> {:ok, user}
      [] -> {:ok, nil}
      _ -> raise "more than 1 user with eamil #{email} is found"
    end
  end

  def get_user_via_token(token) do
    native_time_now = DateTime.to_naive(DateTime.utc_now())

    query = from t in UserAPITokens,
          join: u in User, on: t.user_id == u.id,
          where: t.token == ^token and t.expiration > ^native_time_now,
          select: u

    case Repo.all(query) do
      [user | _tail] -> {:ok, user}
      _ -> {:ok, nil}
    end
  end

  def get_user_token(user) do
    native_time_now = DateTime.to_naive(DateTime.utc_now())

    query = from t in UserAPITokens,
          where: t.expiration > ^native_time_now and t.user_id == ^user.id,
          select: t

    case Repo.all(query) do
      [token | _tail] -> {:ok, token}
      _ -> {:ok, nil}
    end
  end

  def emails_to_user_ids(emails) do
    query = from u in User,
      where: u.email in ^emails,
      select: u

    # create a lookup table
    email_id_map = Repo.all(query) |> Enum.map(fn u -> {u.email, u.id} end) |> Map.new(fn {k, v} -> {k, v} end)

    # look up for ids
    Enum.map(emails, fn e -> {e, email_id_map[e]} end) |> Map.new(fn {k, v} -> {k, v} end)
  end

  def get_user_names(id_list) do
    cmds = Enum.map(id_list, fn i -> ["GET", "user_#{i}_name"] end)
    {:ok, cached_results} = Redix.pipeline(Redis, cmds)

    result_map = Enum.zip([id_list, cached_results])
    |> Map.new(fn {k, v} -> {k, v} end)

    Logger.debug("cached user names #{inspect result_map}")

    not_cached_ids = Enum.filter(result_map, fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, _v} -> k end)
    Logger.debug("not_cached_ids #{inspect not_cached_ids}")

    if length(not_cached_ids) != 0 do
      # query DB for the user names
      query = from u in User,
        where: u.id in ^not_cached_ids,
        select: u

      not_cached_id_users = Repo.all(query)
      Logger.debug("not_cached_id_users #{inspect not_cached_id_users}")

      # cache the result back
      cache_cmds = Enum.map(not_cached_id_users, fn user -> ["SET", "user_#{user.id}_name", user.name, "EX", "3600"] end)
      Logger.debug("cache_cmds #{inspect cache_cmds}")
      {:ok, _} = Redix.pipeline(Redis, cache_cmds)

      # update result_map with the db data
      id_user_name_map = Enum.map(not_cached_id_users, fn user -> {user.id, user.name} end) |> Map.new(fn {k, v} -> {k, v} end)

      result_map |> Enum.map(
        fn {id, name} ->
          if is_nil(name) do
            Map.get(id_user_name_map, id)
          else
            name
          end
      end)
    else
      result_map |> Map.values()
    end
  end

  def get_user_emails(id_list) do
    cmds = Enum.map(id_list, fn i -> ["GET", "user_#{i}_email"] end)
    {:ok, cached_results} = Redix.pipeline(Redis, cmds)

    result_map = Enum.zip([id_list, cached_results])
    |> Map.new(fn {k, v} -> {k, v} end)

    Logger.debug("cached user emails #{inspect result_map}")

    not_cached_ids = Enum.filter(result_map, fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, _v} -> k end)
    Logger.debug("not_cached_ids #{inspect not_cached_ids}")

    if length(not_cached_ids) != 0 do
      # query DB for the user emails
      query = from u in User,
        where: u.id in ^not_cached_ids,
        select: u

      not_cached_id_users = Repo.all(query)
      Logger.debug("not_cached_id_users #{inspect not_cached_id_users}")

      # cache the result back
      cache_cmds = Enum.map(not_cached_id_users, fn user -> ["SET", "user_#{user.id}_email", user.email] end)
      Logger.debug("cache_cmds #{inspect cache_cmds}")
      {:ok, _} = Redix.pipeline(Redis, cache_cmds)

      # update result_map with the db data
      id_user_email_map = Enum.map(not_cached_id_users, fn user -> {user.id, user.email} end) |> Map.new(fn {k, v} -> {k, v} end)

      result_map |> Enum.map(
        fn {id, email} ->
          if is_nil(email) do
            Map.get(id_user_email_map, id)
          else
            email
          end
      end)
    else
      result_map |> Map.values()
    end
  end

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def create_user_token(user) do
    attrs = %{
      "token" => UUID.uuid4() <> UUID.uuid4(),
      "user_id" => user.id,
    }

    %UserAPITokens{}
    |> UserAPITokens.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Logs a user_action.

  ## Examples

      iex> log_user_action(%{field: value})
      {:ok, %User{}}

      iex> log_user_action(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def log_user_action(attrs \\ %{}) do
    %UserAction{}
    |> UserAction.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  alias EdgeOsCloud.Accounts.Team

  @doc """
  Returns the list of teams.

  ## Examples

      iex> list_teams()
      [%Team{}, ...]

  """
  def list_teams do
    Repo.all(Team)
  end

  def list_teams_for_user(user_id) do
    query = from t in Team,
      where: t.deleted == false and (^user_id in t.admins or ^user_id in t.members),
      order_by: [desc: t.inserted_at],
      select: t

    Repo.all(query)
  end

  @doc """
  Gets a single team.

  Raises `Ecto.NoResultsError` if the Team does not exist.

  ## Examples

      iex> get_team!(123)
      %Team{}

      iex> get_team!(456)
      ** (Ecto.NoResultsError)

  """
  def get_team!(id), do: Repo.get!(Team, id)
  def get_team(id), do: Repo.get(Team, id)

  @doc """
  Gets the encrypted id hash from the team.
  We pass this hash to edge through command line when the edge instance is being create.
  And then when the edge is connecting back to the cloud, it provides this hash to the cloud to
  tell the cloud what team this edge belongs to.
  """
  def get_team_id_hash(id) do
    team = get_team!(id)
    EdgeOsCloud.HashIdHelper.encode(team.id, EdgeOsCloud.System.get_setting!("id_hash_salt"))
  end

  @doc """
  Creates a team.

  ## Examples

      iex> create_team(%{field: value})
      {:ok, %Team{}}

      iex> create_team(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_team(attrs \\ %{}) do
    %Team{}
    |> Team.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a team.

  ## Examples

      iex> update_team(team, %{field: new_value})
      {:ok, %Team{}}

      iex> update_team(team, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_team(%Team{} = team, attrs) do
    team
    |> Team.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a team.

  ## Examples

      iex> delete_team(team)
      {:ok, %Team{}}

      iex> delete_team(team)
      {:error, %Ecto.Changeset{}}

  """
  def delete_team(%Team{} = team) do
    update_team(team, %{deleted: true})
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking team changes.

  ## Examples

      iex> change_team(team)
      %Ecto.Changeset{data: %Team{}}

  """
  def change_team(%Team{} = team, attrs \\ %{}) do
    Team.changeset(team, attrs)
  end
end
