# edge-os-edge

`edge-os-edge` is the edge agent binary. It connects back to the cloud over WebSocket/WebRTC and keeps the connection alive.

> **Distribution:** for macOS and Linux desktop, use the Tauri app in `app/` — it bundles this binary and installs it as a system daemon automatically. See [`app/README.md`](../app/README.md) for the full build and install flow.
>
> Direct use of this binary (without the Tauri app) is for headless Linux devices (Pi, server) only.

# Env Vars

- `EDGE_OS_EDGE_DIR`: full dir path to where the `edge` data is stored
- `EDGE_OS_CLOUD_URL`: full websocket path to where the `edge` should connect to, exp: `wss://edge.sailoi.com`

# Development Workflow

There are two ways to run the edge agent depending on what you're working on:

## Edge-only (testing cloud connectivity)

Use this when iterating on edge code — no Tauri involved, fast feedback loop.

```bash
cargo build && ./local.sh --local
```

`--local` reads config from `test_data/config.json`. Set it up once:

```bash
mkdir -p test_data
echo '{"cloud_url":"wss://edgeos.sailoi.com","team_hash":"YOUR_TEAM_HASH"}' > test_data/config.json
```

## Full stack (Tauri UI + edge agent)

The Tauri app writes config to the system path and reads `status.json` from the same place:

| Platform | System path |
|----------|-------------|
| macOS    | `/Library/Application Support/EdgeOS/` |
| Linux    | `/opt/edge-os-edge/` |

`local.sh` (without `--local`) automatically uses the system path for the current OS. The recommended dev flow:

**Step 1 — prepare the system config dir (once, Linux only):**
```bash
sudo mkdir -p /opt/edge-os-edge && sudo chmod 777 /opt/edge-os-edge
```

**Step 2 — run the Tauri app and fill in the setup wizard:**
```bash
cd ../app && npm run dev
```
Enter your Cloud URL and Team Hash. The Tauri app writes `config.json` to the system path and opens the main window.

**Step 3 — run the edge agent in a second terminal:**
```bash
./local.sh
```
The agent reads `config.json` from the system path, connects to the cloud, and writes `status.json`. The Tauri UI polls `status.json` every 5 seconds and flips to "Connected".

**Troubleshooting:**
- Tauri shows "Not running" → the edge agent isn't running. Run `./local.sh` in the edge directory.
- No new edge appears in the cloud dashboard → same cause, the agent never connected.
- `Permission denied` writing config → run Step 1 above to make the system dir writable.

# Run test cases

```
RUST_LOG=debug cargo test -- --test-threads=1
```

# Building

This project can be built for production simply with `cargo`. Just do this:

```
cargo build --release
``` 

## Cross-compliation for different platforms

I would also suggest to use `cross`(https://github.com/cross-rs/cross) if you are to support multiple platforms.

The official documentation is great already. For example, if you are on your PC but building for resberry pi:

```
cross build --target x86_64-unknown-linux-gnu --release
```

We can think about hooking it up to CI in the future for each release.

Currently, we have 4 formal releases:

- `arm-unknown-linux-gnueabi`: for devices with older ARM CPUs like old resberry PIs
- `aarch64-unknown-linux-gnu`: for devices with ARM 64 bit CPUs like Nvidia tegra SoCs, or resberry PI4s
- `x86_64-unknown-linux-gnu`: regular linux PCs, with AMD or Intel CPUs
- `i686-unknown-linux-gnu`: older linux PCs, with 32 bit AMD or Intel CPUs

## Deploying an Edge on Mac OS

EdgeOS also supports Mac OS on M1/M2 chips. All you need to do is to compile edge from the source and place the binary file at `/opt/edge-os-edge/edgeos_edge`.

### Come up with a `launchctl` config file

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>com.sailoi.edgeos</string>
    <key>ProgramArguments</key>
    <array>
      <string>/opt/edge-os-edge/edgeos_edge</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/opt/edge-os-edge/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/opt/edge-os-edge/stderr.log</string>
    <key>KeepAlive</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
      <key>EDGE_OS_EDGE_DIR</key>
      <string>/opt/edge-os-edge</string>
      <key>EDGE_OS_CLOUD_TEAM_HASH</key>
      <string>the_team_hash_goes_here</string>
      <key>EDGE_OS_CLOUD_URL</key>
      <string>wss://edgeos.sailoi.com</string>
    </dict>
  </dict>
</plist>
```

### Move the file to the right place in the system 

```
sudo cp /path/to/com.sailoi.edgeos.plist /Library/LaunchDaemons/
```

### Use the following system commands to enable and start EdgeOS the process

```
launchctl unload com.sailoi.edgeos.plist
launchctl load com.sailoi.edgeos.plist

launchctl enable system/com.sailoi.edgeos.plist
launchctl start com.sailoi.edgeos.plist
```
