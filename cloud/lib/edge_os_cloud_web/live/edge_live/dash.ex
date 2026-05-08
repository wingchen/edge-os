defmodule EdgeOsCloudWeb.EdgeLive.Dash do
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
        protocol = get_in(edge.edge_info, ["protocol"]) || "tcp"
        ice_servers = build_ice_servers()
        {:ok, assign(socket,
          edge: edge,
          current_user: user,
          protocol: protocol,
          ice_servers: ice_servers,
          p2p_status: :idle,
          session_hash: nil,
          video_session_hash: nil,
          video_camera_id: nil
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

    session_hash = generate_session_hash(edge)

    # Subscribe to PubSub so EdgeSocket can route the edge's answer back here
    Phoenix.PubSub.subscribe(EdgeOsCloud.PubSub, "browser_session:#{session_hash}")

    offer_payload = Jason.encode!(%{
      session_id:      session_hash,
      sdp:             sdp,
      connection_type: "camera",
      ice_servers:     build_ice_servers(),
    })

    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil ->
        {:noreply, assign(socket, p2p_status: :edge_offline)}
      _ ->
        send(edge_pid, "WEBRTC_OFFER #{offer_payload}")
        Logger.info("browser→edge camera offer forwarded for edge #{edge.id} session #{session_hash}")
        {:noreply, assign(socket, p2p_status: :negotiating, session_hash: session_hash)}
    end
  end

  # Browser sends an ICE candidate for the data channel PC — forward to edge
  def handle_event("browser_ice_candidate", %{"candidate" => candidate, "sdpMLineIndex" => index, "sdpMid" => mid}, socket) do
    %{edge: edge, session_hash: session_hash} = socket.assigns
    if session_hash do
      payload = Jason.encode!(%{session_id: session_hash, candidate: candidate, sdpMLineIndex: index, sdpMid: mid})
      send(Process.whereis(EdgeSocket.get_pid(edge.id)), "ICE_CANDIDATE #{payload}")
    end
    {:noreply, socket}
  end

  # Browser sends a video offer (camera live view) — separate PC from the data channel
  def handle_event("browser_camera_video_offer", %{"sdp" => sdp, "camera_id" => camera_id}, socket) do
    %{edge: edge} = socket.assigns

    video_session_hash = generate_session_hash(edge)

    Phoenix.PubSub.subscribe(EdgeOsCloud.PubSub, "browser_session:#{video_session_hash}")

    offer_payload = Jason.encode!(%{
      session_id:      video_session_hash,
      sdp:             sdp,
      connection_type: "camera_video",
      camera_id:       camera_id,
      ice_servers:     build_ice_servers(),
    })

    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil ->
        {:noreply, socket}
      _ ->
        send(edge_pid, "WEBRTC_OFFER #{offer_payload}")
        Logger.info("browser→edge camera_video offer forwarded camera=#{camera_id} session=#{video_session_hash}")
        {:noreply, assign(socket, video_session_hash: video_session_hash, video_camera_id: camera_id)}
    end
  end

  # Browser sends ICE candidate for the video PC
  def handle_event("browser_video_ice_candidate", %{"candidate" => candidate, "sdpMLineIndex" => index, "sdpMid" => mid}, socket) do
    %{edge: edge, video_session_hash: video_session_hash} = socket.assigns
    if video_session_hash do
      payload = Jason.encode!(%{session_id: video_session_hash, candidate: candidate, sdpMLineIndex: index, sdpMid: mid})
      send(Process.whereis(EdgeSocket.get_pid(edge.id)), "ICE_CANDIDATE #{payload}")
    end
    {:noreply, socket}
  end

  # Edge answer — session_hash tells us which PC this belongs to
  @impl true
  def handle_info({:webrtc_answer, session_hash, sdp}, socket) do
    cond do
      session_hash == socket.assigns.video_session_hash ->
        camera_id = socket.assigns.video_camera_id
        Logger.info("video WebRTC answer for camera=#{camera_id}, forwarding to browser")
        {:noreply, push_event(socket, "video_webrtc_answer", %{sdp: sdp, camera_id: camera_id})}

      session_hash == socket.assigns.session_hash ->
        Logger.info("data-channel WebRTC answer, forwarding to browser")
        {:noreply, push_event(socket, "webrtc_answer", %{sdp: sdp})}

      true ->
        Logger.warning("webrtc_answer for unknown session #{session_hash}, ignoring")
        {:noreply, socket}
    end
  end

  # Edge ICE candidate — same routing by session_hash
  def handle_info({:ice_candidate, session_hash, candidate, index, mid}, socket) do
    cond do
      session_hash == socket.assigns.video_session_hash ->
        camera_id = socket.assigns.video_camera_id
        {:noreply, push_event(socket, "video_ice_candidate", %{
          candidate: candidate, sdpMLineIndex: index, sdpMid: mid, camera_id: camera_id
        })}

      true ->
        {:noreply, push_event(socket, "ice_candidate", %{
          candidate: candidate, sdpMLineIndex: index, sdpMid: mid
        })}
    end
  end

  defp generate_session_hash(edge) do
    session_id = :rand.uniform(999_999_999)
    EdgeOsCloud.HashIdHelper.encode(session_id, edge.salt)
  end

  defp build_ice_servers, do: EdgeOsCloud.IceServers.build()
end
