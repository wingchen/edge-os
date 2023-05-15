# edge-os-edge

`edge-os-edge` is meant to run in IoT devices. It connects back to the mothership with websockets and retry connection when disconnected. The IoT cluster owner can then send commands to devices via the cloud portal.

To run this in your SoC and have it function normally, you will have to:
- give it `sudo` privileges
- make it into a service with `systemd` or something likewise

# SSH bridging credit

When it comes to the heavy lifting of the SSH feature, `websocat`(https://github.com/vi/websocat) does a big part of it.

1. An edge device gets a ssh request from clould.
2. It starts a `websocat` session to bridge the local ssh onto a cloud session with websocket.
3. Cloud then bridges the ssh session with TCP socket to the user. 

# Env Vars

- `EDGE_OS_EDGE_DIR`: full dir path to where the `edge` data is stored
- `EDGE_OS_CLOUD_URL`: full websocket path to where the `edge` should connect to, exp: `wss://edge.sailoi.com`

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

I would also suggest to use `rust-musl-cross`(https://github.com/rust-cross/rust-musl-cross) if you are to support multiple platforms.

The official documentation is great already. For example, if you are on your PC but building for resberry pi 4:

```
docker pull messense/rust-musl-cross:arm-musleabi

alias rust-musl-builder='docker run --rm -it -v "$(pwd)":/home/rust/src messense/rust-musl-cross:arm-musleabi'

rust-musl-builder cargo build --release
```

We can think about hooking it up to CI in the future for each release.

## Deploying an Edge on Mac OS

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
