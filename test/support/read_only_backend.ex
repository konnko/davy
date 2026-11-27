defmodule Davy.Test.ReadOnlyBackend do
  @moduledoc """
  The in-memory backend for a client that may read but not lock: every LOCK
  and UNLOCK is refused by `authorize_lock/2`.
  """
  @behaviour Davy.Backend

  alias Davy.Backend.InMemory

  @impl true
  def authorize_lock(_auth, _path),
    do: {:error, %Davy.Error{code: :forbidden, message: "Read-only"}}

  @impl true
  defdelegate authenticate(conn), to: InMemory
  @impl true
  defdelegate resolve(auth, path), to: InMemory
  @impl true
  defdelegate get_properties(auth, resource, properties), to: InMemory
  @impl true
  defdelegate set_properties(auth, resource, operations), to: InMemory
  @impl true
  defdelegate get_content(auth, resource, opts), to: InMemory
  @impl true
  defdelegate put_content(auth, path, body, opts), to: InMemory
  @impl true
  defdelegate delete(auth, resource), to: InMemory
  @impl true
  defdelegate copy(auth, resource, dest_path, overwrite?), to: InMemory
  @impl true
  defdelegate move(auth, resource, dest_path, overwrite?), to: InMemory
  @impl true
  defdelegate create_collection(auth, path), to: InMemory
  @impl true
  defdelegate get_members(auth, resource), to: InMemory
end
