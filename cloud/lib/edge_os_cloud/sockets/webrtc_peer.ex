defmodule EdgeOsCloud.Sockets.WebRTCPeer do
  use GenServer
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Device.EdgeSessionStage
  alias EdgeOsCloud.Sockets.EdgeSocket
  alias EdgeOsCloud.Sockets.EdgeTcpSocket
  alias EdgeOsCloud.Sockets.UserTcpSocket

  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)
    edge = Keyword.fetch!(opts, :edge)
    session_hash = Keyword.fetch!(opts, :session_hash)
    GenServer.start_link(__MODULE__, {session, edge, session_hash}, [])
  end

  def init({session, edge, session_hash}) do
    # One registration only — Erlang allows a process only one registered name.
    # EdgeSocket signaling handlers decode the session hash to find this process
    # via EdgeTcpSocket.get_pid. UserTcpSocket and is_session_ready also use this name.
    Process.register(self(), EdgeTcpSocket.get_pid(session.id))

    {turn_ice_servers, turn_fields} = build_turn_config()
    ice_servers = [%{urls: ["stun:stun.l.google.com:19302"]}] ++ turn_ice_servers

    {:ok, pc} = ExWebRTC.PeerConnection.start_link(ice_servers: ice_servers)
    {:ok, dc} = ExWebRTC.PeerConnection.create_data_channel(pc, "ssh-tunnel", ordered: true)
    dc_ref = dc.ref  # plain Erlang reference — what send_data and state_change events use
    {:ok, offer} = ExWebRTC.PeerConnection.create_offer(pc)
    :ok = ExWebRTC.PeerConnection.set_local_description(pc, offer)

    offer_payload = Jason.encode!(Map.merge(%{session_id: session_hash, sdp: offer.sdp}, turn_fields))
    send(EdgeSocket.get_pid(edge.id), "WEBRTC_OFFER #{offer_payload}")

    Device.append_edge_session_action(session.id, EdgeSessionStage.get.edge_connected)
    Logger.info("WebRTCPeer started for session #{session.id}, offer sent to edge #{edge.id}")

    {:ok, %{pc: pc, dc_ref: dc_ref, session: session, edge: edge, session_hash: session_hash, dc_open: false, pending: []}}
  end

  # SDP answer from edge, routed here by EdgeSocket.handel_message
  def handle_info({:webrtc_answer, sdp}, %{pc: pc} = state) do
    answer = %ExWebRTC.SessionDescription{type: :answer, sdp: sdp}
    :ok = ExWebRTC.PeerConnection.set_remote_description(pc, answer)
    Logger.debug("WebRTC answer set for session #{state.session.id}")
    {:noreply, state}
  end

  # ICE candidate from edge, routed here by EdgeSocket.handel_message
  def handle_info({:ice_candidate, candidate_str, index, mid}, %{pc: pc} = state) do
    candidate = %ExWebRTC.ICECandidate{
      candidate: candidate_str,
      sdp_m_line_index: index,
      sdp_mid: mid
    }
    ExWebRTC.PeerConnection.add_ice_candidate(pc, candidate)
    {:noreply, state}
  end

  # Local ICE candidate gathered by ex_webrtc — forward to edge via EdgeSocket
  def handle_info({:ex_webrtc, _pc, {:ice_candidate, candidate}}, %{session_hash: session_hash, edge: edge} = state) do
    candidate_payload = Jason.encode!(%{
      session_id: session_hash,
      candidate: candidate.candidate,
      sdpMLineIndex: candidate.sdp_m_line_index,
      sdpMid: candidate.sdp_mid
    })
    send(EdgeSocket.get_pid(edge.id), "ICE_CANDIDATE #{candidate_payload}")
    {:noreply, state}
  end

  # Data channel became open — flush any buffered user data
  # ex_webrtc sends {:data_channel_state_change, ref, :open} (not {:data_channel_open, ...})
  def handle_info({:ex_webrtc, _pc, {:data_channel_state_change, _ref, :open}}, %{pc: pc, dc_ref: dc_ref, session: session, pending: pending} = state) do
    Logger.info("WebRTC data channel open for session #{session.id}")
    Device.append_edge_session_action(session.id, EdgeSessionStage.get.user_connected)
    Enum.each(Enum.reverse(pending), fn data ->
      ExWebRTC.PeerConnection.send_data(pc, dc_ref, data, :binary)
    end)
    {:noreply, %{state | dc_open: true, pending: []}}
  end

  def handle_info({:ex_webrtc, _pc, {:data_channel_state_change, _ref, state_name}}, state) do
    Logger.debug("data channel state #{state_name} for session #{state.session.id}")
    {:noreply, state}
  end

  # Data from edge via data channel — forward to UserTcpSocket
  # ex_webrtc sends {:data, ref, binary()} (not {:data_channel_message, ...})
  def handle_info({:ex_webrtc, _pc, {:data, _ref, data}}, %{session: session} = state) do
    case Process.whereis(UserTcpSocket.get_pid(session.id)) do
      nil -> Logger.warning("UserTcpSocket not found for session #{session.id}")
      pid -> send(pid, {:edge_ssh_payload, data})
    end
    {:noreply, state}
  end

  # Data from UserTcpSocket — forward to edge via data channel (buffer if channel not yet open)
  def handle_info(data, %{pc: pc, dc_ref: dc_ref, dc_open: true} = state) when is_binary(data) do
    ExWebRTC.PeerConnection.send_data(pc, dc_ref, data, :binary)
    {:noreply, state}
  end

  def handle_info(data, %{dc_open: false, pending: pending} = state) when is_binary(data) do
    {:noreply, %{state | pending: [data | pending]}}
  end

  # UserTcpSocket signals TCP close — tear down the data channel
  def handle_info(:user_tcp_closed, %{session: session} = state) do
    Logger.info("tearing down WebRTC session #{session.id}: user TCP closed")
    Device.append_edge_session_action(session.id, EdgeSessionStage.get.user_disconnected)
    {:stop, :normal, state}
  end

  def handle_info(:user_tcp_errored, %{session: session} = state) do
    Logger.error("tearing down WebRTC session #{session.id}: user TCP error")
    {:stop, :normal, state}
  end

  def handle_info({:ex_webrtc, _pc, {:connection_state_change, new_state}}, state) do
    Logger.debug("WebRTC connection state #{new_state} for session #{state.session.id}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("WebRTCPeer unhandled message: #{inspect msg}")
    {:noreply, state}
  end

  defp build_turn_config do
    case System.get_env("TURN_HOST") do
      nil ->
        {[], %{turn_host: nil, turn_username: nil, turn_credential: nil}}

      turn_host ->
        username   = System.get_env("TURN_USERNAME", "")
        credential = System.get_env("TURN_PASSWORD", "")
        stun_host  = System.get_env("TURN_STUN_HOST", "stun.relay.metered.ca:80")
        ice = [
          %{urls: ["stun:#{stun_host}"]},
          %{urls: ["turn:#{turn_host}:80"],                 username: username, credential: credential},
          %{urls: ["turn:#{turn_host}:80?transport=tcp"],   username: username, credential: credential},
          %{urls: ["turn:#{turn_host}:443"],                username: username, credential: credential},
          %{urls: ["turns:#{turn_host}:443?transport=tcp"], username: username, credential: credential},
        ]
        fields = %{turn_host: turn_host, turn_username: username, turn_credential: credential}
        {ice, fields}
    end
  end
end
