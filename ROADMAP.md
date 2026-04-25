# edge-os Product Roadmap
## From Remote Device Manager → Edge AI Platform

---

## Vision

Transform edge-os into a **privacy-first edge AI camera platform** — a self-hostable alternative to Nest/Arlo/Ring where no video ever leaves the local network. edge-os already solves NAT traversal, auth, and team management. Cameras are the killer app built on top of that foundation.

**Stack decisions:**
- Cloud: Elixir/Phoenix (existing)
- Edge client: Rust (existing) + Tauri v2 for native app shell
- AI inference: ONNX Runtime (`ort` crate) + CoreML on Apple Silicon (Neural Engine)
- Live streaming: WebRTC P2P (~85% direct, coturn relay fallback)
- SSH/data tunnels: WebRTC data channels (replaces current TCP bridge)
- Camera discovery: ONVIF Profile S
- Platforms: Tauri v2 → Mac, Windows, Linux, iOS, Android from one codebase

---

## Phase 0 — Security Hardening
> Prerequisite. Fix before building on top.

- [ ] `runtime.exs:35` — change database SSL from `verify: :verify_none` to `verify: :verify_peer`
- [ ] `api_auth.ex:38` — remove bearer token from `Logger.debug` output
- [ ] Add `force_ssl: [hsts: true]` to production endpoint config

---

## Phase 1 — WebRTC Transport Layer
> Foundation for everything that follows. Replaces the TCP bridge for new devices while keeping the existing TCP path alive for devices already online. SSH relays through TURN (traffic is low enough); video will go P2P in Phase 3.

### 1A — Cloud signaling (additive only, no existing code changed)
- [x] New message clauses in `EdgeSocket.handel_message`: `WEBRTC_ANSWER`, `ICE_CANDIDATE` (edge→cloud); cloud→edge uses existing `handle_info`
- [ ] `protocol_version` field handling in `EDGE_INFO` — cloud uses this to pick old vs new path
- [x] TURN credential generation — time-limited HMAC (`generate_turn_credentials/1`)
- [x] `GET /api/v1/turn-credentials` authenticated endpoint

### 1B — Cloud WebRTC peer (replaces `EdgeTcpSocket`)
- [ ] Integrate `ex_webrtc` (pure Elixir) as cloud-side WebRTC peer
- [ ] Cloud initiates WebRTC offer to edge via `EdgeSocket` signaling
- [ ] Once data channel is open, `UserTcpSocket` pipes TCP bytes through it instead of `EdgeTcpSocket`
- [ ] `EdgeTcpSocket` left in place, unused for new devices

### 1C — New edge agent (alongside old code)
- [ ] Integrate `str0m` (pure Rust, no C deps)
- [ ] Edge advertises `"protocol": "webrtc"` in `EDGE_INFO`
- [ ] Handle `WEBRTC_OFFER` → negotiate → data channel → local `127.0.0.1:22`
- [ ] Data channel: file transfer (replaces SCP tunnel)
- [ ] `tcp_to_websocket.rs` stays dormant, serves old devices

### 1D — coturn infra
- [ ] coturn Docker sidecar in docker-compose
- [ ] Open on Sailoi server: UDP/TCP 3478, UDP/TCP 5349, UDP 49152-65535
- [ ] Shared `TURN_SECRET` env var between coturn and Elixir app

### 1E — Legacy sunset *(no rush, when old devices have cycled out)*
- [ ] Remove `EdgeTcpSocket`, `tcp_to_websocket.rs`, `TCPPortSelector`
- [ ] Remove TCP port range from config

---

## Phase 2 — Tauri Native App
> Proper installable app. Zero-config onboarding. No terminal required. Built on the WebRTC foundation from Phase 1.

- [ ] Tauri v2 project wrapping the Rust edge client
- [ ] Menu bar app (macOS) — connection status, camera count, recent events
- [ ] macOS native notifications with thumbnails
- [ ] Keychain integration for auth token storage
- [ ] Launch at Login
- [ ] Installers: `.dmg` (Mac), AppImage/`.deb` (Linux/Pi), `.exe` (Windows)
- [ ] CoreML execution provider for ONNX — unlock Apple Neural Engine on Mac
- [ ] Tauri v2 mobile — iOS + Android viewer (same Rust core, same web UI)

---

## Phase 3 — Camera MVP
> Built on Phases 1 and 2. Video streams go P2P via WebRTC (cloud never sees frames). HLS used only as fallback for devices without a Tauri client.

### Edge client (Rust)
- [ ] Pull RTSP stream via FFmpeg
- [ ] Extract frames at 1fps
- [ ] Frame differencing as cheap motion pre-filter before AI
- [ ] YOLOv8n inference via `ort` crate (CPU first)
- [ ] Zone intersection logic (user-defined polygons)
- [ ] Trigger local recording on detection (FFmpeg → .mp4)
- [ ] Report events + thumbnails to edge-os cloud
- [ ] Video track — camera feed via WebRTC data channel (replaces HLS for live view)

### Cloud (Elixir/Phoenix)
- [ ] `camera_device` type in device registry
- [ ] Event storage schema (timestamp, thumbnail, clip path, camera id)
- [ ] Notification dispatch — ntfy.sh push + email via SMTP
- [ ] API endpoints for events and thumbnails

### Web UI (LiveView)
- [ ] Camera list in dashboard
- [ ] HLS live feed viewer (FFmpeg → HLS segments, fallback for browser-only access)
- [ ] Events browser with clip playback
- [ ] Zone configuration UI (draw polygons on camera frame)

---

## Phase 4 — ONVIF Multi-Camera Support
> Works with any IP camera, not just D-Link.

- [ ] WS-Discovery (multicast UDP) — auto-discover cameras on LAN
- [ ] ONVIF Profile S client — `GetStreamUri`, `GetProfiles`, `GetDeviceInformation`
- [ ] WS-UsernameToken authentication
- [ ] Camera auto-appears in UI after discovery
- [ ] Test with: Hikvision, Dahua, Reolink, Amcrest
- [ ] PTZ control UI
- [ ] ONVIF event subscriptions (receive motion events from camera's own sensor)

---

## Phase 5 — Advanced AI & Model Management
> From single model to platform.

- [ ] Model hot-swap — push new model from cloud, no app update needed
- [ ] Multiple detection classes per camera (person, vehicle, package, animal)
- [ ] Model marketplace — community-contributed ONNX models
- [ ] Custom training pipeline — train on user's own footage, upload to edge client
- [ ] Apple Vision framework — on-device face recognition
- [ ] Audio detection — glass breaking, shouting (via Whisper or custom model)
- [ ] Sensor fusion — correlate camera events with door/window sensors

---

## Longer-Term

**Product positioning:** Self-hostable, privacy-first alternative to Nest/Arlo/Ring. No subscription. No cloud video storage. Works behind any NAT out of the box.

**Business angles:**
- Open core — free self-hosted, paid cloud relay (NAT traversal as the monetizable layer)
- White-label for SMBs — property managers, retail, warehouses needing multi-site camera management without enterprise pricing
- GDPR/compliance market — local AI inference + no off-premise video is a genuine compliance story in Europe

**Platform evolution:** edge-os becomes an AI-native edge platform — deploy any AI workload to edge device fleets. Cameras are the first use case and the wedge.

---

## Immediate Next Step

**Phase 0 security fixes** (items 3-5 only — items 1 and 2 are superseded by Phase 1). Then **Phase 1A** cloud signaling — purely additive changes to `EdgeSocket`, sets the foundation without touching any existing code.
