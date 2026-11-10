defmodule ToolCall.Audit do
  @moduledoc """
  Dispatch audit hooks.

  A policy is a module implementing `record/1`. Configure it with
  `use ToolCall, audit: Policy` or `run/4 audit: Policy`; `audit: nil` disables
  a module policy for one call. `record/1` receives a
  `%ToolCall.Audit.Entry{}` once per dispatch attempt, including resolve
  failures, approvals, timeouts, raises and resolve/execute policy exceptions.

  This is a hook, not a log store: the application persists the entry, applies
  redaction and retention, and decides whether a failed audit is fatal. The
  library calls the hook synchronously and ignores an exception it raises, so
  a broken audit does not change the tool result. The raw `args` and `context`
  are passed through; redact them in `record/1` when they contain secrets.
  """

  @type outcome ::
          :ok
          | :error
          | :raised
          | :pending
          | :denied
          | :timeout
          | :invalid_arguments
          | :unknown_tool

  defmodule Entry do
    @moduledoc """
    One dispatch attempt.

    `outcome` is `:ok`, `:error`, `:raised`, `:pending`, `:denied`,
    `:timeout`, `:invalid_arguments` or `:unknown_tool`. `duration_us` covers
    the phase that produced the outcome: resolve for an argument error, execute
    for an invoked call, and zero for an unknown tool or non-map arguments.
    `error` carries the reason for failure outcomes and `approval_request_id`
    correlates a pending request. The result value is never recorded.
    """

    @enforce_keys [:id, :at, :module, :tool, :args, :outcome]
    defstruct [
      :id,
      :at,
      :module,
      :tool,
      :args,
      :context,
      :outcome,
      :duration_us,
      :error,
      :approval_request_id,
      :timeout
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            at: DateTime.t(),
            module: module(),
            tool: String.t(),
            args: term(),
            context: term(),
            outcome: ToolCall.Audit.outcome(),
            duration_us: non_neg_integer() | nil,
            error: term(),
            approval_request_id: String.t() | nil,
            timeout: non_neg_integer() | nil
          }
  end

  @callback record(Entry.t()) :: term()

  @doc """
  Builds the entry passed to `c:record/1`.

  `outcome` is one of the `t:outcome/0` values; `opts` accepts
  `:duration_us`, `:error`, `:approval_request_id` and `:timeout`.
  Custom dispatchers call this when they bypass `ToolCall.run/4`.
  """
  @spec entry(module(), String.t(), term(), term(), outcome(), keyword()) :: Entry.t()
  def entry(module, tool, args, context, outcome, opts \\ []) do
    %Entry{
      id: id(),
      at: DateTime.utc_now(),
      module: module,
      tool: tool,
      args: args,
      context: context,
      outcome: outcome,
      duration_us: Keyword.get(opts, :duration_us),
      error: Keyword.get(opts, :error),
      approval_request_id: Keyword.get(opts, :approval_request_id),
      timeout: Keyword.get(opts, :timeout)
    }
  end

  defp id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
