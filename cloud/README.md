# EdgeOsCloud

`EdgeOsCloud` is coded up with Elixir and Phoenix web framework. 

To start your Phoenix server:

  * Install dependencies with `mix deps.get`
  * Create and migrate your database with `mix ecto.setup`
  * Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

# Commands I often use

When it comes to compilation:

```
mix compile --warnings-as-errors
```

When it comes to testing locally, first set up your Linux Environment Variables for google and github login:

```
export GOOGLE_CLIENT_ID=something_google_client_id
export GOOGLE_CLIENT_SECRET=something_google_client_secret
export GITHUB_CLIENT_ID=something_github_client_id
export GITHUB_CLIENT_SECRET=something_github_client_secret
```

Then run the following command to start the local server:

```
docker-compose up && phx.server
```

# UI Template

The UI template is based on the MIT project: `Start Bootstrap - SB Admin 2` 
https://github.com/StartBootstrap/startbootstrap-sb-admin-2 

# Target Features

- [ ] configure db connections with env vars
- [ ] configure redis connections with env vars
- [x] stand up websocket server for edges
- [x] mark the edges as online when they connect through websocket
- [ ] allow remote ssh connections to the edges
- [ ] make sure error happens if ssh connection is not established correctly
