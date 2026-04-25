# EdgeOsCloud

`EdgeOsCloud` is coded up with Elixir and Phoenix web framework. 

To start your Phoenix server:

  * Install dependencies with `mix deps.get`
  * Create and migrate your database with `mix ecto.setup`
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`127.0.0.1:4000`](http://127.0.0.1:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

# Commands I often use

## When it comes to compilation:

```
mix compile --warnings-as-errors
```

## When it comes to testing locally

First set up your Linux Environment Variables for google and github login:

```
export GOOGLE_CLIENT_ID=something_google_client_id
export GOOGLE_CLIENT_SECRET=something_google_client_secret
export GITHUB_CLIENT_ID=something_github_client_id
export GITHUB_CLIENT_SECRET=something_github_client_secret
```

Then run the following command to start the local server:

```
docker-compose up && mix phx.server
```

## Building for releases

### With Docker (recommended — matches production Debian x86_64)

```bash
docker build --platform linux/amd64 -t edgeos-cloud .
```

**Run as a container:**
```bash
docker run --env-file .env -p 443:443 edgeos-cloud
```

**Extract the release binary for traditional systemd deployment:**
```bash
docker create --name edgeos-extract edgeos-cloud
docker cp edgeos-extract:/app/. ./edge_os_cloud_release/
docker rm edgeos-extract
rsync -a ./edge_os_cloud_release/ user@edgeos-prod-01:/opt/edgeos/edge_os_cloud/
```

Then on the server: `sudo systemctl restart edge-os`

### Without Docker (requires matching Elixir/OTP on build machine)

```
MIX_ENV=prod mix release
```

The binaries will be built at:

```
_build/prod/rel/edge_os_cloud/bin/
edge_os_cloud  migrate  server
```

The `server` script is the one you want to run on the server.

## Install or Update in server

We also provide an `install.sh` script for you to install or update EdgeOS server side in a x86 server environment.
You won't need to clone the entire repo if all you want to do is to install EdgeOS server in your x86 linux server.
You only have to download the latest version of `install.sh`, update the env vars, and run it with `sudo`.

It downloads the latest binary, configures env vars, and then installs EdgeOS server as a systemd service in the linux server.

# UI Template

The UI template is based on the MIT project: `Start Bootstrap - SB Admin 2` 
https://github.com/StartBootstrap/startbootstrap-sb-admin-2 
