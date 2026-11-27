defmodule Davy.Test.ShortLockStore do
  @moduledoc """
  Lock store that never grants a lock for longer than a minute, whatever the
  client asks for. Everything else is `Davy.LockStore.ETS`.
  """

  @behaviour Davy.LockStore

  alias Davy.LockStore.ETS

  @max_timeout 60

  @impl true
  def lock(path, scope, type, depth, owner, timeout),
    do: ETS.lock(path, scope, type, depth, owner, min(timeout, @max_timeout))

  @impl true
  def refresh(token, timeout), do: ETS.refresh(token, min(timeout, @max_timeout))

  @impl true
  defdelegate unlock(token), to: ETS

  @impl true
  defdelegate get_locks(path), to: ETS

  @impl true
  defdelegate get_locks_covering(path), to: ETS

  @impl true
  defdelegate get_descendant_locks(path), to: ETS

  @impl true
  defdelegate check_token(path, token), to: ETS
end
