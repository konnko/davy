defmodule Davy.Test.RecordingBackend do
  @moduledoc """
  The in-memory backend, telling the calling process which options Davy passed
  to `put_content/4` and `copy/5`. The handlers run in the test process, so the
  options arrive as `{:put_content, opts}` and `{:copy, opts}` messages.
  """
  @behaviour Davy.Backend

  alias Davy.Backend.InMemory

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
  def put_content(auth, path, body, opts) do
    send(self(), {:put_content, opts})
    InMemory.put_content(auth, path, body, opts)
  end

  @impl true
  defdelegate delete(auth, resource), to: InMemory

  @impl true
  def copy(auth, resource, dest_path, overwrite?, opts) do
    send(self(), {:copy, opts})
    InMemory.copy(auth, resource, dest_path, overwrite?)
  end

  @impl true
  defdelegate move(auth, resource, dest_path, overwrite?), to: InMemory
  @impl true
  defdelegate create_collection(auth, path), to: InMemory
  @impl true
  defdelegate get_members(auth, resource), to: InMemory
end
