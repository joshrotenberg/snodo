%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      parse_timeout: 5_000,
      color: true,
      plugins: [],
      requires: [],
      checks: %{
        extra: [],
        disabled: [
          {Credo.Check.Refactor.UtcNowTruncate, []}
        ]
      }
    }
  ]
}
