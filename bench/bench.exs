alias ToolCallBench.{Many, Tools}

req_add =
  ReqLLM.Tool.new!(
    name: "add",
    description: "Add two integers.",
    parameter_schema: [
      a: [type: :integer, required: true],
      b: [type: :integer, required: true]
    ],
    callback: fn %{a: a, b: b} -> {:ok, a + b} end
  )

req_describe =
  ReqLLM.Tool.new!(
    name: "describe",
    description: "Describe a user.",
    parameter_schema: [
      name: [type: :string, required: true],
      age: [type: :integer, required: false],
      tags: [type: {:list, :string}, required: true]
    ],
    callback: fn %{name: name, age: age, tags: tags} ->
      {:ok, %{name: name, age: age, tags: tags}}
    end
  )

req_many =
  for n <- 1..10 do
    ReqLLM.Tool.new!(
      name: "add#{n}",
      description: "Add two integers.",
      parameter_schema: [
        a: [type: :integer, required: true],
        b: [type: :integer, required: true]
      ],
      callback: fn %{a: a, b: b} -> {:ok, a + b} end
    )
  end

args_add = %{"a" => 1, "b" => 2}
args_describe = %{"name" => "Ada", "age" => 42, "tags" => ["admin", "ops"]}

Benchee.run(
  %{
    "ToolCall add (string keys)" => fn -> ToolCall.run(Tools, :add, args_add) end,
    "ReqLLM add (string keys)" => fn -> ReqLLM.Tool.execute(req_add, args_add) end,
    "ToolCall add (atom keys)" => fn -> ToolCall.run(Tools, :add, %{a: 1, b: 2}) end,
    "ReqLLM add (atom keys)" => fn -> ReqLLM.Tool.execute(req_add, %{a: 1, b: 2}) end,
    "ToolCall describe (generic)" => fn -> ToolCall.run(Tools, :describe, args_describe) end,
    "ReqLLM describe (generic)" => fn -> ReqLLM.Tool.execute(req_describe, args_describe) end,
    "ToolCall emit openai" => fn -> ToolCall.emit(Tools, :openai) end,
    "ReqLLM schema openai" => fn -> ReqLLM.Tool.to_schema(req_add, :openai) end,
    "ToolCall emit anthropic" => fn -> ToolCall.emit(Tools, :anthropic) end,
    "ReqLLM schema anthropic" => fn -> ReqLLM.Tool.to_schema(req_add, :anthropic) end,
    "ToolCall 10 schemas" => fn -> ToolCall.emit(Many, :openai) end,
    "ReqLLM 10 schemas" => fn ->
      Enum.map(req_many, &ReqLLM.Tool.to_schema(&1, :openai))
    end,
    "ReqLLM.Tool.new! add" => fn ->
      ReqLLM.Tool.new!(
        name: "add",
        description: "Add two integers.",
        parameter_schema: [
          a: [type: :integer, required: true],
          b: [type: :integer, required: true]
        ],
        callback: fn %{a: a, b: b} -> {:ok, a + b} end
      )
    end
  },
  warmup: 3,
  time: 10,
  memory_time: 2,
  reduction_time: 2
)
