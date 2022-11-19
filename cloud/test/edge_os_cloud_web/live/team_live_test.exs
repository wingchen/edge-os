defmodule EdgeOsCloudWeb.TeamLiveTest do
  use EdgeOsCloudWeb.ConnCase

  import Phoenix.LiveViewTest
  import EdgeOsCloud.AccountsFixtures

  @create_attrs %{admins: [], name: "some name"}
  @update_attrs %{admins: [], name: "some updated name"}
  @invalid_attrs %{admins: [], name: nil}

  defp create_team(_) do
    team = team_fixture()
    %{team: team}
  end

  describe "Index" do
    setup [:create_team]

    test "lists all teams", %{conn: conn, team: team} do
      {:ok, _index_live, html} = live(conn, Routes.team_index_path(conn, :index))

      assert html =~ "Listing Teams"
      assert html =~ team.name
    end

    test "saves new team", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, Routes.team_index_path(conn, :index))

      assert index_live |> element("a", "New Team") |> render_click() =~
               "New Team"

      assert_patch(index_live, Routes.team_index_path(conn, :new))

      assert index_live
             |> form("#team-form", team: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#team-form", team: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.team_index_path(conn, :index))

      assert html =~ "Team created successfully"
      assert html =~ "some name"
    end

    test "updates team in listing", %{conn: conn, team: team} do
      {:ok, index_live, _html} = live(conn, Routes.team_index_path(conn, :index))

      assert index_live |> element("#team-#{team.id} a", "Edit") |> render_click() =~
               "Edit Team"

      assert_patch(index_live, Routes.team_index_path(conn, :edit, team))

      assert index_live
             |> form("#team-form", team: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#team-form", team: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.team_index_path(conn, :index))

      assert html =~ "Team updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes team in listing", %{conn: conn, team: team} do
      {:ok, index_live, _html} = live(conn, Routes.team_index_path(conn, :index))

      assert index_live |> element("#team-#{team.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#team-#{team.id}")
    end
  end

  describe "Show" do
    setup [:create_team]

    test "displays team", %{conn: conn, team: team} do
      {:ok, _show_live, html} = live(conn, Routes.team_show_path(conn, :show, team))

      assert html =~ "Show Team"
      assert html =~ team.name
    end

    test "updates team within modal", %{conn: conn, team: team} do
      {:ok, show_live, _html} = live(conn, Routes.team_show_path(conn, :show, team))

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Team"

      assert_patch(show_live, Routes.team_show_path(conn, :edit, team))

      assert show_live
             |> form("#team-form", team: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        show_live
        |> form("#team-form", team: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.team_show_path(conn, :show, team))

      assert html =~ "Team updated successfully"
      assert html =~ "some updated name"
    end
  end
end
