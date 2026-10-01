# Used by "mix format"
locals_without_parens = [
  argument: 1,
  argument: 2,
  argument: 3,
  argument: 4,
  annotations: 1,
  description: 1,
  icons: 1,
  metadata: 1,
  title: 1,
  input_schema: 1,
  output_schema: 1,
  prompt: 1,
  prompt: 2,
  prompt: 3,
  resource: 1,
  resource: 2,
  resource: 3,
  tool: 1,
  tool: 2,
  tool: 3
]

[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,examples,lib,test}/**/*.{ex,exs}",
    # conformance/fixture holds a Mix project whose deps/ and _build/ are not ours.
    "conformance/*.{ex,exs}",
    "conformance/{fixture,support}/*.{ex,exs}"
  ],
  # Exported for projects that use the DSL; this repository keeps the parentheses.
  export: [locals_without_parens: locals_without_parens]
]
