# Releasing

The six packages in this repository share one version and are released
together from one `v<version>` tag:

| Package | Directory |
|---|---|
| `snodo` | `.` |
| `snodo_tasks` | `extensions/tasks` |
| `snodo_plug` | `integrations/plug` |
| `snodo_jsv` | `integrations/schema_jsv` |
| `snodo_tasks_postgres` | `extensions/tasks_postgres` |
| `snodo_tasks_sqlite` | `extensions/tasks_sqlite` |

Inside the repository each sibling depends on `snodo` (the Tasks stores on
`snodo_tasks`) by path. Hex does not accept path dependencies, so a sibling is
built and published with `SNODO_HEX=1`, which makes its `mix.exs` require the
released package at the same version instead.

## How a release happens

[release-please](https://github.com/googleapis/release-please) runs on every
push to `main` ([release-please.yml](.github/workflows/release-please.yml)):

1. It keeps a release pull request open. The pull request sets the next
   version in all six `mix.exs` files (`release-please-config.json` lists the
   sibling files, whose `@version` lines sit between
   `x-release-please-start-version` and `x-release-please-end` comments) and
   adds the release's `CHANGELOG.md` entry. Both come from the
   conventional commit titles merged since the last release: `feat` and `fix`
   entries, and breaking changes marked with `!`. Before 1.0, a breaking
   change bumps the minor version and a feature bumps the patch version. The
   first release is 0.1.0 (`initial-version`); without it, release-please
   starts at 1.0.0.
2. Pull requests opened by the workflow token do not start other workflows, so
   the same workflow dispatches the Compatibility and Protocol workflows on the
   release branch. Their runs satisfy the required checks.
3. Merging the release pull request tags `v<version>`, creates the GitHub
   release, and runs the `publish-hex` job. That job publishes the core, then
   `snodo_tasks`, `snodo_plug`, and `snodo_jsv`, then the two Tasks stores,
   waiting for each tier to appear in the Hex index. It skips a package whose
   version is already on Hex, so a failed run can be rerun.

The job authenticates with the repository secret `HEX_API_KEY`. The repository
setting "Allow GitHub Actions to create and approve pull requests" must stay on
for release-please to open its pull request.

## Before merging a release pull request

- Read the version and the generated `CHANGELOG.md` entry in the pull request.
- Confirm the README and guides describe the release. HexDocs "source" links
  point at the new tag.

CI also runs a packaging dry run on every pull request: `mix hex.build` for the
core, and `SNODO_HEX=1 mix hex.build` plus `mix docs --warnings-as-errors` for
each sibling.

## Publishing by hand

If the `publish-hex` job cannot run, publish from a clean checkout of the tag,
in the same order, after `mix hex.user auth` or with `HEX_API_KEY` set:

```sh
mix hex.publish

(cd extensions/tasks && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
(cd integrations/plug && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
(cd integrations/schema_jsv && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)

(cd extensions/tasks_postgres && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
(cd extensions/tasks_sqlite && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
```

`SNODO_HEX=1 mix deps.get` rewrites the siblings' `mix.lock` files. Discard
those changes afterwards:

```sh
git checkout -- extensions/*/mix.lock integrations/*/mix.lock
```
