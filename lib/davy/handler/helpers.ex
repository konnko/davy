defmodule Davy.Handler.Helpers do
  @moduledoc false

  alias Davy.{Error, Telemetry, XML}

  @doc """
  Extract the resource path from the conn as a list of decoded URI segments.
  """
  @spec resource_path(Plug.Conn.t()) :: [String.t()]
  def resource_path(conn) do
    conn.path_info
    |> Enum.map(&URI.decode/1)
  end

  @doc """
  Build the full href for a resource path, including the script_name prefix.

  Every segment is percent-encoded down to the unreserved characters, so a name
  with `#`, `?` or `:` stays one path segment for the client that follows the href.
  """
  @spec href(Plug.Conn.t(), [String.t()]) :: String.t()
  def href(conn, path) do
    prefix = Enum.map_join(conn.script_name, "/", &encode_segment/1)
    suffix = Enum.map_join(path, "/", &encode_segment/1)
    "/#{prefix}/#{suffix}" |> String.replace("//", "/")
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  @doc """
  Parse the `Depth` header. Returns 0, 1, or :infinity.
  """
  @spec parse_depth(Plug.Conn.t(), 0 | 1 | :infinity) :: 0 | 1 | :infinity
  def parse_depth(conn, default \\ :infinity) do
    case Plug.Conn.get_req_header(conn, "depth") do
      ["0"] -> 0
      ["1"] -> 1
      ["infinity"] -> :infinity
      _ -> default
    end
  end

  @doc """
  Parse the `Destination` header into a path segment list relative to the mount point.
  """
  @spec parse_destination(Plug.Conn.t()) :: {:ok, [String.t()]} | {:error, :bad_request}
  def parse_destination(conn) do
    case Plug.Conn.get_req_header(conn, "destination") do
      [dest_uri] ->
        uri = URI.parse(dest_uri)
        segments = String.split(uri.path || "/", "/", trim: true)

        {:ok, segments |> drop_mount_point(conn.script_name) |> Enum.map(&URI.decode/1)}

      [] ->
        {:error, :bad_request}
    end
  end

  # Compared segment by segment and dropped once: a destination such as
  # `/dav/david/a.txt` under a `/dav` mount must stay `david/a.txt`.
  defp drop_mount_point(segments, script_name) do
    if List.starts_with?(segments, script_name) do
      Enum.drop(segments, length(script_name))
    else
      segments
    end
  end

  @doc """
  Parse the `Overwrite` header. Defaults to true per RFC 4918.
  """
  @spec parse_overwrite(Plug.Conn.t()) :: boolean()
  def parse_overwrite(conn) do
    case Plug.Conn.get_req_header(conn, "overwrite") do
      ["F"] -> false
      _ -> true
    end
  end

  @doc """
  Parse the `Timeout` header for lock requests.
  Returns timeout in seconds, defaulting to the configured lock timeout.
  """
  @spec parse_timeout(Plug.Conn.t(), pos_integer()) :: pos_integer()
  def parse_timeout(conn, default) do
    case Plug.Conn.get_req_header(conn, "timeout") do
      [value] -> parse_timeout_value(value, default)
      _ -> default
    end
  end

  defp parse_timeout_value("Infinite", _default), do: 3600
  defp parse_timeout_value("infinite", _default), do: 3600

  defp parse_timeout_value("Second-" <> seconds, default) do
    case Integer.parse(seconds) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_timeout_value(_, default), do: default

  @doc """
  Extract lock tokens from the `If` header.
  Returns a list of extracted lock tokens.
  """
  @spec extract_lock_tokens(Plug.Conn.t()) :: [String.t()]
  def extract_lock_tokens(conn) do
    conn
    |> Plug.Conn.get_req_header("if")
    |> Enum.flat_map(&parse_if_header/1)
  end

  defp parse_if_header(value) do
    # Extract opaquelocktoken URIs from If header
    # Handles both <opaquelocktoken:xxx> and bare opaquelocktoken:xxx (Windows quirk)
    ~r/<?opaquelocktoken:([^>)\s]+)>?/
    |> Regex.scan(value)
    |> Enum.map(fn [_, token] -> token end)
  end

  @doc """
  Send an error response based on a `Davy.Error`.
  """
  @spec send_error(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def send_error(conn, %Error{code: code, message: message}) do
    status = Error.status_code(code)
    body = message || to_string(code)
    Plug.Conn.send_resp(conn, status, body)
  end

  @doc """
  Check lock tokens on a write operation.

  Returns `:ok` if neither the path nor any ancestor collection with
  `depth: :infinity` is locked, or if a valid token covering the write
  is provided in the `If` header.

  A lock store that cannot answer returns its own error, which propagates
  unchanged — an unreachable store never reads as "unlocked".
  """
  @spec check_lock(Plug.Conn.t(), [String.t()], map()) :: :ok | {:error, Error.t()}
  def check_lock(conn, path, %{lock_store: lock_store} = opts) do
    lock_path = lock_path(opts, path)

    case locks_covering(lock_store, lock_path) do
      {:ok, []} ->
        :ok

      {:ok, _locks} ->
        conn
        |> extract_lock_tokens()
        |> find_covering_token(lock_store, lock_path)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Check the locks held on resources below `path`.

  Returns `:ok` if every such lock has its token in the `If` header, or
  `{:locked_descendants, paths}` with the request paths of the members still
  locked against the request.
  """
  @spec check_descendant_locks(Plug.Conn.t(), [String.t()], map()) ::
          :ok | {:locked_descendants, [[String.t()]]} | {:error, Error.t()}
  def check_descendant_locks(conn, path, %{lock_store: lock_store} = opts) do
    lock_path = lock_path(opts, path)

    descendants =
      Telemetry.span_lock_store(lock_store, :get_descendant_locks, %{path: lock_path}, fn ->
        lock_store.get_descendant_locks(lock_path)
      end)

    case descendants do
      {:ok, []} ->
        :ok

      {:ok, descendant_locks} ->
        tokens = extract_lock_tokens(conn)

        locked =
          descendant_locks
          |> Enum.filter(fn info -> not Enum.member?(tokens, info.token) end)
          |> Enum.map(&request_path(opts, &1.path))
          |> Enum.uniq()

        case locked do
          [] -> :ok
          paths -> {:locked_descendants, paths}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Send a 207 Multi-Status with one status per resource path.
  """
  @spec send_multistatus(Plug.Conn.t(), [{[String.t()], Plug.Conn.status()}]) ::
          Plug.Conn.t()
  def send_multistatus(conn, statuses) do
    body =
      statuses
      |> Enum.map(fn {path, status} -> status_response(conn, path, status) end)
      |> XML.multistatus()

    conn
    |> Plug.Conn.put_resp_content_type("application/xml", nil)
    |> Plug.Conn.send_resp(207, body)
  end

  defp status_response(conn, path, status) do
    Saxy.XML.element("D:response", [], [
      XML.text_element("D:href", href(conn, path)),
      Saxy.XML.element("D:status", [], [
        "HTTP/1.1 #{status} #{Plug.Conn.Status.reason_phrase(status)}"
      ])
    ])
  end

  @doc """
  The path a resource is known by in the lock store: the request path under
  the backend's `c:Davy.Backend.lock_root/1`.
  """
  @spec lock_path(map(), [String.t()]) :: [String.t()]
  def lock_path(%{lock_root: lock_root}, path), do: lock_root ++ path

  @doc """
  The request path of a lock store path at or below the lock root.
  """
  @spec request_path(map(), [String.t()]) :: [String.t()]
  def request_path(%{lock_root: lock_root}, lock_path),
    do: Enum.drop(lock_path, length(lock_root))

  @doc """
  Build the error returned when a write is blocked by a lock the request
  did not supply a token for.
  """
  @spec locked_error() :: Error.t()
  def locked_error, do: %Error{code: :locked, message: "Locked"}

  defp locks_covering(lock_store, path) do
    Telemetry.span_lock_store(lock_store, :get_locks_covering, %{path: path}, fn ->
      lock_store.get_locks_covering(path)
    end)
  end

  defp find_covering_token(tokens, lock_store, path) do
    Enum.reduce_while(tokens, {:error, locked_error()}, fn token, blocked ->
      case check_token(lock_store, path, token) do
        :ok -> {:halt, :ok}
        {:error, :invalid_token} -> {:cont, blocked}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp check_token(lock_store, path, token) do
    Telemetry.span_lock_store(lock_store, :check_token, %{path: path, token: token}, fn ->
      lock_store.check_token(path, token)
    end)
  end
end
