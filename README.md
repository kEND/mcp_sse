# MCP over SSE

[![Releases](https://img.shields.io/hexpm/v/mcp_sse.svg)](https://github.com/kEND/mcp_sse/releases)
[![Documentation](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/mcp_sse/)
[![MCP Specification Version](https://img.shields.io/badge/spec-2024--11--05-blue)](https://modelcontextprotocol.io/specification/2024-11-05/index)
[![Downloads](https://img.shields.io/hexpm/dt/mcp_sse.svg)](https://hex.pm/packages/mcp_sse)
[![License](https://img.shields.io/badge/licence-MIT-blue.svg)](https://github.com/kEND/mcp_sse/blob/main/LICENSE)
[![CI](https://github.com/kEND/mcp_sse/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kEND/mcp_sse/actions/workflows/ci.yml?query=branch%3Amain)
[![Last Commit](https://img.shields.io/github/last-commit/kEND/mcp_sse.svg)](https://github.com/kEND/mcp_sse/commits/main)

This library provides a simple implementation of the Model Context Protocol (MCP) over Server-Sent Events (SSE).

For more information about the Model Context Protocol, visit:
[Model Context Protocol Documentation](https://modelcontextprotocol.io/introduction).

## Table of Contents

- [Features](#features)
- [Create your own MCP server](#create-your-own-mcp-server)
- [Installation](#installation)
  - [For Phoenix Applications](#for-phoenix-applications)
  - [For Plug Applications with Bandit](#for-plug-applications-with-bandit)
- [Usage](#usage)
  - [With MCP Inspector](#with-mcp-inspector)
  - [With Cursor](#with-cursor)
- [Configuration](#configuration)
  - [Port and HTTPS](#port-and-https)
  - [Paths](#paths)
  - [Keepalive](#keepalive)
- [Quick Demo](#quick-demo)
- [Other Notes](#other-notes)
  - [Example Client Usage](#example-client-usage)
  - [Session Management](#session-management)
  - [MCP Response Formatting](#mcp-response-formatting)
- [Contributing](#contributing)

## Features

- Full MCP server implementation
- SSE connection management
- JSON-RPC message handling
- Tool registration and execution
- Session management
- Automatic ping/keepalive
- Error handling and validation

## Create your own MCP server

You must implement the `MCPServer` behaviour.

You only need to implement the required callbacks (`handle_ping/1` and `handle_initialize/2`) and any optional callbacks for features you want to support.

The `use MCPServer` macro provides:
- Built-in message routing
- Protocol version validation
- Default implementations for optional callbacks
- JSON-RPC error handling
- Logging

See [`DefaultServer`](https://hexdocs.pm/mcp_sse/MCPServer.html#module-example) for a default implementation of the `MCPServer` behaviour.

## Installation

### For Phoenix Applications:

1. Add the required configuration to `config/config.exs`:

```elixir
# Configure MIME types for SSE
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

# Configure the MCP Server
config :mcp_sse, :mcp_server, YourApp.YourMCPServer
```

2. Add to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mcp_sse, "~> 0.1.5"}
  ]
end
```

3. Configure your router (`lib/your_app_web/router.ex`):

```elixir
pipeline :sse do
  plug :accepts, ["sse"]
end

scope "/" do
  pipe_through :sse
  get "/sse", SSE.ConnectionPlug, :call
  post "/message", SSE.ConnectionPlug, :call
end
```

4. Run your application:

```bash
mix phx.server
```

### For Plug Applications with Bandit:

1. Create a new Plug application with supervision:

```bash
mix new your_app --sup
```

2. Add the required configuration to `config/config.exs`:

```elixir
import Config

# Configure MIME types for SSE
config :mime, :types, %{
  "text/event-stream" => ["sse"]
}

# Configure the MCP Server
config :mcp_sse, :mcp_server, YourApp.YourMCPServer
```

3. Add dependencies to `mix.exs`:

```elixir
def deps do
  [
    {:mcp_sse, "~> 0.1.5"},
    {:plug, "~> 1.14"},
    {:bandit, "~> 1.2"}
  ]
end
```

4. Configure your router (`lib/your_app/router.ex`):

```elixir
defmodule YourApp.Router do
  use Plug.Router

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["text/*"],
    json_decoder: JSON

  plug :match
  plug :ensure_session_id
  plug :dispatch

  # Middleware to ensure session ID exists
  def ensure_session_id(conn, _opts) do
    case get_session_id(conn) do
      nil ->
        # Generate a new session ID if none exists
        session_id = generate_session_id()
        %{conn | query_params: Map.put(conn.query_params, "sessionId", session_id)}
      _session_id ->
        conn
    end
  end

  # Helper to get session ID from query params
  defp get_session_id(conn) do
    conn.query_params["sessionId"]
  end

  # Generate a unique session ID
  defp generate_session_id do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  forward "/sse", to: SSE.ConnectionPlug
  forward "/message", to: SSE.ConnectionPlug

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
```

5. Set up your application supervision (`lib/your_app/application.ex`):

```elixir
defmodule YourApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Bandit, plug: YourApp.Router, port: 4000}
    ]

    opts = [strategy: :one_for_one, name: YourApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

6. Run your application:

```bash
mix run --no-halt
```

## Usage

### With MCP Inspector

- Start the inspector: 

```bash
MCP_SERVER_URL=localhost:4000 npx @modelcontextprotocol/inspector@latest
```

- Navigate to http://localhost:6274/
- Make sure your server is running
- Click `Connect`
- You can now list tools and call them

### With Cursor

- Open Cursor Settings
- Navigate to the MCP tab
- Click `Add new global MCP server`
- Fill in the `~/.cursor/mcp.json` with:

```json
{
  "mcpServers": {
    "your-mcp-server": {
      "url": "http://localhost:4000/sse"
    }
  }
}
```

- Make sure your server is running
- Ask Cursor to run one of your tools

## Configuration

### Port and HTTPS

The Bandit server can be configured with additional options in your application module:

```elixir
# Example with custom port and HTTPS
children = [
  {Bandit,
    plug: YourApp.Router,
    port: System.get_env("PORT", "4000") |> String.to_integer(),
    scheme: :https,
    certfile: "priv/cert/selfsigned.pem",
    keyfile: "priv/cert/selfsigned_key.pem"
  }
]
```

### Paths

You can customize the paths used for the SSE and message endpoints:

```elixir
config :mcp_sse,
  sse_path: "/mcp/sse",    # Default: "/sse"
  message_path: "/mcp/msg" # Default: "/message"
```

This allows you to use custom paths in your routers:

```elixir
# Phoenix
scope "/mcp" do
  pipe_through :sse
  get "/sse", SSE.ConnectionPlug, :call
  post "/msg", SSE.ConnectionPlug, :call
end

# Plug
forward "/mcp/sse", to: SSE.ConnectionPlug
forward "/mcp/msg", to: SSE.ConnectionPlug
```

### Keepalive

The SSE connection sends periodic keepalive pings to prevent connection timeouts.
You can configure the ping interval or disable it entirely in `config/config.exs`:

```elixir
# Set custom ping interval (in milliseconds)
config :mcp_sse, :sse_keepalive_timeout, 30_000  # 30 seconds

# Or disable pings entirely
config :mcp_sse, :sse_keepalive_timeout, :infinity
```

## Quick Demo

To see the MCP server in action:

1. Start a server in one terminal:
```bash
# Our example server
elixir dev/example_server.exs

# Your Phoenix application
mix phx.server

# Your Plug application
mix run --no-halt
```

2. In another terminal, run the demo client script:
```bash
elixir dev/example_client.exs
```

The client script will:
- Connect to the SSE endpoint
- Initialize the connection
- List available tools
- Call the upcase tool with example input
- Display the results of each step

This provides a practical demonstration of the Model Context Protocol flow and server capabilities.

## Other Notes

### Example Client Usage

```javascript
// Connect to SSE endpoint
const sse = new EventSource('/sse');

// Handle endpoint message
sse.addEventListener('endpoint', (e) => {
  const messageEndpoint = e.data;
  // Use messageEndpoint for subsequent JSON-RPC requests
});

// Send initialize request
fetch('/message?sessionId=YOUR_SESSION_ID', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: '2024-11-05',
      capabilities: {}
    }
  })
});
```

### Session Management

The MCP SSE server requires a session ID for each connection. The router automatically:
- Uses an existing session ID from query parameters if provided
- Generates a new session ID if none exists
- Ensures all requests to `/sse` and `/message` endpoints have a valid session ID

### MCP Response Formatting

When implementing tool responses in your MCP server, the content must follow the MCP specification for content types.
The response content should be formatted as one of these types:

```elixir
# Text content
{:ok,
 %{
   jsonrpc: "2.0",
   id: request_id,
   result: %{
     content: [
       %{
         type: "text",
         text: "Your text response here"
       }
     ]
   }
 }}

# Image content
{:ok,
 %{
   jsonrpc: "2.0",
   id: request_id,
   result: %{
     content: [
       %{
         type: "image",
         data: "base64_encoded_image_data",
         mimeType: "image/png"
       }
     ]
   }
 }}

# Resource reference
{:ok,
 %{
   jsonrpc: "2.0",
   id: request_id,
   result: %{
     content: [
       %{
         type: "resource",
         resource: %{
           name: "resource_name",
           description: "resource description"
         }
       }
     ]
   }
 }}
```

For structured data like JSON, you should convert it to a formatted string:

```elixir
def handle_call_tool(request_id, %{"name" => "list_companies"} = _params) do
  companies = fetch_companies()  # Your data fetching logic

  {:ok,
   %{
     jsonrpc: "2.0",
     id: request_id,
     result: %{
       content: [
         %{
           type: "text",
           text: JSON.encode!(companies, pretty: true)
         }
       ]
     }
   }}
end
```

For more details on response formatting, see the [MCP Content Types Specification](https://spec.modelcontextprotocol.io/specification/2024-11-05/basic/messages/#responses).

## Contributing

- Fork the repository and clone it
- Create a new branch in your fork
- Make your changes and commit them
- Push the changes to your fork
- Open a pull request in upstream