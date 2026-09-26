# Releasing

The six packages in this repository share one version and are released
together from one tag:

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

## Before publishing

1. Set the version in `@version` in all six `mix.exs` files.
2. In `CHANGELOG.md`, move the Unreleased entries under a heading for the
   version and date.
3. Switch the install instructions to Hex: the Packages section of `README.md`
   and `guides/getting-started.md`. Remove the "not yet published" notes in
   `README.md` and `guides/application-stack.md`.
4. Merge those changes, then tag the merge commit on `main` and push the tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

   The HexDocs "source" links point at this tag.

CI runs a packaging dry run on every pull request: `mix hex.build` for the core,
and `SNODO_HEX=1 mix hex.build` plus `mix docs --warnings-as-errors` for each
sibling. To run it locally:

```sh
mix hex.build
cd integrations/plug && SNODO_HEX=1 mix hex.build
```

## Publishing

Authenticate once with `mix hex.user auth`, or set `HEX_API_KEY`. Publish in
dependency order from a clean checkout of the tag. Each sibling fetches its
snodo dependency from Hex, so the previous step must be live first.

```sh
# 1. The core
mix hex.publish

# 2. Packages that depend only on the core
(cd extensions/tasks && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
(cd integrations/plug && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
(cd integrations/schema_jsv && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)

# 3. The Tasks stores, which depend on snodo_tasks
(cd extensions/tasks_postgres && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
(cd extensions/tasks_sqlite && SNODO_HEX=1 mix deps.get && SNODO_HEX=1 mix hex.publish)
```

`SNODO_HEX=1 mix deps.get` rewrites the siblings' `mix.lock` files. Discard
those changes afterwards; the committed lockfiles keep the path dependencies:

```sh
git checkout -- extensions/*/mix.lock integrations/*/mix.lock
```
