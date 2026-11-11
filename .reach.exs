# Reach configuration.
[
  smells: [
    # These modules already implement ToolCall.TypeProvider; Reach sees the
    # shared callback set as a candidate for another behaviour.
    behaviour_candidate: [
      ignore: [modules: ["ToolCall.Providers.*"]]
    ],
    # These maps are documented public return contracts, not interchangeable
    # domain records.
    fixed_shape_map: [
      ignore: [paths: ["lib/tool_call/doc.ex", "lib/tool_call/stream.ex"]]
    ]
  ]
]
