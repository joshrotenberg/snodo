# Contributing to snodo

Thanks for considering a contribution. This guide covers how work is organized and what a pull request needs. [AGENTS.md](AGENTS.md) has the same rules in reference form, with every command, and applies equally to people and to coding agents.

## Finding something to work on

Open issues are labeled so you can pick one without asking first:

| Label | Meaning |
|---|---|
| `p1`, `p2`, `p3` | Priority: blocking, standard queue, nice to have |
| `size/small`, `size/medium`, `size/large` | About 1 to 3, 4 to 10, or more than 10 changed files |
| `area/protocol`, `area/client`, `area/transport`, `area/extensions`, `area/ci`, `area/docs` | Where the change lands |
| `good first issue` | Small and well scoped; a good place to start |

Each issue describes the gap and proposes a shape for the change. If you disagree with the proposal, or the scope is unclear, comment on the issue before writing much code. Check the open pull requests first, so two people are not working on the same thing.

To propose something new, open an issue with the feature request or bug report form. For a security problem, follow [SECURITY.md](SECURITY.md) instead of opening an issue.

## Setting up

You need Elixir 1.18 or later on OTP 27 or later, and Node.js 24 for the interop and conformance checks. PostgreSQL is only needed for the live tests of `snodo_tasks_postgres`.

```sh
git clone https://github.com/joshrotenberg/snodo.git
cd snodo
mix setup
(cd interop/official_client && npm ci --ignore-scripts)
```

This repository builds eight Hex packages: the core `snodo` at the root, and seven siblings under `integrations/` and `extensions/`. `mix setup` fetches dependencies for all of them.

## Making a change

1. Branch from `main`.
2. Open a draft pull request early, and describe your plan in its body. Early feedback is cheaper than a rewrite.
3. Keep the change focused on one issue. Unrelated fixes you notice along the way go in their own issue or pull request.
4. Add or update tests with the change. Protocol behavior is covered by acceptance tests in `test/`; literal protocol messages live in `test/compliance/`.
5. Update the guides or module docs when behavior changes. Do not edit `CHANGELOG.md` or version numbers; the release process writes them.

A few design rules are firm, because users depend on them:

- The core package has no Hex runtime dependencies. A feature that needs one goes in a sibling package.
- Wire names (`MCP-Protocol-Version`, `Mcp-Method`, `io.modelcontextprotocol/*`) never change.
- Handler arguments and results use the protocol's string keys.
- Convenience APIs are built on the low-level modules, not the other way around.
- Integration with a specific external system goes behind a behaviour, such as the Tasks store, subscription source, or authorization policy, not into the core.

[AGENTS.md](AGENTS.md) lists these with the reasons.

## Before you push

Run the same checks CI runs:

```sh
mix quality
MIX_ENV=test mix quality.types
MIX_ENV=dev mix docs --warnings-as-errors
mix compile && (cd interop/official_client && npm run check)
```

If your change touches a transport or anything on the wire, also run the conformance lanes and the wire-schema check (see [conformance/AGENTS.md](conformance/AGENTS.md) and [interop/AGENTS.md](interop/AGENTS.md)).

A weekly workflow, [repeat-until-failure.yml](.github/workflows/repeat-until-failure.yml), runs every package's suite many times in a row three ways, with default schedulers, with two schedulers (`ERL_FLAGS="+S 2:2"`), and under competing CPU load, to find tests that fail only under load or with an unlucky ordering. It is not a required check. When it finds one, it opens or updates an issue labeled `flaky` with the test and the seed. To check a new or changed test the same way before pushing:

```sh
mix test test/my_test.exs --repeat-until-failure 30 --max-failures 1
ERL_FLAGS="+S 2:2" mix test test/my_test.exs --repeat-until-failure 30 --max-failures 1
```

## Commits and pull requests

- Commit messages and pull request titles use [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `ci:`, `perf:`, `refactor:`, `chore:`. The release notes are generated from them.
- A breaking change gets `!` in the title (`fix!: ...`) and a `BREAKING CHANGE:` paragraph in a commit message that explains what users must change.
- Close issues with one keyword each: `Closes #12. Closes #13.`
- In the pull request body, say what changed and why, how it is tested, and anything left for later. The template prompts for this.
- Pull requests are squash-merged once CI is green and the change has been reviewed.

## Writing style

Guides, docs, and commit messages are plain and factual. Describe what the code does and what changed; skip marketing language. The project does not use em dashes.

## License

By contributing, you agree that your contributions are licensed under the project's [MIT License](LICENSE).
