defmodule ToolCall.Approval do
  @moduledoc """
  Approval policies and pending approval requests.

  A policy is a module implementing `check/3`; `use ToolCall, approval: Policy`
  installs it for every tool in the module, and `run/4` with `approval:` can
  override it per call. `check/3` receives the tool IR, the raw argument map and
  the caller's context, and answers:

    * `:approve` - invoke the tool;
    * `{:deny, reason}` - `{:error, {:approval_denied, reason}}`;
    * `{:required, reason}` - `{:pending, %ToolCall.Approval.Request{}}`.

  This is a mechanism, not a workflow: the application persists the request,
  shows it to a human, and resumes with
  `ToolCall.run(request.module, request.tool, request.args, approval: :granted,
  context: request.context)`. It must use the stored arguments — never model
  output for an already approved call. There is no storage, timeout, retry or
  double-execution guard here; the agent runtime or application owns those.
  """

  alias ToolCall.IR.Tool

  @type decision :: :approve | {:deny, term()} | {:required, term()}

  @callback check(Tool.t(), map(), term()) :: decision()

  defmodule Request do
    @moduledoc """
    A serializable pending approval.

    `args` is the raw argument map the model requested; `context` is whatever
    the caller passed to `run/4`. `inserted_at` lets the application expire
    stale requests. The struct contains no pids or closures.
    """

    @enforce_keys [:id, :module, :tool, :args]
    defstruct [:id, :module, :tool, :args, :reason, :context, :inserted_at]

    @type t :: %__MODULE__{
            id: String.t(),
            module: module(),
            tool: String.t(),
            args: map(),
            reason: term(),
            context: term(),
            inserted_at: DateTime.t()
          }
  end

  @doc false
  @spec request(module(), Tool.t(), map(), term(), term()) :: Request.t()
  def request(module, %Tool{} = tool, args, reason, context) do
    %Request{
      id: id(),
      module: module,
      tool: tool.name,
      args: args,
      reason: reason,
      context: context,
      inserted_at: DateTime.utc_now()
    }
  end

  defp id do
    :crypto.strong_rand_bytes(16)
    |> Base.url_encode64(padding: false)
  end
end
