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
    <div id="modal" class="alert alert-warning" role="alert">
      <h4 class="alert-heading">Renmae Edge</h4>
      <hr>
      <p class="mb-0">
        <%= render_slot(@inner_block) %>
      </p>
      <p class="mb-0">
        <%= if @return_to do %>
          <%= live_patch "Cancel",
            to: @return_to,
            id: "close",
            class: "btn btn-outline-danger",
            phx_click: hide_modal()
          %>
        <% else %>
        <a id="close" class="btn btn-outline-danger" phx-click={hide_modal()} href="#" role="button">Cancel</a>
        <% end %>
      </p>
    </div>
    """
  end

  defp hide_modal(js \\ %JS{}) do
    js
    |> JS.hide(to: "#modal", transition: "fade-out")
    |> JS.hide(to: "#modal-content", transition: "fade-out-scale")
  end
end
