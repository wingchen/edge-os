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

# Target Features

- [x] create device UUID if no uuid is found locally
- [x] connect back to mothership via websocket
- [ ] check if the local ssh server is available
- [ ] allow remote ssh in even when the IoT device is behind firewall
- [ ] allow whitelisted packets in and out of the device

# Env Vars

- `EDGE_OS_EDGE_DIR`: full dir path to where the `edge` data is stored
- `EDGE_OS_CLOUD_URL`: full websocket path to where the `edge` should connect to, exp: `wss://edge.sailoi.com`

# Run test cases

```
RUST_LOG=debug cargo test -- --test-threads=1
```
