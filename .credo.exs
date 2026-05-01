%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "test_helpers/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: %{
        extra: [
          {ExSlop, []}
        ]
      }
    }
  ]
}
