defmodule Davy.Test.TenantBackend do
  @moduledoc """
  The in-memory backend as a multi-tenant server would present it.

  The `x-tenant` request header names the tenant, whose locks are kept apart
  from other tenants' by `lock_root/1`, and the root collection reports a
  quota. Storage itself is shared between tenants, which is enough to test
  what Davy does with these.
  """
  @behaviour Davy.Backend

  alias Davy.Backend.InMemory

  @quota_available_bytes 1000
  @quota_used_bytes 24

  @impl true
  def authenticate(conn) do
    [tenant] = Plug.Conn.get_req_header(conn, "x-tenant")
    {:ok, %{tenant: tenant}}
  end

  @impl true
  def lock_root(%{tenant: tenant}), do: [tenant]

  @impl true
  def resolve(auth, []) do
    with {:ok, root} <- InMemory.resolve(auth, []) do
      {:ok,
       %{
         root
         | quota_available_bytes: @quota_available_bytes,
           quota_used_bytes: @quota_used_bytes
       }}
    end
  end

  def resolve(auth, path), do: InMemory.resolve(auth, path)

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
