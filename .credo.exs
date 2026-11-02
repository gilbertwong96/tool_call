%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Design.TagTODO, exit_status: 0},
        {ExSlop.Check.Readability.NarratorDoc, false}
      ]
    }
  ]
}
