# EdgeOS App

The Tauri v2 desktop application for EdgeOS. This is the primary distribution for macOS and Linux desktop going forward — it installs the edge agent as a system-level OS daemon alongside the menubar management UI.

## Platform support

| Platform | Role |
|---|---|
| macOS | Edge agent (system daemon) + menubar UI |
| Linux desktop | Edge agent (system daemon) + menubar UI |
| Windows | TODO — viewer/management UI only, no daemon |
| Linux headless (Pi/server) | TODO — use `edge/` directly with systemd |

## Prerequisites

- [Rust](https://rustup.rs/) with the target for your platform
- [Node.js](https://nodejs.org/) 18+
- macOS: Xcode command-line tools (`xcode-select --install`)
- Linux: `libwebkit2gtk-4.1-dev`, `libayatana-appindicator3-dev`

## Build order

The edge binary must be compiled before the Tauri app, since Tauri bundles it as a sidecar.

```bash
# 1. Build the edge agent binary
cd edge
cargo build --release

# 2. Build the Tauri app (bundles the edge binary as a sidecar)
cd ../app
npm install
npm run build

# 3. macOS only: wrap the .app into a .pkg installer
./scripts/build-macos-pkg.sh
```

The `.pkg` is what you distribute. It installs `EdgeOS.app` into `/Applications` and registers the edge agent as a LaunchDaemon at `/Library/LaunchDaemons/com.sailoi.edgeos.plist`.

## Development

```bash
cd app
npm run dev
```

This launches the app with hot-reload. The tray icon appears in the menu bar.

Note: in dev mode the daemon status check still queries `launchctl`/`systemctl`, so it will show `○ Daemon not installed` unless the LaunchDaemon is already registered from a previous `.pkg` install.

## macOS daemon paths

| Path | Purpose |
|---|---|
| `/Applications/EdgeOS.app` | Tauri UI app |
| `/Library/Application Support/EdgeOS/edge-os-edge` | Edge agent binary |
| `/Library/Application Support/EdgeOS/device_id` | Persistent device identity |
| `/Library/Application Support/EdgeOS/device_password` | Persistent device password |
| `/Library/LaunchDaemons/com.sailoi.edgeos.plist` | LaunchDaemon registration |
| `/var/log/edgeos.log` | Daemon stdout |
| `/var/log/edgeos-error.log` | Daemon stderr |

## Linux daemon

After installing the app, run once with sudo to register the systemd service:

```bash
sudo ./scripts/install-linux-daemon.sh
```

TODO (Phase 2E): fold this into the `.deb` postinst script so it runs automatically.

## Tray status

The menubar icon updates every 5 seconds based on what the daemon reports:

| Status | Meaning |
|---|---|
| `● Connected` | Daemon running, WebSocket connected to cloud |
| `◌ Connecting...` | Daemon running, establishing connection |
| `○ Disconnected` | Daemon running, WebSocket dropped (will auto-reconnect) |
| `○ Daemon stopped` | Daemon process not running (plist/service exists) |
| `○ Daemon not installed` | `.pkg`/service not installed |

The daemon writes its state to `$EDGE_OS_EDGE_DIR/status.json` on every transition. The UI reads this file — no socket or port needed.

## Configuring the edge agent

The edge agent reads its team hash and cloud URL from environment variables set in the daemon config:

- **macOS**: edit `/Library/LaunchDaemons/com.sailoi.edgeos.plist`, add `EDGE_OS_CLOUD_TEAM_HASH` and `EDGE_OS_CLOUD_URL` under `EnvironmentVariables`, then reload with `sudo launchctl unload /Library/LaunchDaemons/com.sailoi.edgeos.plist && sudo launchctl load /Library/LaunchDaemons/com.sailoi.edgeos.plist`
- **Linux**: edit `/etc/systemd/system/edge-os.service`, add env vars under `[Service]`, then `sudo systemctl daemon-reload && sudo systemctl restart edge-os`

TODO (Phase 2D): the first-run setup wizard will handle this automatically.
