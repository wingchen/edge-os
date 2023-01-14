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

We can use the phoenix command to build releases:

```
MIX_ENV=prod mix release 
```

The the binaries will be built at:

```
[wingchen@WT-Garuda cloud]$ ls _build/prod/rel/edge_os_cloud/bin/
edge_os_cloud  edge_os_cloud.bat  migrate  migrate.bat  server  server.bat
```

The `_build/prod/rel/edge_os_cloud/bin/server` file is the one you want to run on server.

## Install or Update in server

We also provide an `install.sh` script for you to install or update EdgeOS server side in a x86 server environment.
You won't need to clone the entire repo if all you want to do is to install EdgeOS server in your x86 linux server.
You only have to download the latest version of `install.sh`, update the env vars, and run it with `sudo`.

It downloads the latest binary, configures env vars, and then installs EdgeOS server as a systemd service in the linux server.

# UI Template

The UI template is based on the MIT project: `Start Bootstrap - SB Admin 2` 
https://github.com/StartBootstrap/startbootstrap-sb-admin-2 
