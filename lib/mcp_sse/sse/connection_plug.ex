defmodule SSE.ConnectionPlug do
  @moduledoc """
  A Plug for handling Server-Sent Events (SSE) connections with Model Context Protocol (MCP) support.

  Query params:
    * `sessionId` - The session ID for the connection

  This plug provides two endpoints:
    * `/sse` - Establishes the SSE connection
    * `/message` - Handles JSON-RPC messages for the Model Context Protocol

  ## Usage in Phoenix Router

      pipeline :sse do
        plug :accepts, ["sse"]
      end

      scope "/" do
        pipe_through :sse
        get "/sse", SSE.ConnectionPlug, :call
        post "/message", SSE.ConnectionPlug, :call
      end

  ## Usage in Plug Router

      forward "/sse", to: SSE.ConnectionPlug
      forward "/message", to: SSE.ConnectionPlug

  The paths can be configured in your application config:

      config :mcp_sse,
        sse_path: "/mcp/sse",
        message_path: "/mcp/msg"
  """

  import Plug.Conn
  require Logger

  alias MCP.MessageRouter
  alias SSE.ConnectionRegistry
  alias SSE.ConnectionState

  @sse_path Application.compile_env(:mcp_sse, :sse_path, "/sse")
  @message_path Application.compile_env(:mcp_sse, :message_path, "/message")
  @sse_keepalive_timeout Application.compile_env(:mcp_sse, :sse_keepalive_timeout, 15_000)

  # Standard Plug callback
  @doc false
  def init(opts), do: opts

  # Standard Plug callback
  @doc false
  def call(%Plug.Conn{request_path: @sse_path, method: "POST"} = conn, _opts) do
    conn
    |> put_status(405)
    |> send_error(405, "Method not allowed")
  end

  # Standard Plug callback
  @doc false
  def call(%Plug.Conn{request_path: @sse_path} = conn, _opts) do
    handle_sse(conn)
  end

  # Standard Plug callback
  @doc false
  def call(%Plug.Conn{request_path: @message_path} = conn, _opts) do
    handle_message(conn)
  end

  def call(conn, _opts), do: conn

  defp send_json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(conn.status || 200, JSON.encode!(data))
  end

  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(%{error: message}))
  end

  defp send_jsonrpc_error(conn, id, code, message, data \\ nil) do
    error = %{
      code: code,
      message: message
    }

    error = if data, do: Map.put(error, :data, data), else: error

    response = %{
      jsonrpc: "2.0",
      id: id,
      error: error
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(response))
  end

  defp handle_sse(conn) do
    session_id = generate_session_id()
    {:ok, state_pid} = ConnectionState.start_link(session_id)
    # Set SSE pid in connection state
    ConnectionState.set_sse_pid(state_pid, self())

    conn
    |> setup_sse_connection()
    |> register_connection(session_id, state_pid)
    |> send_initial_message(session_id)
    |> start_sse_loop(session_id, state_pid)
  end

  defp handle_message(conn) do
    Logger.info("Received POST message")
    params = conn.body_params
    Logger.debug("Raw params: #{inspect(params, pretty: true)}")

    with {:ok, session_id} <- get_session_id(conn),
         {:ok, {sse_pid, state_pid}} <- lookup_session(session_id),
         {:ok, message} <- validate_jsonrpc_message(params) do
      # Record client activity
      ConnectionState.record_activity(state_pid)

      # Handle initialization sequence
      case message do
        %{"method" => "initialize"} = msg ->
          Logger.info("Routing MCP message - Method: initialize, ID: #{msg["id"]}")
          Logger.debug("Full message: #{inspect(msg, pretty: true)}")
          ConnectionState.handle_initialize(state_pid)

          case MessageRouter.handle_message(msg) do
            {:ok, response} ->
              Logger.debug("Sending SSE response: #{inspect(response, pretty: true)}")
              send(sse_pid, {:send_sse_message, response})
              conn |> put_status(202) |> send_json(%{status: "ok"})
          end

        %{"method" => "notifications/initialized"} ->
          ConnectionState.handle_initialized(state_pid)
          # Start ping notifications after successful initialization
          schedule_next_ping(sse_pid)
          conn |> put_status(202) |> send_json(%{status: "ok"})

        %{"method" => "notifications/cancelled"} ->
          # Just log the cancellation notification and return ok
          Logger.info("Request cancelled: #{inspect(message["params"])}")
          conn |> put_status(202) |> send_json(%{status: "ok"})

        _ ->
          if Map.has_key?(message, "id") do
            # Handle requests that expect responses
            case MessageRouter.handle_message(message) do
              {:ok, nil} ->
                conn |> put_status(202) |> send_json(%{status: "ok"})

              {:ok, response} ->
                Logger.debug("Sending SSE response: #{inspect(response, pretty: true)}")
                send(sse_pid, {:send_sse_message, response})
                conn |> put_status(202) |> send_json(%{status: "ok"})

              {:error, error_response} ->
                Logger.warning("Error handling message: #{inspect(error_response)}")
                # Send error response via SSE to match JSON-RPC 2.0 spec
                send(sse_pid, {:send_sse_message, error_response})
                # we still reply with 202, because some clients abort the connection
                # when they receive a non-200 response
                conn |> put_status(202) |> send_json(%{status: "ok"})
            end
          else
            conn |> put_status(202) |> send_json(%{status: "ok"})
          end
      end
    else
      {:error, :missing_session} ->
        Logger.warning("Missing session ID in request")
        send_error(conn, 400, "session_id is required")

      {:error, :invalid_session} ->
        Logger.warning("Invalid session ID provided")
        send_error(conn, 400, "Invalid session ID")

      {:error, :session_not_found} ->
        Logger.warning("Session not found: #{conn.query_params["sessionId"]}")
        send_error(conn, 404, "Could not find session")

      {:error, :invalid_jsonrpc} ->
        Logger.warning("Invalid JSON-RPC message format")
        send_jsonrpc_error(conn, nil, -32600, "Could not parse message")
    end
  end

  defp setup_sse_connection(conn) do
    conn
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> put_resp_header("content-type", "text/event-stream; charset=utf-8")
    |> send_chunked(200)
  end

  defp register_connection(conn, session_id, state_pid) do
    :ets.insert(ConnectionRegistry.table_name(), {session_id, self(), state_pid})

    Logger.info(
      "SSE connection established. Session ID: #{session_id}, Process PID: #{inspect(self())}"
    )

    conn
  end

  defp send_initial_message(conn, session_id) do
    endpoint =
      "#{conn.scheme}://#{conn.host}:#{conn.port}#{@message_path}?sessionId=#{session_id}"

    case chunk(conn, "event: endpoint\ndata: #{endpoint}\n\n") do
      {:ok, conn} -> conn
      {:error, :closed} -> conn
    end
  end

  defp start_sse_loop(conn, session_id, state_pid) do
    sse_loop(conn, session_id, state_pid)
    conn
  end

  defp sse_loop(conn, session_id, state_pid) do
    receive do
      {:send_sse_message, msg} ->
        case handle_sse_message(conn, session_id, state_pid, msg) do
          {:ok, conn} -> sse_loop(conn, session_id, state_pid)
          {:error, :closed} -> handle_client_disconnect(session_id)
        end

      :init_timeout ->
        close_connection(conn, session_id, "Initialization timeout after 30 seconds")

      :inactivity_timeout ->
        close_connection(conn, session_id, "Connection closed due to 5 minutes of inactivity")

      :send_ping ->
        case ConnectionState.ready?(state_pid) do
          true ->
            case handle_ping(conn, session_id, state_pid) do
              {:ok, conn} ->
                schedule_next_ping(self())
                sse_loop(conn, session_id, state_pid)

              {:error, :closed} ->
                handle_client_disconnect(session_id)
            end

          false ->
            schedule_next_ping(self())
            sse_loop(conn, session_id, state_pid)
        end
    end
  end

  defp schedule_next_ping(sse_pid) do
    case @sse_keepalive_timeout do
      # Don't schedule next ping if disabled
      :infinity ->
        :ok

      timeout when is_integer(timeout) ->
        Process.send_after(sse_pid, :send_ping, timeout)
    end
  end

  defp handle_sse_message(conn, _session_id, _state_pid, msg) do
    sse_message = "event: message\ndata: #{JSON.encode!(msg)}\n\n"
    Logger.debug("Sending SSE message:\n#{sse_message}")

    case chunk(conn, sse_message) do
      {:ok, conn} -> {:ok, conn}
      {:error, :closed} -> {:error, :closed}
    end
  end

  defp handle_ping(conn, _session_id, _state_pid) do
    ping_notification = %{
      jsonrpc: "2.0",
      method: "$/ping",
      params: %{}
    }

    case chunk(conn, "event: message\ndata: #{JSON.encode!(ping_notification)}\n\n") do
      {:ok, conn} -> {:ok, conn}
      {:error, :closed} -> {:error, :closed}
    end
  end

  defp handle_client_disconnect(session_id) do
    Logger.info("SSE connection cancelled")
    Logger.info("Cleaning up SSE connection")

    case lookup_session(session_id) do
      {:ok, {_sse_pid, state_pid}} ->
        ConnectionState.cleanup(state_pid)

      _ ->
        :ok
    end

    :ets.delete(ConnectionRegistry.table_name(), session_id)
    Logger.info("SSE connection closed for session #{session_id}")
  end

  defp close_connection(conn, session_id, reason) do
    Logger.info("Closing SSE connection. Session ID: #{session_id}, Reason: #{reason}")

    case lookup_session(session_id) do
      {:ok, {_sse_pid, state_pid}} ->
        ConnectionState.cleanup(state_pid)

      _ ->
        :ok
    end

    :ets.delete(ConnectionRegistry.table_name(), session_id)

    case chunk(conn, "event: close\ndata: #{reason}\n\n") do
      {:ok, conn} -> halt(conn)
      {:error, :closed} -> halt(conn)
    end
  end

  defp get_session_id(conn) do
    case conn.query_params do
      %{"sessionId" => ""} -> {:error, :invalid_session}
      %{"sessionId" => session_id} -> {:ok, session_id}
      _ -> {:error, :missing_session}
    end
  end

  defp lookup_session(session_id) do
    case :ets.lookup(ConnectionRegistry.table_name(), session_id) do
      [{^session_id, pid, state_pid}] -> {:ok, {pid, state_pid}}
      [] -> {:error, :session_not_found}
    end
  end

  defp validate_jsonrpc_message(%{"jsonrpc" => "2.0"} = message) do
    cond do
      # Request must have method and id (string or number)
      Map.has_key?(message, "id") and Map.has_key?(message, "method") ->
        case message["id"] do
          id when is_binary(id) or is_number(id) -> {:ok, message}
          nil -> {:error, :invalid_jsonrpc}
          _ -> {:error, :invalid_jsonrpc}
        end

      # Notification must have method but no id
      not Map.has_key?(message, "id") and Map.has_key?(message, "method") ->
        {:ok, message}

      true ->
        {:error, :invalid_jsonrpc}
    end
  end

  defp validate_jsonrpc_message(_), do: {:error, :invalid_jsonrpc}

  defp generate_session_id do
    <<i1::32, i2::32, i3::32>> = :crypto.strong_rand_bytes(12)

    :io_lib.format("~8.16.0b-~8.16.0b-~8.16.0b", [i1, i2, i3])
    |> List.to_string()
  end
end
