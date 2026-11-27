defmodule Davy.Backend do
  @moduledoc """
  Behaviour for WebDAV storage backends.

  Implement this behaviour to connect Davy to any storage system. The backend
  handles resource resolution, content operations, and collection management.
  All path arguments are lists of URI-decoded path segments.

  ## Example

      defmodule MyApp.DavBackend do
        @behaviour Davy.Backend

        @impl true
        def authenticate(_conn), do: {:ok, %{user: "anonymous"}}

        @impl true
        def resolve(_auth, path) do
          # Look up the resource at path
        end

        # ... implement remaining callbacks
      end
  """

  @type auth_context :: term()
  @type path :: [String.t()]
  @type property :: {namespace :: String.t(), name :: String.t()}
  @type resource :: Davy.Resource.t()
  @type error :: Davy.Error.t()

  # --- Authentication ---

  @doc """
  Authenticate the request. Called before any operation.

  Return `{:ok, auth_context}` where `auth_context` is passed to all
  subsequent callbacks, or `{:error, :unauthorized}`.
  """
  @callback authenticate(conn :: Plug.Conn.t()) ::
              {:ok, auth_context()} | {:error, :unauthorized}

  # --- Resource resolution ---

  @doc """
  Resolve a path to a resource. Return `{:error, not_found_error}` if
  the resource does not exist.
  """
  @callback resolve(auth_context(), path()) ::
              {:ok, resource()} | {:error, error()}

  # --- Properties ---

  @doc """
  Return values for the requested properties on a resource.

  Each property is a `{namespace, name}` tuple. Return a list of
  `{property, {:ok, value}}` or `{property, {:error, :not_found}}` pairs.
  The value should be a string or a Saxy XML element.
  """
  @callback get_properties(auth_context(), resource(), [property()]) ::
              [{property(), {:ok, term()} | {:error, :not_found}}]

  @doc """
  Set or remove properties on a resource.

  Operations are `{:set, property, value}` or `{:remove, property}` tuples.
  Must be atomic — either all succeed or none are applied.
  """
  @callback set_properties(
              auth_context(),
              resource(),
              [{:set, property(), term()} | {:remove, property()}]
            ) ::
              :ok | {:error, error()}

  # --- File operations ---

  @doc """
  Read file content. Called for GET only: HEAD is answered from the resource.

  When `opts` contains `:range` as `{first, last}`, return exactly those bytes.
  Both positions are absolute and inclusive, and have already been resolved
  against the resource's `content_length`, so `first <= last < content_length`
  always holds — a backend never has to clamp a range or decide whether one is
  satisfiable. Resources reporting no `content_length` are never asked for a
  partial read, because there is nothing to resolve suffix and open-ended
  ranges against. Neither is a request whose `If-Range` does not match the
  resource's `etag`: it gets the whole content.

  Return `{:ok, iodata}` or `{:ok, enumerable}` for streaming.
  """
  @callback get_content(auth_context(), resource(), opts :: map()) ::
              {:ok, iodata() | Enumerable.t()} | {:error, error()}

  @doc """
  Create or replace a file at the given path.

  `opts` carries what the request said about the body:

  - `:content_type` — the `Content-Type` header, `application/octet-stream`
    when the client sent none;
  - `:content_length` — the size the client declared (`Content-Length`, or
    `X-Expected-Entity-Length` for a chunked body), `nil` when it declared
    none. It lets a backend refuse a body that will not fit before reading it.

  Return `{:ok, resource}` with the created/updated resource.
  """
  @callback put_content(auth_context(), path(), body :: iodata(), opts :: map()) ::
              {:ok, resource()} | {:error, error()}

  @doc """
  Create or replace a file from a stream of binary segments.

  Optional. When implemented, the PUT handler reads the request body in
  bounded slices and feeds them to the backend as a `Stream` instead of
  materialising the whole body in memory. Backends that don't implement this
  callback are dispatched through `put_content/4` as before. `opts` are those
  of `put_content/4`.

  Return `{:ok, resource}` with the created/updated resource.
  """
  @callback put_content_stream(
              auth_context(),
              path(),
              Enumerable.t(binary()),
              opts :: map()
            ) ::
              {:ok, resource()} | {:error, error()}

  @optional_callbacks put_content_stream: 4, lock_root: 1, authorize_lock: 2, copy: 4, copy: 5

  @doc """
  Delete a resource. For collections, the backend should handle recursive
  deletion. Return `:ok` on full success, or `{:error, error}` with a list
  of partial failures via `{:partial, [{path, error}]}` for 207 responses.
  """
  @callback delete(auth_context(), resource()) ::
              :ok | {:error, error()} | {:partial, [{path(), error()}]}

  @doc """
  Copy a resource to the destination path.

  `overwrite?` indicates whether existing resources at the destination
  should be replaced. Return `{:ok, :created}` or `{:ok, :no_content}`
  to distinguish new vs overwritten destinations.
  """
  @callback copy(auth_context(), resource(), dest_path :: path(), overwrite? :: boolean()) ::
              {:ok, :created | :no_content} | {:error, error()}

  @doc """
  Copy a resource to the destination path, honouring the request's `Depth`.

  Implement this instead of `copy/4` to tell the two copies of a collection
  apart: `opts.depth` is `:infinity` for the collection with everything in it
  and `0` for the collection alone (RFC 4918 §9.8.3). A backend must implement
  one of the two; when both exist this one is called.
  """
  @callback copy(
              auth_context(),
              resource(),
              dest_path :: path(),
              overwrite? :: boolean(),
              opts :: %{depth: 0 | :infinity}
            ) ::
              {:ok, :created | :no_content} | {:error, error()}

  @doc """
  Move a resource to the destination path.

  `overwrite?` indicates whether existing resources at the destination
  should be replaced. Should be atomic when possible.
  """
  @callback move(auth_context(), resource(), dest_path :: path(), overwrite? :: boolean()) ::
              {:ok, :created | :no_content} | {:error, error()}

  # --- Locking ---

  @doc """
  Path segments that place this auth context's tree in the lock store.

  Optional. Davy prepends them to every path it hands to the `Davy.LockStore`,
  so locks are keyed by `lock_root(auth) ++ path` instead of `path` alone.

  Without this callback all requests share one lock namespace, which is right
  when every client sees the same tree. A backend that shows each auth context
  a different tree must implement it — otherwise a lock on `/notes.txt` held
  by one tenant blocks, and is visible to, every other tenant with a file of
  that name.

  Return the position of the context's root in one tree common to everybody
  who can reach the same resources: `["tenant-42"]` for a tenant's whole tree,
  `["tenant-42", "photos"]` for a credential confined to that folder. Both then
  agree on the lock for `tenant-42/photos/a.jpg`.
  """
  @callback lock_root(auth_context()) :: path()

  @doc """
  Decide whether this auth context may lock, refresh or unlock the path.

  Optional. Davy keeps locks in the `Davy.LockStore` and never asks the
  backend about them, so without this callback every authenticated client can
  lock any path — including a client the backend lets read but not write,
  whose lock would then stop the writers. Return `{:error, error}` to refuse
  LOCK and UNLOCK with that error's status; nothing is locked or created.
  """
  @callback authorize_lock(auth_context(), path()) :: :ok | {:error, error()}

  # --- Collection operations ---

  @doc """
  Create a collection (directory) at the given path.
  """
  @callback create_collection(auth_context(), path()) ::
              :ok | {:error, error()}

  @doc """
  List the direct members of a collection.
  """
  @callback get_members(auth_context(), resource()) ::
              {:ok, [resource()]} | {:error, error()}
end
