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
- **RTSP→WebRTC video bridge: GStreamer** — `rtspsrc → rtph264depay → h264parse → tee → rtph264pay → webrtcbin`. Handles RTP packetization, SDP/profile-level-id negotiation, RTCP PLI keyframe requests, and N-viewer fan-out natively. LGPL 2.1 throughout (no gst-plugins-ugly or libav needed). Bundled per-platform — see Distribution section in Phase 3E.

---

## Phase 1 — Security Hardening
> Prerequisite. Fix before building on top.

- [ ] `runtime.exs:35` — change database SSL from `verify: :verify_none` to `verify: :verify_peer`
- [ ] `api_auth.ex:38` — remove bearer token from `Logger.debug` output
- [ ] Add `force_ssl: [hsts: true]` to production endpoint config

---

## Phase 2 — WebRTC Transport Layer
> Foundation for everything that follows. Replaces the TCP bridge for new devices while keeping the existing TCP path alive for devices already online. SSH relays through TURN (traffic is low enough); video will go P2P in Phase 3.

### 2A — Cloud signaling (additive only, no existing code changed)
- [x] New message clauses in `EdgeSocket.handel_message`: `WEBRTC_ANSWER`, `ICE_CANDIDATE` (edge→cloud); cloud→edge uses existing `handle_info`
- [x] `protocol_version` field handling in `EDGE_INFO` — cloud uses this to pick old vs new path
- [x] TURN credential generation — time-limited HMAC (`generate_turn_credentials/1`)
- [x] `GET /api/v1/turn-credentials` authenticated endpoint

### 2B — Cloud WebRTC peer (replaces `EdgeTcpSocket`)
- [x] Integrate `ex_webrtc` (pure Elixir) as cloud-side WebRTC peer
- [x] Cloud initiates WebRTC offer to edge via `EdgeSocket` signaling
- [x] `WebRTCPeer` registers under `EdgeTcpSocket`'s process name — `UserTcpSocket` and `is_session_ready` unchanged
- [x] `EdgeSSHUtils` branches on `edge.edge_info["protocol"]` — old devices use TCP bridge, new devices use WebRTC
- [x] `EdgeTcpSocket` left in place, unused for new devices

### 2C — New edge agent (alongside old code)
- [x] Integrate `webrtc` crate (webrtc-rs) for peer connection handling
- [x] Edge advertises `"protocol": "webrtc"` in `EDGE_INFO`
- [x] Handle `WEBRTC_OFFER` → negotiate → data channel → local `127.0.0.1:22`
- [x] Handle incoming `ICE_CANDIDATE` from cloud, route to active session
- [x] TURN credentials passed inside offer payload — edge needs no TURN secret
- [ ] Data channel: file transfer (replaces SCP tunnel)
- [x] `tcp_to_websocket.rs` stays dormant, serves old devices

### 2D — coturn infra
- [x] coturn Docker sidecar in docker-compose (host networking, local dev)
- [x] Production: `docker run` command documented in `prod.sh` comments
- [ ] Open on Sailoi server: UDP/TCP 3478, UDP 49152-65535
- [x] `TURN_SECRET` and `TURN_HOST` added to `prod.sh`; `TURN_SECRET` wired into `docker-compose.yaml`

### TODO — 2E-scale: Horizontal scaling via PubSub signaling
> Currently `EdgeSocket` and `WebRTCPeer` communicate via node-local `Process.register`/`Process.whereis`. This means the user's session and the edge's WebSocket must land on the same Erlang node — sticky sessions required.
>
> With WebRTC the data channel is UDP-based (IP-addressed, not process-addressed), so once ICE connects the data path already scales horizontally. Only the signaling phase needs fixing:
> - Replace `send(EdgeSocket.get_pid(edge.id), ...)` with a `Phoenix.PubSub` broadcast keyed on `edge_id`
> - The node holding the edge's WebSocket subscribes to its topic and forwards offer/answer/ICE messages
> - `WebRTCPeer` on any node can send/receive signaling without knowing which node the edge is on
>
> After this change: cloud nodes are fully stateless for the data path. Load balancers need no affinity. Horizontal scaling works out of the box.

### 2E — Legacy sunset *(no rush, when old devices have cycled out)*
- [ ] Remove `EdgeTcpSocket`, `tcp_to_websocket.rs`, `TCPPortSelector`
- [ ] Remove TCP port range from config

---

## Phase 3 — Tauri Native App
> Proper installable app. Zero-config onboarding. No terminal required. Built on the WebRTC foundation from Phase 1. Tauri is the only distribution going forward — the original daemon-only package is retired.
>
> **Daemon model:** the edge agent binary runs as a **system-level** OS service (starts at boot, survives user logout, no UI required). The Tauri menubar app is the management UI only — it does not own the agent process.
>
> **Platform roles:**
> - macOS / Linux desktop — full edge agent (system daemon) + management UI

### 3A — App shell
- [x] Tauri v2 project in `app/` (alongside `cloud/` and `edge/`)
- [x] Menubar app — `LSUIElement: true` + `ActivationPolicy::Accessory` — no dock icon on macOS
- [x] Tray menu: status item (disabled, updated by 2C), separator, Quit
- [x] Quit exits the UI only — daemon keeps running independently
- [x] `set_tray_status` helper ready for 2C to wire in live daemon state

### 3B — System daemon registration (macOS + Linux desktop only)
- [x] macOS: `pkg-scripts/preinstall` unloads daemon on upgrade; `pkg-scripts/postinstall` copies edge binary to `/Library/Application Support/EdgeOS/`, writes LaunchDaemon plist, runs `launchctl load`
- [x] `scripts/build-macos-pkg.sh` — wraps Tauri `.app` into a signed `.pkg` via `pkgbuild` + `productbuild`
- [x] Linux: `scripts/install-linux-daemon.sh` (manual sudo step; TODO: fold into `.deb` postinst in 2E)
- [x] Edge binary bundled as Tauri sidecar via `externalBin` in `tauri.conf.json`
- [x] Tray polls daemon status every 5s — shows `● Daemon running` / `○ Daemon stopped` / `○ Daemon not installed`
- [ ] Uninstaller stops + removes the service

### 3C — IPC between UI and daemon (macOS + Linux only)
- [x] Edge agent writes `$EDGE_OS_EDGE_DIR/status.json` on connect / disconnect / startup
- [x] Tauri UI reads status file on each 5s poll — shows `● Connected`, `◌ Connecting...`, `○ Disconnected`
- [x] File permissions work naturally: daemon (root) writes `644`, UI (user) reads

### 3D — Auth & config
- [x] Edge agent reads `$EDGE_OS_EDGE_DIR/config.json` on startup (falls back to env vars, then built-in defaults)
- [x] `postinstall` sets `root:admin 775` on EdgeOS dir so admin-user Tauri app can write `config.json` without sudo
- [x] First-run setup wizard (`setup.html`) — Cloud URL, Team Hash, API Token fields
- [x] `save_config` Tauri command: writes `config.json`, stores token in OS keychain, restarts daemon via `osascript`/`pkexec`
- [x] Keychain: `keyring` crate (macOS Keychain / Linux libsecret) under service `com.sailoi.edgeos`
- [x] Settings menu item re-opens setup window for config changes

### 3E — Distribution & Packaging
> GStreamer is a system library (plugin-based, cannot be statically linked). The packaging strategy differs by platform. Both paths are required before Phase 6 live video ships.

**Linux — `.deb` + shell install script**
- Declare GStreamer as apt dependencies in `tauri.conf.json` → `bundle.deb.depends`:
  `libgstreamer1.0-0`, `gstreamer1.0-plugins-base`, `gstreamer1.0-plugins-good`, `gstreamer1.0-plugins-bad`, `gstreamer1.0-nice`
- `.deb` install triggers `apt-get` to pull GStreamer automatically — zero user friction
- GStreamer lands at `/usr/lib/gstreamer-1.0/` (default scan path) — edge binary finds plugins with no extra config
- Also ship a `curl -sSL https://get.edgeos.io | bash` shell script that detects the distro (`apt` / `dnf` / `yum` / `pacman`) and installs GStreamer + the edge daemon + systemd unit in one step. Covers distros beyond Debian/Ubuntu (RHEL, Fedora, Arch).
- `.rpm` via `bundle.rpm.depends` for RHEL/Fedora coverage (same plugin list, different package names: `gstreamer1-plugins-base` etc.)

**macOS — bundled GStreamer inside `.pkg`**
- Use **Cerbero** (GStreamer's own cross-platform build tool) to build a minimal, relocatable GStreamer bundle containing only the ~12 plugins needed:
  `coreelements`, `rtspsrc`, `rtpmanager`, `rtp`, `h264parse`, `rtph264`, `webrtc`, `nice`, `app`, `videoconvert`, `openh264`
  Resulting bundle: ~40–60 MB (vs. 700 MB full framework).
- Run `dylibbundler` on each plugin `.dylib` to rewrite hardcoded build-prefix paths to `@loader_path/../lib/` (makes the bundle fully relocatable).
- The `.pkg` installs the bundle to `/Library/Application Support/EdgeOS/gstreamer/` alongside the edge daemon binary.
- `postinstall` script writes `GST_PLUGIN_PATH` and `DYLD_LIBRARY_PATH` into the LaunchDaemon plist so the edge daemon finds GStreamer at boot without any user action.
- Test on a clean macOS VM (no Homebrew) to confirm no hidden system dependencies.

**License compliance**
- GStreamer core + all plugins used: LGPL 2.1. Safe to bundle alongside a proprietary or MIT-licensed product.
- Include a `LICENSES/gstreamer-lgpl-2.1.txt` file in the distribution and a one-line acknowledgement in the app's About screen.
- H.264 patents (MPEG LA): royalty-free tier applies for free-to-end-user distributions below 100k units/year. Track deployment numbers; obtain a licence before crossing that threshold.
- No `gst-plugins-ugly` or `gst-libav` used — avoids GPL and the most patent-sensitive codecs.

**Tasks:**
- [ ] `tauri.conf.json`: add `bundle.deb.depends` and `bundle.rpm.depends` for GStreamer packages
- [ ] `scripts/bundle-gstreamer-mac.sh`: Cerbero build → `dylibbundler` relocation → output to `app/gstreamer-bundle/`
- [ ] `tauri.conf.json`: add `bundle.resources` pointing at `app/gstreamer-bundle/**/*`
- [ ] `pkg-scripts/postinstall`: copy bundle to `/Library/Application Support/EdgeOS/gstreamer/`, patch LaunchDaemon plist with env vars
- [ ] `scripts/install.sh`: distro-detecting shell script for headless Linux installs
- [ ] Verify on clean macOS VM and clean Ubuntu/RHEL VMs before shipping
- [ ] CoreML execution provider for ONNX (Apple Neural Engine) — deferred to Phase 6 AI inference

### TODO — 3F: Mobile viewer
> Deferred. Tauri v2 mobile (iOS + Android) for viewing camera feeds and managing edges. Depends on Phase 6 camera MVP being complete first.

### Headless Linux (Pi / server)
> Critical for the Maker and MSP segments. Headless Linux devices (Raspberry Pi, VPS, home server) are the primary deployment target for DIY users and IT consultants. A smooth one-command install here is the difference between community adoption and a GitHub repo nobody uses.

- [ ] One-command install script: `curl -sSL https://get.edgeos.io | bash` — detects distro (`apt` / `dnf` / `yum` / `pacman`), installs GStreamer system packages, installs edge binary, writes systemd unit, starts service
- [ ] Quick-start guide: Pi-specific README (flash SD card → run install → scan QR code in cloud UI → done)
- [ ] `.deb` package with `postinst` that writes systemd unit and enables it on install (GStreamer pulled via `Depends:`)
- [ ] `.rpm` package for RHEL/Fedora/Rocky users (same approach, different package names)
- [ ] Documented uninstall path

### TODO — Windows
> Deferred. The Windows build would be a viewer + management UI only (no edge agent, no daemon) since SSH on Windows is not a meaningful use case and ONVIF cameras are network devices independent of host OS. Not worth the effort until there is clear demand.

---

## Phase 4 — Browser↔Edge P2P Foundation
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

### 4A — Edge: connection type routing
- [x] Add `connection_type` field to WEBRTC_OFFER payload: `"ssh"` vs `"camera"`
- [x] Edge routes `"ssh"` offers to existing SSH bridge handler (no change)
- [x] Edge routes `"camera"` offers to new stub camera handler — opens data channel, echoes pong to validate P2P

### 4B — Cloud: browser signaling path
- [x] LiveView JS hook: browser creates `RTCPeerConnection`, generates offer, sends to LiveView via `pushEvent`
- [x] LiveView forwards browser offer to edge via `EdgeSocket` (same `send/2` path as today)
- [x] LiveView receives edge answer + ICE candidates, forwards back to browser via `push_event`
- [x] TURN credentials passed to browser (same HMAC generation as SSH path)
- [x] Session scoped to the authenticated user — no unauthenticated signaling

### 4C — Validate end-to-end ✓
- [x] Browser opens data channel to edge, sends `{type: "ping"}`, edge replies `{type: "pong"}`
- [x] Confirmed: "✓ P2P validated. Direct browser ↔ edge data channel works. Cloud saw only signaling."
- [ ] Test via TURN relay (simulate NAT) to confirm relay path works from browser

### 4D — Define data channel protocol (spec only, no implementation)
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

## Phase 5 — Developer & Community Experience
> Prerequisite for any public launch or marketing effort. Traffic from Hacker News, Hackaday, or r/selfhosted converts to nothing without a good README, quick-start, and a working demo. This phase costs nothing but time and unlocks Priority 1 go-to-market (Makers + MSPs).

- [ ] **GitHub README overhaul** — hero section with screenshot/demo GIF, one-command quick-start, architecture diagram (privacy-first P2P flow), badges (build status, license)
- [ ] **Raspberry Pi quick-start guide** — step-by-step: flash SD card → `curl install` → QR code appears → scan in cloud UI → device online. Target: working in under 10 minutes
- [ ] **"How it works" page** — plain-language explanation of the WebRTC P2P architecture for non-engineers. Answers "is my video going to your servers?" definitively
- [ ] **Self-hosted cloud deployment guide** — Docker Compose one-liner for spinning up the cloud server on a VPS. Targets MSPs and IT consultants who want to run their own instance
- [ ] **Demo instance** — a live cloud server at `demo.edgeos.io` (or similar) with a sandboxed edge device, so people can explore the UI without installing anything
- [ ] **Changelog / release notes** — public CHANGELOG.md so the community can follow progress

---

## Phase 6 — Camera MVP
> Built on Phase 4 (browser↔edge P2P already validated).
>
> **Privacy principle: the cloud knows about edges, not cameras.**
> Camera lists, metadata, live frames, events, and thumbnails never touch the cloud server. The browser fetches all of this directly from the edge over the WebRTC data channel. The cloud's role is auth + signaling only — identical to Phase 4.
>
> **Two WebRTC connections per camera session:**
>
> **Connection 1 — Data channel** (control + metadata, already built)
> ```
> Browser opens /edges/:id/camera
>   → WebRTC data channel opens (cloud = signaling only)
>
> Camera list
>   → Browser sends: {"type": "LIST_CAMERAS"}
>   → Edge replies:  {"type": "CAMERA_LIST", "cameras": [{id, name, status}]}
>
> Camera thumbnail (for /edges dashboard preview and camera grid)
>   → Browser sends: {"type": "GET_THUMBNAIL", "camera_id": "cam-abc"}
>   → Edge replies:  {"type": "THUMBNAIL", "camera_id": "cam-abc", "data": <jpeg bytes>}
>   → Frame is the latest 1fps JPEG already in SharedFrame — no extra work on edge
>   → No cloud storage. Thumbnail lives on edge, fetched on demand. Offline edge = placeholder.
>
> Events
>   → Browser sends: {"type": "LIST_EVENTS", "camera_id": "cam-abc", "limit": 50}
>   → Edge replies:  {"type": "EVENT_LIST", "events": [{id, timestamp, class, confidence}]}
>   → Browser sends: {"type": "GET_THUMBNAIL", "event_id": "..."}
>   → Edge replies:  {"type": "THUMBNAIL", "event_id": "...", "data": <jpeg bytes>}
>
> Fence config
>   → Browser sends: {"type": "SET_FENCES", "camera_id": "cam-abc", "fences": [...]}
>   → Edge stores locally in config.json — cloud never sees fence config
> ```
>
> **Connection 2 — WebRTC video track** (live stream only)
> ```
> User selects a camera for live view
>   → Browser initiates a second RTCPeerConnection (media, not data)
>   → Cloud signals this offer to edge via existing WebSocket (connection_type: "camera")
>   → Edge spins up a GStreamer pipeline for that camera:
>        rtspsrc → rtph264depay → h264parse → rtph264pay → webrtcbin
>   → webrtcbin handles: RTP packetization, SDP profile-level-id negotiation,
>        RTCP PLI keyframe requests, ICE/DTLS transport
>   → Multiple viewers → tee element fans out to N webrtcbin instances,
>        one RTSP connection per camera regardless of viewer count
>   → Browser receives native MediaStream → renders in <video> tag
>   → No transcoding — H.264 passes through from camera to browser unchanged
>   → Latency ~200ms vs. JPEG polling which is choppy and slow
> ```
>
> **Separation principle — SSH WebRTC path is untouched:**
> ```
> connection_type: "ssh"    → handle_webrtc_offer()   [existing, webrtc crate, data channel → TCP:22]
> connection_type: "camera" → handle_camera_offer()   [new, GStreamer webrtcbin, video track]
> ```
> The routing key (`connection_type`) already exists in `main.rs`. The two paths share the same
> WebSocket signaling channel but are otherwise completely independent code paths.
>
> **Frame reuse — no redundant work:**
> ```
> RTSP (one connection per camera)
>   ├── GStreamer tee → webrtcbin (Connection 2, live view, N viewers)
>   └── retina + openh264 → JPEG → SharedFrame
>                             ├── localhost:4001/frame/:id  (Tauri local polling)
>                             └── data channel GET_THUMBNAIL  (Connection 1, cloud UI preview)
> ```
> The existing retina/openh264 JPEG path stays for thumbnails. GStreamer handles video only.
> Two RTSP connections per camera (one for each path) is acceptable — cameras handle multiple
> clients, and the thumbnail path is already working in production.
>
> **What this means for cloud storage:**
> - No `camera_device` table — cameras are an edge concern only
> - No event storage on cloud — events live on the edge, browser fetches them via data channel
> - No API endpoints for camera lists, frames, events, or thumbnails
> - Cloud stores only: users, teams, edges, sessions, AI Guard credit balances
> - For AI Guard: edge calls LLM directly using a short-lived token issued by cloud (text result only sent back to cloud — no image ever)
> - For push notifications: edge sends text-only event summary to cloud, cloud fires the push. No image, no metadata beyond what the user agreed to share.
>
> **Split responsibility:**
> - **Local cameras** (same LAN as the Tauri machine) → managed and viewed in the **Tauri desktop app**. Live feeds via `localhost:4001` HTTP endpoint from the edge agent. No cloud or WebRTC needed for local access.
> - **Remote cameras** (different site) → viewed in the **Phoenix cloud web UI** via browser↔edge WebRTC data channel. Cloud handles auth + signaling only.

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
- [x] Main app window with sidebar navigation (Cameras / Events / Settings)
- [x] Camera grid — mocked with fake CSS gradient feeds (`app/src/main.html`)
- [x] Camera onboarding wizard — Add Camera modal with scan + manual RTSP entry (UI only, no backend)
- [x] Events view — mocked event table with confidence bars (UI only, no backend)
- [x] Open main window from tray
- [x] Camera grid — wire up real JPEG snapshots from edge agent (`localhost:4001/frame/:id` polled every 2s, live badge + clock shown on success)
- [ ] Single camera full-screen view + event timeline (detail feed polls real frames at 1fps ✓; event sidebar is still mocked HTML)
- [ ] Digital fence configuration UI — draw and label fence polygons on a camera still frame (see Digital Fences section below)

### Digital Fences
> Not everything in a camera frame matters. A shop camera pointing at a street will see hundreds of pedestrians a day — without fences, every one of them triggers an AI Guard evaluation and burns credits. Digital fences are the primary mechanism for controlling AI Guard credit consumption while keeping alerts meaningful.
>
> **How it works:**
> - User draws one or more named polygons on a still frame of each camera (e.g. "Register area", "Back door", "Parking lot entrance")
> - Each fence can be independently enabled/disabled and assigned alert sensitivity
> - YOLO detections are filtered on the edge: only detections whose bounding box intersects an active fence are forwarded to AI Guard
> - Detections entirely outside all fences are discarded locally — zero cloud cost, zero credit spend
> - The fence config is stored on the edge device, not the cloud — no privacy leakage
>
> **Why this matters for the credit model:** A camera with no fences in a busy environment could easily generate 500+ AI Guard evaluations/day. The same camera with a well-placed fence on the door generates 5–20. Fences turn AI Guard from a runaway cost into a predictable, low spend. Users who configure fences well spend less and get better alerts — the incentives align.

**Fence UI tasks (Tauri app):**
- [ ] Still-frame capture from camera for fence drawing canvas
- [ ] Draw polygon tool — click to place vertices, close polygon, label it
- [ ] Edit / delete existing fences
- [ ] Per-fence toggles: enabled/disabled, sensitivity (all detections vs. person only vs. vehicle only)
- [ ] Preview overlay — show active fences on the live camera grid thumbnail

**Fence UI tasks (Cloud web UI):**
- [ ] Polygon drawing UI on camera still frame — frame fetched from edge via data channel
- [ ] Fence config sent to edge via `SET_FENCES` data channel message — never stored on cloud

**Fence backend tasks (Edge Rust client):**
- [ ] Store fence polygons in `config.json` per camera
- [ ] Point-in-polygon / bounding-box intersection check on every YOLO detection
- [ ] Metrics: log how many detections were fenced out vs. passed through (visible in Settings view)

### Edge client (Rust)

**Target hardware (in priority order):**
1. **Raspberry Pi 4/5 (headless Linux)** — canonical DIY device. Cheap, runs 24/7, huge community. Primary development and test target.
2. **Any headless Linux box** — NUC, old laptop, VPS-class machine. Same binary as Pi.
3. **Mac Mini** — plausible for small businesses that already have one. Tauri app runs as management UI.

**Target cameras (in priority order):**
1. **ONVIF/RTSP IP cameras** — Reolink, Hikvision, Dahua, Amcrest. Already deployed in SMB market. Single protocol regardless of edge hardware. A $30 Reolink is what DIYers and retail owners actually buy today. **Implement first.**
2. **USB cameras via V4L2** — Pi + USB webcam fallback for pure DIY setups with no IP cameras. Both paths converge at the same YOLO inference pipeline. **Implement second.**

**Tasks — RTSP path (Priority 1):**
- [x] Pull RTSP stream via `retina` + `openh264` (pure Rust, no FFmpeg dependency)
- [x] Extract frames at configurable fps (default 1fps, tunable per camera)
- [x] Frame differencing as cheap motion pre-filter — skip encode if scene is static
- [x] Serve last-frame JPEG on `localhost:4001/frame/:camera_id` for Tauri app polling
- [ ] YOLOv8n inference via `ort` crate (CPU first, CoreML on Apple Silicon later)
- [ ] **Digital fence enforcement** — only pass detections to AI Guard if bounding box intersects an active fence polygon. Detections outside all fences discarded locally — zero cloud cost.
- [ ] Trigger local recording on detection (FFmpeg → .mp4 clip)
- [x] Handle data channel messages: `LIST_CAMERAS` ✓, `GET_THUMBNAIL` ✓ — `LIST_EVENTS` and `SET_FENCES` not yet implemented
- [x] Serve camera thumbnail via data channel — resize to 320×180 before base64 encode to stay within SCTP message size limit; confirmed working in production
- [x] WebRTC video track: GStreamer pipeline per camera (`rtspsrc → rtph264depay → h264parse → rtph264pay → webrtcbin`). Signaling via existing WebSocket (`connection_type: "camera_video"`). Existing SSH WebRTC path (`handle_webrtc_offer`) untouched. PT negotiated from answer SDP and set explicitly on `rtph264pay` to avoid caps-race mismatch. Confirmed working in production.
- [ ] Multi-viewer fan-out: add `tee` element so N browser sessions share one RTSP connection per camera (currently a new RTSP connection is opened per viewer).
- [ ] RTSP protocol flexibility: remove hardcoded `protocols=tcp` — use GStreamer default (`protocols=4`, try UDP first, fall back to TCP) so cameras that only support UDP RTSP work out of the box.
- [ ] H265/HEVC camera support: transcode pipeline `rtph265depay ! h265parse ! avdec_h265 ! videoconvert ! x264enc ! rtph264pay` since WebRTC has no native H265 support. Deferred until there is demand.
- [ ] MJPEG camera support: encode pipeline `rtpjpegdepay ! jpegdec ! videoconvert ! x264enc ! rtph264pay`. Common on cheap/older cameras.
- [ ] Send text-only event summary to cloud for push notification dispatch (no image, no thumbnail)
- [ ] Send AI Guard token request to cloud; call Vertex AI / Bedrock directly with frames; send text result back to cloud

**Tasks — V4L2 path (Priority 2, Pi + USB camera):**
- [ ] Capture frames from V4L2 device (`/dev/video0`)
- [ ] Feed into same frame differencing + YOLO pipeline as RTSP path
- [ ] Camera discovery — list available `/dev/video*` devices for onboarding UI

### Cloud (Elixir/Phoenix) — minimal surface, privacy-first
> The cloud has no knowledge of cameras, events, frames, or thumbnails. All camera data stays on the edge and travels P2P to the browser. Cloud responsibilities are limited to what cannot be done on the edge.

- [ ] `POST /api/v1/ai_guard/token` — credit check, Vertex AI / Bedrock short-lived token generation, deduct credit, log issuance. No image data involved.
- [ ] Token redemption tracking — edge reports text result back; cloud marks token used, stores text summary only
- [ ] Rate limiter on token issuance per user per hour
- [ ] Push notification dispatch — edge sends `POST /api/v1/events/notify` with text-only summary (class, severity, camera name). Cloud fires ntfy.sh push. No image stored.

### Cloud Web UI (LiveView) — remote camera access
> LiveView is the shell only — opens the signaling path and hands control to browser JS. No camera data ever hits the cloud DB.

- [x] Live feed viewer page — `/edges/:id/camera` with WebRTC signaling hook (`camera.html.heex`, `camera.ex`)
- [x] `/edges/:id/dash` — WebRTC data channel opens on page load, `LIST_CAMERAS` fetches camera list, `GET_THUMBNAIL` auto-fetched for cameras with frames, thumbnails shown in grid. Confirmed working in production.
- [x] Camera list page — `LIST_CAMERAS` via data channel renders camera grid with thumbnails and Active/No signal badges
- [x] Live stream — browser opens second RTCPeerConnection (video track), renders in `<video>` tag. Cloud signals this offer to edge exactly like the data channel offer. Confirmed working in production.
- [ ] Events browser — send `LIST_EVENTS` + `GET_THUMBNAIL` via data channel, render feed
- [ ] Digital fence UI — polygon tool in browser, send `SET_FENCES` via data channel. Cloud never stores fence config.

---

## Phase 7 — Billing & Monetization
> Adds the billing layer for managed TURN relay and AI Guard credits. See BUSINESS_MODEL.md for pricing strategy, plan structure, and AI Guard architecture decisions.

- [ ] Stripe integration — relay subscription + AI Guard credit top-up
- [ ] Billing page in cloud web UI — plan, credit balance, top-up, invoice history
- [ ] Usage gate — TURN credential endpoint rejects without active relay subscription
- [ ] Credit balance per user, decremented $0.10 on each AI Guard token issuance
- [ ] Auto-pause AI Guard at $0 — token endpoint rejects with "top up to continue"
- [ ] Credit alert notifications at 50%, 20%, 10% balance (email + in-app)
- [ ] Weekly digest email — evaluations used, credits spent, top-triggered fences
- [ ] Webhook handler for Stripe events (failed payment → downgrade, cancellation → revoke)
- [ ] Sign-up flow — email + password, self-service, no sales call
- [ ] Team creation wizard on first login (currently manual)
- [ ] In-app upgrade prompt when user hits a paid feature on free tier
- [ ] `POST /api/v1/ai_guard/token` — credit check, Vertex AI / Bedrock short-lived token generation, deduct credit, log issuance
- [ ] Token redemption tracking — mark used when edge reports result
- [ ] Rate limiter on token issuance per user per hour

### AI Guard user controls (edge + cloud UI)
- [ ] Trigger hours per camera — start/end time, active days. Edge skips evaluation outside window.
- [ ] Frames per event — configurable 1–10, default 3. Show estimated cost per evaluation in UI.
- [ ] Event cooldown per fence — suppress re-evaluation from same fence for X min (default 5)
- [ ] Credit balance visible in camera settings — current balance + estimated evaluations remaining

---

## Phase 8 — ONVIF Multi-Camera Support
> Works with any IP camera, not just D-Link.

- [ ] WS-Discovery (multicast UDP) — auto-discover cameras on LAN
- [ ] ONVIF Profile S client — `GetStreamUri`, `GetProfiles`, `GetDeviceInformation`
- [ ] WS-UsernameToken authentication
- [ ] Camera auto-appears in UI after discovery
- [ ] Test with: Hikvision, Dahua, Reolink, Amcrest
- [ ] PTZ control UI
- [ ] ONVIF event subscriptions (receive motion events from camera's own sensor)

---

## Phase 9 — Mobile Viewer
> Airbnb hosts, property managers, and retail owners will ask "can I check my cameras from my phone?" on day one. This phase delivers a read-only mobile viewer — live feeds, event notifications, alert review. No camera management or config; that stays on desktop.
>
> Built on Tauri v2 mobile (iOS + Android from one codebase). Depends on Phase 6 camera feed being stable.

- [ ] iOS and Android build targets in Tauri v2 project
- [ ] Live camera feed view — WebRTC stream from edge, same P2P path as browser
- [ ] Events feed — thumbnail list, tap to view clip, dismiss / confirm alert
- [ ] Push notifications — urgent AI Guard alerts routed to mobile via ntfy or APNs/FCM
- [ ] Multi-site switcher — property managers with multiple edges can switch between them
- [ ] App Store + Google Play submission

---

## Phase 10 — Advanced AI & Model Management
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

**Phase 6 Camera MVP** — live WebRTC video stream from edge to browser is working in production (H264, single viewer). Next priorities: multi-viewer `tee` fan-out, RTSP protocol flexibility, and the Tauri local camera UI.
