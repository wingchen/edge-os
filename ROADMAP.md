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
- [x] Integrate `ex_webrtc` (pure Elixir) as cloud-side WebRTC peer
- [x] Cloud initiates WebRTC offer to edge via `EdgeSocket` signaling
- [x] `WebRTCPeer` registers under `EdgeTcpSocket`'s process name — `UserTcpSocket` and `is_session_ready` unchanged
- [x] `EdgeSSHUtils` branches on `edge.edge_info["protocol"]` — old devices use TCP bridge, new devices use WebRTC
- [x] `EdgeTcpSocket` left in place, unused for new devices

### 1C — New edge agent (alongside old code)
- [x] Integrate `webrtc` crate (webrtc-rs) for peer connection handling
- [x] Edge advertises `"protocol": "webrtc"` in `EDGE_INFO`
- [x] Handle `WEBRTC_OFFER` → negotiate → data channel → local `127.0.0.1:22`
- [x] Handle incoming `ICE_CANDIDATE` from cloud, route to active session
- [x] TURN credentials passed inside offer payload — edge needs no TURN secret
- [ ] Data channel: file transfer (replaces SCP tunnel)
- [x] `tcp_to_websocket.rs` stays dormant, serves old devices

### 1D — coturn infra
- [x] coturn Docker sidecar in docker-compose (host networking, local dev)
- [x] Production: `docker run` command documented in `prod.sh` comments
- [ ] Open on Sailoi server: UDP/TCP 3478, UDP 49152-65535
- [x] `TURN_SECRET` and `TURN_HOST` added to `prod.sh`; `TURN_SECRET` wired into `docker-compose.yaml`

### TODO — 1E-scale: Horizontal scaling via PubSub signaling
> Currently `EdgeSocket` and `WebRTCPeer` communicate via node-local `Process.register`/`Process.whereis`. This means the user's session and the edge's WebSocket must land on the same Erlang node — sticky sessions required.
>
> With WebRTC the data channel is UDP-based (IP-addressed, not process-addressed), so once ICE connects the data path already scales horizontally. Only the signaling phase needs fixing:
> - Replace `send(EdgeSocket.get_pid(edge.id), ...)` with a `Phoenix.PubSub` broadcast keyed on `edge_id`
> - The node holding the edge's WebSocket subscribes to its topic and forwards offer/answer/ICE messages
> - `WebRTCPeer` on any node can send/receive signaling without knowing which node the edge is on
>
> After this change: cloud nodes are fully stateless for the data path. Load balancers need no affinity. Horizontal scaling works out of the box.

### 1E — Legacy sunset *(no rush, when old devices have cycled out)*
- [ ] Remove `EdgeTcpSocket`, `tcp_to_websocket.rs`, `TCPPortSelector`
- [ ] Remove TCP port range from config

---

## Phase 2 — Tauri Native App
> Proper installable app. Zero-config onboarding. No terminal required. Built on the WebRTC foundation from Phase 1. Tauri is the only distribution going forward — the original daemon-only package is retired.
>
> **Daemon model:** the edge agent binary runs as a **system-level** OS service (starts at boot, survives user logout, no UI required). The Tauri menubar app is the management UI only — it does not own the agent process.
>
> **Platform roles:**
> - macOS / Linux desktop — full edge agent (system daemon) + management UI

### 2A — App shell
- [x] Tauri v2 project in `app/` (alongside `cloud/` and `edge/`)
- [x] Menubar app — `LSUIElement: true` + `ActivationPolicy::Accessory` — no dock icon on macOS
- [x] Tray menu: status item (disabled, updated by 2C), separator, Quit
- [x] Quit exits the UI only — daemon keeps running independently
- [x] `set_tray_status` helper ready for 2C to wire in live daemon state

### 2B — System daemon registration (macOS + Linux desktop only)
- [x] macOS: `pkg-scripts/preinstall` unloads daemon on upgrade; `pkg-scripts/postinstall` copies edge binary to `/Library/Application Support/EdgeOS/`, writes LaunchDaemon plist, runs `launchctl load`
- [x] `scripts/build-macos-pkg.sh` — wraps Tauri `.app` into a signed `.pkg` via `pkgbuild` + `productbuild`
- [x] Linux: `scripts/install-linux-daemon.sh` (manual sudo step; TODO: fold into `.deb` postinst in 2E)
- [x] Edge binary bundled as Tauri sidecar via `externalBin` in `tauri.conf.json`
- [x] Tray polls daemon status every 5s — shows `● Daemon running` / `○ Daemon stopped` / `○ Daemon not installed`
- [ ] Uninstaller stops + removes the service

### 2C — IPC between UI and daemon (macOS + Linux only)
- [x] Edge agent writes `$EDGE_OS_EDGE_DIR/status.json` on connect / disconnect / startup
- [x] Tauri UI reads status file on each 5s poll — shows `● Connected`, `◌ Connecting...`, `○ Disconnected`
- [x] File permissions work naturally: daemon (root) writes `644`, UI (user) reads

### 2D — Auth & config
- [x] Edge agent reads `$EDGE_OS_EDGE_DIR/config.json` on startup (falls back to env vars, then built-in defaults)
- [x] `postinstall` sets `root:admin 775` on EdgeOS dir so admin-user Tauri app can write `config.json` without sudo
- [x] First-run setup wizard (`setup.html`) — Cloud URL, Team Hash, API Token fields
- [x] `save_config` Tauri command: writes `config.json`, stores token in OS keychain, restarts daemon via `osascript`/`pkexec`
- [x] Keychain: `keyring` crate (macOS Keychain / Linux libsecret) under service `com.sailoi.edgeos`
- [x] Settings menu item re-opens setup window for config changes

### TODO — 2E: Installers
> Deferred. macOS `.pkg` build script exists (`scripts/build-macos-pkg.sh`); notarization and Linux `.deb`/AppImage packaging not yet set up. CoreML execution provider for ONNX (Apple Neural Engine) also deferred to when Phase 3 camera inference is ready.

### TODO — 2F: Mobile viewer
> Deferred. Tauri v2 mobile (iOS + Android) for viewing camera feeds and managing edges. Depends on Phase 3 camera MVP being complete first.

### TODO — Headless Linux (Pi / server)
> Deferred. Headless Linux devices currently use the original daemon package (`edge-os.service`).
> Future work: a `.deb` post-install script that writes the systemd unit and enables it, mirroring the macOS `.pkg` approach. No Tauri UI needed.

### TODO — Windows
> Deferred. The Windows build would be a viewer + management UI only (no edge agent, no daemon) since SSH on Windows is not a meaningful use case and ONVIF cameras are network devices independent of host OS. Not worth the effort until there is clear demand.

---

## Phase 2.5 — Browser↔Edge P2P Foundation
> Lays the data-flow architecture before Phase 3 camera work begins. Validates that a browser can open a WebRTC data channel directly to the edge with the cloud handling signaling only — no camera data or event data ever touches the cloud server.
>
> **Principle:** Cloud = authentication + signaling only. All camera data, events, and thumbnails flow P2P between browser and edge over an encrypted WebRTC data channel (DTLS). If the edge is offline, the browser sees nothing — that is the correct tradeoff for a privacy-first product.
>
> **Signaling flow:**
> ```
> Browser JS ──offer──→ LiveView ──→ EdgeSocket ──→ Edge
> Browser JS ←─answer─ LiveView ←── EdgeSocket ←── Edge
> Browser JS ←─ICE────→ LiveView ←─→ EdgeSocket ←─→ Edge
>                  (cloud sees signaling only, never data)
> Browser ←──────────── WebRTC data channel ──────────→ Edge
> ```

### 2.5A — Edge: connection type routing
- [x] Add `connection_type` field to WEBRTC_OFFER payload: `"ssh"` vs `"camera"`
- [x] Edge routes `"ssh"` offers to existing SSH bridge handler (no change)
- [x] Edge routes `"camera"` offers to new stub camera handler — opens data channel, echoes pong to validate P2P

### 2.5B — Cloud: browser signaling path
- [x] LiveView JS hook: browser creates `RTCPeerConnection`, generates offer, sends to LiveView via `pushEvent`
- [x] LiveView forwards browser offer to edge via `EdgeSocket` (same `send/2` path as today)
- [x] LiveView receives edge answer + ICE candidates, forwards back to browser via `push_event`
- [x] TURN credentials passed to browser (same HMAC generation as SSH path)
- [x] Session scoped to the authenticated user — no unauthenticated signaling

### 2.5C — Validate end-to-end ✓
- [x] Browser opens data channel to edge, sends `{type: "ping"}`, edge replies `{type: "pong"}`
- [x] Confirmed: "✓ P2P validated. Direct browser ↔ edge data channel works. Cloud saw only signaling."
- [ ] Test via TURN relay (simulate NAT) to confirm relay path works from browser

### 2.5D — Define data channel protocol (spec only, no implementation)
> Agree on the message format before Phase 3 builds on top. Implementation happens in Phase 3.
>
> **Browser → Edge:**
> ```json
> {"type": "LIST_EVENTS", "since": <timestamp>, "limit": 50}
> {"type": "GET_THUMBNAIL", "event_id": "..."}
> {"type": "START_STREAM", "camera_id": "..."}
> {"type": "STOP_STREAM", "camera_id": "..."}
> ```
> **Edge → Browser:**
> ```json
> {"type": "EVENT_LIST", "events": [{id, camera, timestamp, class, confidence}]}
> {"type": "THUMBNAIL", "event_id": "...", "data": <binary JPEG>}
> {"type": "FRAME", "camera_id": "...", "data": <binary JPEG>}  // MJPEG at 5-10fps
> {"type": "PONG"}
> ```

---

## Phase 3 — Camera MVP
> Built on Phase 2.5 (browser↔edge P2P already validated).
>
> **Split responsibility:**
> - **Local cameras** (same LAN as the Tauri machine) → managed and viewed in the **Tauri desktop app**. Live feeds via direct RTSP or edge agent relay. No cloud involvement in the video path.
> - **Remote cameras** (different site) → viewed in the **Phoenix cloud web UI** via browser↔edge WebRTC P2P. Cloud handles auth + signaling only — no video, events, or thumbnails stored on or routed through the cloud.

### Tauri app — local camera UI

**Main window** (900×640, opens from tray icon):

```
┌─────────────────────────────────────────────────────┐
│  [logo]  EdgeOS          ○ edge-228 · Connected      │  ← top bar
├──────────┬──────────────────────────────────────────┤
│          │                                          │
│ Cameras  │   [Camera 1]        [Camera 2]           │
│          │   ┌──────────┐      ┌──────────┐         │
│ Events   │   │  live    │      │  live    │         │
│          │   │  feed    │      │  feed    │         │
│ Settings │   └──────────┘      └──────────┘         │
│          │                                          │
│  + Add   │   [Camera 3]        [+ Add Camera]       │
│  Camera  │   ┌──────────┐      ┌──────────┐         │
│          │   │  live    │      │  dotted  │         │
│          │   │  feed    │      │  border  │         │
│          │   └──────────┘      └──────────┘         │
└──────────┴──────────────────────────────────────────┘
```

**Three views:**
- **Cameras** — live grid; click any tile for full-screen + event timeline
- **Events** — chronological detection feed with thumbnails and clip playback
- **Settings** — zone config (draw polygons on frame), alert thresholds, edge config

**Camera onboarding flow:**
1. Click "+ Add Camera"
2. App scans LAN for ONVIF devices (WS-Discovery)
3. Lists found cameras with IP + model name
4. User selects one (or enters manual RTSP URL) + credentials
5. Camera appears in grid

**Live feed path (local):**
- Poll last-frame JPEG from edge agent as starting point (simpler than full RTSP)
- Upgrade to direct RTSP decode (Rust RTSP client + ffmpeg) → frames into `<canvas>`
- Full real-time: edge agent streams via WebRTC data channel → rendered in Tauri webview

**Tasks:**
- [ ] Main app window with sidebar navigation (Cameras / Events / Settings)
- [ ] Camera grid — static JPEG snapshots first, live RTSP second
- [ ] Camera onboarding wizard — ONVIF LAN scan + manual RTSP entry
- [ ] Single camera full-screen view + event timeline
- [ ] Events view — thumbnail list, clip playback
- [ ] Zone configuration UI — draw polygons on camera still frame
- [ ] Open main window from tray (replaces or augments current status panel)

### Edge client (Rust)
- [ ] Pull RTSP stream via FFmpeg
- [ ] Extract frames at 1fps
- [ ] Frame differencing as cheap motion pre-filter before AI
- [ ] YOLOv8n inference via `ort` crate (CPU first)
- [ ] Zone intersection logic (user-defined polygons)
- [ ] Trigger local recording on detection (FFmpeg → .mp4)
- [ ] Report events + thumbnails to edge-os cloud
- [ ] Serve last-frame JPEG endpoint for Tauri app polling
- [ ] Stream camera feed via WebRTC data channel

### Cloud (Elixir/Phoenix) — remote camera access
- [ ] `camera_device` type in device registry
- [ ] Event storage schema (timestamp, thumbnail, clip path, camera id)
- [ ] Notification dispatch — ntfy.sh push + email via SMTP
- [ ] API endpoints for events and thumbnails

### Cloud Web UI (LiveView) — remote camera access
- [ ] Camera list in dashboard
- [ ] Live feed viewer — WebRTC stream relayed through edge agent
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
