# edge-os

`edge-os` gathers a bunch of tools for edge device hackers to manage their edge machines without having to configure port-forwarding.

It should also address many common features that's absolutely required when it comes to scaling up with edge machines.

I will gradually add in code when I am not working on my day job.

# Target Features

- [x] SSH: ssh in from remote without port-forwarding
- [x] Metrics: collect basic CPU/Memory/Disk/Tmp/Process metrics
- [x] Metrics: user defined metrics that can be sent to EdgeOS via file socket
- [x] Manual Edge Software Update: provide a clean way for the daemon running on edge to update
- [x] Metrics: collect the GPU tmp and usage data from NV Jetson SoCs 
- [ ] Security: to make sure that we control where packets can be sent and received
- [ ] OTA: so that users will be able to deploy and update long running codes
- [ ] OTA self: EdgeOS will be able to update itself
- [ ] Group Commands: so that theh users will be able to do map/reduce kind of command execution in edge machines altogether.
- [ ] File Upload: user file upload to the system for more server processing

# Tested SoCs (edge computers)

- [x] rasberry pi 3 with rasberry pi OS
- [x] rasberry pi 4 with ubuntu
- [x] NVIDIA Jetson AGX Xavier with Ubuntu 22.02
- [x] MacOS on M1/M2 chips but with manually built EdgeOS and websocat
- [ ] The SoCs what run various Linux kernels (like Android but only with the `adb`)

# Language Used

- `server`: elixir, because I like the OTA from erlang
- `edge`: rust, because I wanna learn it

# License

MIT
