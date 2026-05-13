defmodule EdgeOsCloud.IceServers do
  @moduledoc """
  Builds the ICE server list sent to both the browser (RTCPeerConnection) and
  the edge (WEBRTC_OFFER ice_servers field).

  Configured via env vars:
    TURN_HOST      — relay hostname (e.g. global.relay.metered.ca)
    TURN_USERNAME  — TURN username
    TURN_PASSWORD  — TURN credential
    TURN_STUN_HOST — STUN hostname:port (default: stun.relay.metered.ca:80)

  Returns a list of maps matching the W3C RTCIceServer shape so the same value
  can be JSON-encoded into the edge offer and rendered into the browser config.
  """

  def build do
    case System.get_env("TURN_HOST") do
      nil ->
        [%{urls: ["stun:stun.l.google.com:19302"]}]

      turn_host ->
        username   = System.get_env("TURN_USERNAME", "")
        credential = System.get_env("TURN_PASSWORD", "")
        stun_host  = System.get_env("TURN_STUN_HOST", "stun.relay.metered.ca:80")
        [
          %{urls: ["stun:#{stun_host}"]},
          %{urls: ["turn:#{turn_host}:80"],                 username: username, credential: credential},
          %{urls: ["turn:#{turn_host}:80?transport=tcp"],   username: username, credential: credential},
          %{urls: ["turn:#{turn_host}:443"],                username: username, credential: credential},
          %{urls: ["turns:#{turn_host}:443?transport=tcp"], username: username, credential: credential},
        ]
    end
  end
end
