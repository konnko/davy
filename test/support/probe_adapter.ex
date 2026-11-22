defmodule Davy.Test.ProbeAdapter do
  @moduledoc """
  Wraps the Plug test adapter so tests can observe and disturb the transport.

  Every body read is reported to the test process as `{:read_req_body, opts}`,
  and `chunk_error: reason` makes each chunk send fail with `{:error, reason}`,
  as a real adapter does once the peer stops reading.
  """

  alias Plug.Adapters.Test.Conn, as: TestAdapter

  @spec wrap(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def wrap(%Plug.Conn{adapter: {TestAdapter, state}} = conn, opts \\ []) do
    %{conn | adapter: {__MODULE__, {state, opts}}}
  end

  def read_req_body({state, opts}, read_opts) do
    send(self(), {:read_req_body, read_opts})
    {tag, data, state} = TestAdapter.read_req_body(state, read_opts)
    {tag, data, {state, opts}}
  end

  def send_resp({state, opts}, status, headers, body) do
    {:ok, body, state} = TestAdapter.send_resp(state, status, headers, body)
    {:ok, body, {state, opts}}
  end

  def send_chunked({state, opts}, status, headers) do
    {:ok, body, state} = TestAdapter.send_chunked(state, status, headers)
    {:ok, body, {state, opts}}
  end

  def chunk({state, opts}, body) do
    case Keyword.fetch(opts, :chunk_error) do
      {:ok, reason} ->
        {:error, reason}

      :error ->
        {:ok, body, state} = TestAdapter.chunk(state, body)
        {:ok, body, {state, opts}}
    end
  end
end
