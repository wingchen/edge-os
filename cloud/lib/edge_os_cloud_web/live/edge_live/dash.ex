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
        is_windows = get_in(edge.edge_info, ["sys_name"]) == "Windows"
        {:ok, assign(socket,
          edge: edge,
          current_user: user,
          protocol: protocol,
          ice_servers: ice_servers,
          is_windows: is_windows,
          p2p_status: :idle,
          session_hash: nil,
          video_session_hash: nil,
          video_camera_id: nil,
          rdp_session_hash: nil
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

      session_hash == socket.assigns.rdp_session_hash ->
        Logger.info("RDP WebRTC answer, forwarding to browser")
        {:noreply, push_event(socket, "rdp_webrtc_answer", %{sdp: sdp})}

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

      session_hash == socket.assigns.rdp_session_hash ->
        {:noreply, push_event(socket, "rdp_ice_candidate", %{
          candidate: candidate, sdpMLineIndex: index, sdpMid: mid
        })}

      true ->
        {:noreply, push_event(socket, "ice_candidate", %{
          candidate: candidate, sdpMLineIndex: index, sdpMid: mid
        })}
    end
  end

  # Browser explicitly stopped the video stream (back button, stop button, etc.)
  def handle_event("browser_stop_camera_video", _params, socket) do
    send_webrtc_close(socket)
    {:noreply, assign(socket, video_session_hash: nil, video_camera_id: nil)}
  end

  # ── RDP signaling ────────────────────────────────────────────────────────────

  def handle_event("browser_rdp_offer", %{"sdp" => sdp}, socket) do
    %{edge: edge} = socket.assigns

    rdp_session_hash = generate_session_hash(edge)
    Phoenix.PubSub.subscribe(EdgeOsCloud.PubSub, "browser_session:#{rdp_session_hash}")

    offer_payload = Jason.encode!(%{
      session_id:      rdp_session_hash,
      sdp:             sdp,
      connection_type: "rdp",
      ice_servers:     build_ice_servers(),
    })

    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil ->
        {:noreply, socket}
      _ ->
        send(edge_pid, "WEBRTC_OFFER #{offer_payload}")
        Logger.info("browser→edge RDP offer forwarded session=#{rdp_session_hash}")
        {:noreply, assign(socket, rdp_session_hash: rdp_session_hash)}
    end
  end

  def handle_event("browser_rdp_ice_candidate", %{"candidate" => candidate, "sdpMLineIndex" => index, "sdpMid" => mid}, socket) do
    %{edge: edge, rdp_session_hash: rdp_session_hash} = socket.assigns
    if rdp_session_hash do
      payload = Jason.encode!(%{session_id: rdp_session_hash, candidate: candidate, sdpMLineIndex: index, sdpMid: mid})
      send(Process.whereis(EdgeSocket.get_pid(edge.id)), "ICE_CANDIDATE #{payload}")
    end
    {:noreply, socket}
  end

  def handle_event("browser_stop_rdp", _params, socket) do
    send_rdp_close(socket)
    {:noreply, assign(socket, rdp_session_hash: nil)}
  end

  # LiveView process terminating — browser closed tab, navigated away, or connection lost.
  # Fires for cases 1 & 2; case 3 already cleared video_session_hash so this is a no-op then.
  @impl true
  def terminate(_reason, socket) do
    send_webrtc_close(socket)
    send_rdp_close(socket)
    :ok
  end

  defp send_webrtc_close(%{assigns: %{edge: edge, video_session_hash: video_session_hash}})
       when is_binary(video_session_hash) do
    payload = Jason.encode!(%{session_id: video_session_hash})
    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil -> :ok
      pid -> send(pid, "WEBRTC_CLOSE #{payload}")
    end
    Logger.info("WEBRTC_CLOSE sent for session=#{video_session_hash}")
  end
  defp send_webrtc_close(_socket), do: :ok

  defp send_rdp_close(%{assigns: %{edge: edge, rdp_session_hash: rdp_session_hash}})
       when is_binary(rdp_session_hash) do
    payload = Jason.encode!(%{session_id: rdp_session_hash})
    edge_pid = EdgeSocket.get_pid(edge.id)
    case Process.whereis(edge_pid) do
      nil -> :ok
      pid -> send(pid, "WEBRTC_CLOSE #{payload}")
    end
    Logger.info("WEBRTC_CLOSE sent for RDP session=#{rdp_session_hash}")
  end
  defp send_rdp_close(_socket), do: :ok

  defp generate_session_hash(edge) do
    session_id = :rand.uniform(999_999_999)
    EdgeOsCloud.HashIdHelper.encode(session_id, edge.salt)
  end

  defp build_ice_servers, do: EdgeOsCloud.IceServers.build()
end
