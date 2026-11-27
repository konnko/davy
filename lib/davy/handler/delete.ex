defmodule Davy.Handler.Delete do
  @moduledoc false

  import Plug.Conn
  alias Davy.{Handler.Helpers, Telemetry}

  @doc false
  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, opts) do
    path = Helpers.resource_path(conn)

    with :ok <- Helpers.check_lock(conn, path, opts),
         :ok <- Helpers.check_descendant_locks(conn, path, opts),
         {:ok, resource} <-
           Telemetry.span_backend(opts.backend, :resolve, %{path: path}, fn ->
             opts.backend.resolve(opts.auth, path)
           end) do
      result =
        Telemetry.span_backend(opts.backend, :delete, %{path: resource.path}, fn ->
          opts.backend.delete(opts.auth, resource)
        end)

      case result do
        :ok ->
          Helpers.release_locks(opts, path)
          send_resp(conn, 204, "")

        {:partial, failures} ->
          send_multistatus_failures(conn, failures, :error)

        {:error, error} ->
          Helpers.send_error(conn, error)
      end
    else
      {:locked_descendants, locked_paths} ->
        Helpers.send_multistatus(conn, Enum.map(locked_paths, &{&1, 423}))

      {:error, error} ->
        Helpers.send_error(conn, error)
    end
  end

  defp send_multistatus_failures(conn, failures, :error) do
    statuses =
      Enum.map(failures, fn {path, error} -> {path, Davy.Error.status_code(error.code)} end)

    Helpers.send_multistatus(conn, statuses)
  end
end
