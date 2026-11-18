# ToolCall benchmark

Standalone Mix project for measuring the compile-time schema path and the
runtime dispatch path against `req_llm`. It uses local tool execution only; no
API keys or network requests are involved.

```sh
cd bench
mix deps.get
mix run bench.exs
```

The benchmark uses:

- `tool_call` from the parent checkout
- `req_llm ~> 1.30`
- `benchee ~> 1.4`

It deliberately keeps these dependencies out of the library's `mix.exs`, so the
published package and the main `mix ci` run do not pull in an LLM client.

## Cases

- `add/2`: two scalar integers. ToolCall takes its generated fast path.
- `describe/3`: a string, an optional positive integer and a list of strings.
  This takes ToolCall's generic runner and ReqLLM's NimbleOptions path.
- `emit/3`: one precompiled OpenAI schema and ten precompiled schemas.
- `ReqLLM.Tool.new!/1`: runtime construction of one tool, included as a setup
  cost reference.

## Reference run

Apple M1 Pro, 32 GB, macOS, Elixir 1.20.5, Erlang/OTP 29, JIT enabled,
Benchee 1.5.1. Values are medians from one run; absolute numbers vary by
machine and VM load.

| Case | ToolCall | ReqLLM |
|---|---:|---:|
| OpenAI schema, 1 tool | 0.46 µs / 72 B | 0.42 µs / 600 B |
| OpenAI schema, 10 tools | 0.46 µs / 72 B | 3.96 µs / 5.94 KB |
| `add`, string keys | 0.63 µs / 200 B | 0.54 µs / 1.47 KB |
| `add`, atom keys | 0.54 µs / 240 B | 0.50 µs / 1.42 KB |
| `describe`, generic path | 2.54 µs / 2.38 KB | 0.88 µs / 3.01 KB |
| `ReqLLM.Tool.new!` setup | compile-time | 3.33 µs / 5.03 KB |

These are local CPU measurements. For an end-to-end LLM request, network and
model latency dominate both numbers.
