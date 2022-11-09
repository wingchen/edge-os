# edge-os

`edge-os` gathers a bunch of tools for edge device hackers to manage their edge machines without having to configure port-forwarding.

It should also address many common features that's absolutely required when it comes to scaling up with edge machines.

I will gradually add in code when I am not working on my day job.

# Target Features

- [] SSH: ssh in from remote without port-forwarding
- [] Metrics: collect basic CPU/Memory/Disk/GPU metrics
- [] Security: to make sure that we control where packets can be sent and received
- [] OTA: so that users will be able to deploy and update long running codes
- [] Group Commands: so that theh users will be able to do map/reduce kind of command execution in edge machines altogether.

# Language Used

- `server`: elixir, because I like the OTA from erlang
- `edge`: go or rust, probably going with `rust` first, because I like it better

# License

MIT
