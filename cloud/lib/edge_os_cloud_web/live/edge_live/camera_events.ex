defmodule EdgeOsCloudWeb.EdgeLive.CameraEvents do
  use EdgeOsCloudWeb, :live_view
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Sockets.EdgeSocket

  @impl true
  def mount(%{"id" => edge_id, "camera_id" => camera_id} = params, session, socket) do
    case Map.get(session, "current_user") do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user ->
        edge = Device.get_edge!(edge_id)
        protocol = get_in(edge.edge_info, ["protocol"]) || "tcp"
        {_turn_fields, ice_servers} = build_turn_config()

        camera_name = Map.get(params, "camera_name", camera_id)
        {:ok, assign(socket,
          edge:         edge,
          camera_id:    camera_id,
          camera_name:  camera_name,
          current_user: user,
          protocol:     protocol,
          ice_servers:  ice_servers,
          session_hash: nil
        )}
    end
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("browser_webrtc_offer", %{"sdp" => sdp}, socket) do
    %{edge: edge} = socket.assigns
    {turn_fields, _} = build_turn_config()
    session_hash = generate_session_hash(edge)

    Phoenix.PubSub.subscribe(EdgeOsCloud.PubSub, "browser_session:#{session_hash}")

    offer_payload = Jason.encode!(Map.merge(%{
      session_id:      session_hash,
      sdp:             sdp,
      connection_type: "camera",
    }, turn_fields))

    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil ->
        {:noreply, socket}
      _ ->
        send(edge_pid, "WEBRTC_OFFER #{offer_payload}")
        Logger.info("CameraEvents: browser→edge offer forwarded edge=#{edge.id} session=#{session_hash}")
        {:noreply, assign(socket, session_hash: session_hash)}
    end
  end

  def handle_event("browser_ice_candidate", %{"candidate" => candidate, "sdpMLineIndex" => index, "sdpMid" => mid}, socket) do
    %{edge: edge, session_hash: session_hash} = socket.assigns
    if session_hash do
      payload = Jason.encode!(%{session_id: session_hash, candidate: candidate, sdpMLineIndex: index, sdpMid: mid})
      send(Process.whereis(EdgeSocket.get_pid(edge.id)), "ICE_CANDIDATE #{payload}")
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:webrtc_answer, _session_hash, sdp}, socket) do
    {:noreply, push_event(socket, "webrtc_answer", %{sdp: sdp})}
  end

  def handle_info({:ice_candidate, _session_hash, candidate, index, mid}, socket) do
    {:noreply, push_event(socket, "ice_candidate", %{
      candidate: candidate, sdpMLineIndex: index, sdpMid: mid
    })}
  end

  defp generate_session_hash(edge) do
    session_id = :rand.uniform(999_999_999)
    EdgeOsCloud.HashIdHelper.encode(session_id, edge.salt)
  end

  defp build_turn_config do
    case System.get_env("TURN_HOST") do
      nil ->
        {%{turn_host: nil, turn_username: nil, turn_credential: nil},
         [%{urls: ["stun:stun.l.google.com:19302"]}]}
      turn_host ->
        username   = System.get_env("TURN_USERNAME", "")
        credential = System.get_env("TURN_PASSWORD", "")
        fields = %{turn_host: turn_host, turn_username: username, turn_credential: credential}
        servers = [
          %{urls: ["stun:stun.l.google.com:19302"]},
          %{urls: ["turn:#{turn_host}:3478"], username: username, credential: credential}
        ]
        {fields, servers}
    end
  end
end
