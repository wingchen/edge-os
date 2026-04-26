defmodule EdgeOsCloudWeb.LiveHelpers do
  import Phoenix.LiveView
  import Phoenix.LiveView.Helpers

  alias Phoenix.LiveView.JS

  @doc """
  Renders a live component inside a modal.

  The rendered modal receives a `:return_to` option to properly update
  the URL when the modal is closed.

  ## Examples

      <.modal return_to={Routes.edge_index_path(@socket, :index)}>
        <.live_component
          module={EdgeOsCloudWeb.EdgeLive.FormComponent}
          id={@edge.id || :new}
          title={@page_title}
          action={@live_action}
          return_to={Routes.edge_index_path(@socket, :index)}
          edge: @edge
        />
      </.modal>
  """
  def modal(assigns) do
    assigns = assign_new(assigns, :return_to, fn -> nil end)

    ~H"""
    <div id="modal" class="card shadow mb-4">
      <div class="card-body">
        <%= render_slot(@inner_block) %>
      </div>
      <div class="card-footer bg-transparent border-top-0 pt-0">
        <%= if @return_to do %>
          <%= live_patch "Cancel",
            to: @return_to,
            id: "close",
            class: "btn btn-outline-secondary btn-sm",
            phx_click: hide_modal()
          %>
        <% else %>
          <a id="close" class="btn btn-outline-secondary btn-sm" phx-click={hide_modal()} href="#" role="button">Cancel</a>
        <% end %>
      </div>
    </div>
    """
  end

  defp hide_modal(js \\ %JS{}) do
    js
    |> JS.hide(to: "#modal", transition: "fade-out")
    |> JS.hide(to: "#modal-content", transition: "fade-out-scale")
  end
end
