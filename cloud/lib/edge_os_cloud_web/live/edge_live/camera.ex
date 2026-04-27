defmodule EdgeOsCloudWeb.EdgeLive.Camera do
  use EdgeOsCloudWeb, :live_view
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Sockets.EdgeSocket

  @impl true
  def mount(%{"id" => edge_id}, session, socket) do
    case Map.get(session, "current_user") do
      nil -> {:ok, redirect(socket, to: "/login")}
      user ->
        edge = Device.get_edge!(edge_id)
        {:ok, assign(socket,
          edge: edge,
          current_user: user,
          p2p_status: :idle,
          session_hash: nil
        )}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # Browser sends its WebRTC offer — forward to edge with connection_type: "camera"
  @impl true
  def handle_event("browser_webrtc_offer", %{"sdp" => sdp}, socket) do
    %{edge: edge} = socket.assigns

    {turn_fields, ice_servers} = build_turn_config()
    session_hash = generate_session_hash(edge)

    # Subscribe to PubSub so EdgeSocket can route the edge's answer back here
    Phoenix.PubSub.subscribe(EdgeOsCloud.PubSub, "browser_session:#{session_hash}")

    offer_payload = Jason.encode!(Map.merge(%{
      session_id:      session_hash,
      sdp:             sdp,
      connection_type: "camera",
    }, turn_fields))

    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil ->
        {:noreply, assign(socket, p2p_status: :edge_offline)}
      _ ->
        send(edge_pid, "WEBRTC_OFFER #{offer_payload}")
        Logger.info("browser→edge camera offer forwarded for edge #{edge.id} session #{session_hash}")
        {:noreply, assign(socket, p2p_status: :negotiating, session_hash: session_hash,
                                  ice_servers: ice_servers)}
    end
  end

  # Browser sends an ICE candidate — forward to edge
  def handle_event("browser_ice_candidate", %{"candidate" => candidate, "sdpMLineIndex" => index, "sdpMid" => mid}, socket) do
    %{edge: edge, session_hash: session_hash} = socket.assigns
    if session_hash do
      payload = Jason.encode!(%{session_id: session_hash, candidate: candidate, sdpMLineIndex: index, sdpMid: mid})
      send(Process.whereis(EdgeSocket.get_pid(edge.id)), "ICE_CANDIDATE #{payload}")
    end
    {:noreply, socket}
  end

  # Edge answer routed back via PubSub
  @impl true
  def handle_info({:webrtc_answer, sdp}, socket) do
    Logger.info("camera WebRTC answer received, forwarding to browser")
    {:noreply, push_event(socket, "webrtc_answer", %{sdp: sdp})}
  end

  # Edge ICE candidate routed back via PubSub
  def handle_info({:ice_candidate, candidate, index, mid}, socket) do
    {:noreply, push_event(socket, "ice_candidate", %{candidate: candidate, sdpMLineIndex: index, sdpMid: mid})}
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
        secret    = System.get_env("TURN_SECRET", "")
        timestamp = System.os_time(:second) + 86_400
        username  = "#{timestamp}:edgeos"
        credential = :crypto.mac(:hmac, :sha, secret, username) |> Base.encode64()
        fields = %{turn_host: turn_host, turn_username: username, turn_credential: credential}
        servers = [
          %{urls: ["stun:stun.l.google.com:19302"]},
          %{urls: ["turn:#{turn_host}:3478"], username: username, credential: credential}
        ]
        {fields, servers}
    end
  end
end
