defmodule Davy.Handler.CopyMove do
  @moduledoc false

  import Plug.Conn
  alias Davy.{Handler.Helpers, Telemetry}

  @doc false
  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, opts) do
    path = Helpers.resource_path(conn)

    with {:ok, dest_path} <- Helpers.parse_destination(conn),
         :ok <- check_not_self(path, dest_path),
         :ok <- check_not_descendant(conn.method, path, dest_path),
         :ok <- maybe_check_lock(conn, path, dest_path, opts),
         :ok <- check_member_locks(conn, path, dest_path, opts) do
      do_copy_or_move(conn, opts, path, dest_path)
    else
      {:locked_descendants, locked_paths} ->
        Helpers.send_multistatus(conn, Enum.map(locked_paths, &{&1, 423}))

      {:error, :bad_request} ->
        send_resp(conn, 400, "Missing Destination header")

      {:error, :forbidden} ->
        send_resp(conn, 403, "Cannot copy/move to descendant of self")

      {:error, error} ->
        Helpers.send_error(conn, error)
    end
  end

  defp do_copy_or_move(conn, opts, path, dest_path) do
    resolved =
      Telemetry.span_backend(opts.backend, :resolve, %{path: path}, fn ->
        opts.backend.resolve(opts.auth, path)
      end)

    case resolved do
      {:ok, resource} -> copy_or_move_resource(conn, opts, resource, dest_path)
      {:error, error} -> Helpers.send_error(conn, error)
    end
  end

  defp copy_or_move_resource(conn, opts, resource, dest_path) do
    overwrite? = Helpers.parse_overwrite(conn)
    operation = if conn.method == "COPY", do: :copy, else: :move

    metadata = %{source_path: resource.path, dest_path: dest_path, overwrite: overwrite?}

    result =
      Telemetry.span_backend(opts.backend, operation, metadata, fn ->
        run_copy_or_move(operation, opts, resource, dest_path, overwrite?)
      end)

    case result do
      {:ok, :created} -> send_resp(conn, 201, "")
      {:ok, :no_content} -> send_resp(conn, 204, "")
      {:error, error} -> Helpers.send_error(conn, error)
    end
  end

  defp run_copy_or_move(:copy, opts, resource, dest_path, overwrite?),
    do: opts.backend.copy(opts.auth, resource, dest_path, overwrite?)

  defp run_copy_or_move(:move, opts, resource, dest_path, overwrite?),
    do: opts.backend.move(opts.auth, resource, dest_path, overwrite?)

  defp check_not_self(path, path), do: {:error, :forbidden}
  defp check_not_self(_, _), do: :ok

  defp check_not_descendant("COPY", source, dest), do: check_descendant(source, dest)
  defp check_not_descendant("MOVE", source, dest), do: check_descendant(source, dest)
  defp check_not_descendant(_, _, _), do: :ok

  defp check_descendant(source, dest) do
    if List.starts_with?(dest, source) and length(dest) > length(source) do
      {:error, :forbidden}
    else
      :ok
    end
  end

  defp maybe_check_lock(conn, _source, dest_path, opts) do
    # MOVE requires lock check on source; both require check on destination
    if conn.method == "MOVE" do
      source_path = Helpers.resource_path(conn)

      with :ok <- Helpers.check_lock(conn, source_path, opts) do
        Helpers.check_lock(conn, dest_path, opts)
      end
    else
      Helpers.check_lock(conn, dest_path, opts)
    end
  end

  # A MOVE takes the source's members away and an overwrite deletes the
  # destination's, so both need the tokens of the locks held on them.
  defp check_member_locks(conn, source_path, dest_path, opts) do
    with :ok <- maybe_check_source_members(conn, source_path, opts) do
      maybe_check_destination_members(conn, dest_path, opts)
    end
  end

  defp maybe_check_source_members(%{method: "MOVE"} = conn, source_path, opts),
    do: Helpers.check_descendant_locks(conn, source_path, opts)

  defp maybe_check_source_members(_conn, _source_path, _opts), do: :ok

  defp maybe_check_destination_members(conn, dest_path, opts) do
    if Helpers.parse_overwrite(conn) do
      Helpers.check_descendant_locks(conn, dest_path, opts)
    else
      :ok
    end
  end
end
