defmodule EdgeOsCloudWeb.EdgeLiveTest do
  use EdgeOsCloudWeb.ConnCase

  import Phoenix.LiveViewTest
  import EdgeOsCloud.DeviceFixtures

  @create_attrs %{ip: "some ip", name: "some name", status: "some status"}
  @update_attrs %{ip: "some updated ip", name: "some updated name", status: "some updated status"}
  @invalid_attrs %{ip: nil, name: nil, status: nil}

  defp create_edge(_) do
    edge = edge_fixture()
    %{edge: edge}
  end

  describe "Index" do
    setup [:create_edge]

    test "lists all edges", %{conn: conn, edge: edge} do
      {:ok, _index_live, html} = live(conn, Routes.edge_index_path(conn, :index))

      assert html =~ "Listing Edges"
      assert html =~ edge.ip
    end

    test "saves new edge", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, Routes.edge_index_path(conn, :index))

      assert index_live |> element("a", "New Edge") |> render_click() =~
               "New Edge"

      assert_patch(index_live, Routes.edge_index_path(conn, :new))

      assert index_live
             |> form("#edge-form", edge: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#edge-form", edge: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.edge_index_path(conn, :index))

      assert html =~ "Edge created successfully"
      assert html =~ "some ip"
    end

    test "updates edge in listing", %{conn: conn, edge: edge} do
      {:ok, index_live, _html} = live(conn, Routes.edge_index_path(conn, :index))

      assert index_live |> element("#edge-#{edge.id} a", "Edit") |> render_click() =~
               "Edit Edge"

      assert_patch(index_live, Routes.edge_index_path(conn, :edit, edge))

      assert index_live
             |> form("#edge-form", edge: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        index_live
        |> form("#edge-form", edge: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.edge_index_path(conn, :index))

      assert html =~ "Edge updated successfully"
      assert html =~ "some updated ip"
    end

    test "deletes edge in listing", %{conn: conn, edge: edge} do
      {:ok, index_live, _html} = live(conn, Routes.edge_index_path(conn, :index))

      assert index_live |> element("#edge-#{edge.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#edge-#{edge.id}")
    end
  end

  describe "Show" do
    setup [:create_edge]

    test "displays edge", %{conn: conn, edge: edge} do
      {:ok, _show_live, html} = live(conn, Routes.edge_show_path(conn, :show, edge))

      assert html =~ "Show Edge"
      assert html =~ edge.ip
    end

    test "updates edge within modal", %{conn: conn, edge: edge} do
      {:ok, show_live, _html} = live(conn, Routes.edge_show_path(conn, :show, edge))

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Edge"

      assert_patch(show_live, Routes.edge_show_path(conn, :edit, edge))

      assert show_live
             |> form("#edge-form", edge: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      {:ok, _, html} =
        show_live
        |> form("#edge-form", edge: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, Routes.edge_show_path(conn, :show, edge))

      assert html =~ "Edge updated successfully"
      assert html =~ "some updated ip"
    end
  end
end
