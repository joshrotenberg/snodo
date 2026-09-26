# Used by "mix format"
[
  inputs: [
    "{mix,.formatter}.exs",
    "{config,examples,lib,test}/**/*.{ex,exs}",
    # conformance/fixture holds a Mix project whose deps/ and _build/ are not ours.
    "conformance/*.{ex,exs}",
    "conformance/{fixture,support}/*.{ex,exs}"
  ]
]
