# edge-os-edge

`edge-os-edge` is meant to run in IoT devices. It connects back to the mothership with websockets and retry connection when disconnected. The IoT cluster owner can then send commands to devices via the cloud portal.

To run this in your SoC and have it function normally, you will have to:
- give it `sudo` privileges
- make it into a service with `systemd` or something likewise

# Target Features

- [x] create device UUID if no uuid is found locally
- [ ] connect back to mothership via websocket
- [ ] allow remote ssh in even when the IoT device is behind firewall
- [ ] allow whitelisted packets in and out of the device


# Run test cases

```
RUST_LOG=debug cargo test -- --test-threads=1
```
