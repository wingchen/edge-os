![dashborad](https://github.com/wingchen/edge-os/assets/798321/4f0471af-ec75-4a26-b3cc-51f022391829)

# edge-os

`edge-os` gathers a bunch of tools for edge device hackers to manage their edge machines without having to configure port-forwarding.

A fully hosted version can be found here at [edge.sailoi.com](https://edge.sailoi.com/). I will come up with a dockerized version of server later on.

It should also address many common features that's absolutely required when it comes to scaling up with edge machines.

I will gradually add in code when I am not working on my day job.

# Builds and deployments

- [Building EdgeOS for cloud and edge](https://github.com/wingchen/edge-os/wiki/Building-EdgeOS-for-cloud-and-edge)
- [Deploying EdgeOS to self-hosted cloud](https://github.com/wingchen/edge-os/wiki/Deploying-EdgeOS-to-self-hosted-cloud)
- [Deploying EdgeOS to edge to connect to your self-hosted cloud](https://github.com/wingchen/edge-os/wiki/Deploying-EdgeOS-to-edge-to-connect-to-your-self-hosted-cloud)

# Usages, other docs and tutorials

## General Admin

1. [Creating an account or logging in](https://github.com/wingchen/edge-os/wiki/Creating-an-account-or-logging-in)
2. [Creating a team for your edges](https://github.com/wingchen/edge-os/wiki/Creating-a-team-for-your-edges)
3. [Getting an edge connected to your team, or updating a connected edge](https://github.com/wingchen/edge-os/wiki/Getting-an-edge-connected-to-your-team,-or-updating-a-connected-edge)
4. [Adding members or admins to your team](https://github.com/wingchen/edge-os/wiki/Adding-members-or-admins-to-your-team)

## Working with your edges

1. [Connecting into your edge via SSH](https://github.com/wingchen/edge-os/wiki/Connecting-into-your-edge-via-SSH)
2. [Sending or getting files from edges with scp](https://github.com/wingchen/edge-os/wiki/Sending-or-getting-files-from-edges-with-scp)
3. [Connecting into your edge with xrdp for Windows-like GUI (remote desktop)](https://github.com/wingchen/edge-os/wiki/Connecting-into-your-edge-with-xrdp-for-Windows-like-GUI-(remote-desktop))
4. [Check the basic metrics of your edge, including tegra GPU](https://github.com/wingchen/edge-os/wiki/Check-the-basic-metrics-of-your-edge,-including-tegra-GPU)

## Advanced

1. [Building EdgeOS for cloud and edge](https://github.com/wingchen/edge-os/wiki/Building-EdgeOS-for-cloud-and-edge)
2. [Deploying EdgeOS to self-hosted cloud](https://github.com/wingchen/edge-os/wiki/Deploying-EdgeOS-to-self-hosted-cloud)
3. [Deploying EdgeOS to edge to connect to your self-hosted cloud](https://github.com/wingchen/edge-os/wiki/Deploying-EdgeOS-to-edge-to-connect-to-your-self-hosted-cloud)

## API Doc

1. [Getting your user key and get connected](https://github.com/wingchen/edge-os/wiki/Getting-your-user-key-and-get-connected)

# Issues and feature requests

Please feel free to use the github for these: [https://github.com/wingchen/edge-os/issues](https://github.com/wingchen/edge-os/issues).

# Language Used

- `server`: elixir, because I like the OTA from erlang
- `edge`: rust, because I wanna learn it

# License

MIT
