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
   starts at 1.0.0. The install snippets in the READMEs and
   `guides/getting-started.md` are listed there too, between the same markers
   written as HTML comments. The updater rewrites only full `x.y.z` versions,
   so other requirements in those snippets, such as `~> 1.12`, stay as they are.
2. release-please acts with the `RELEASE_PLEASE_TOKEN` secret, so its pull
   request runs the usual pull request workflows and gets the required checks.
   A pull request opened with the workflow token would start no workflows.
3. Merging the release pull request tags `v<version>`, creates the GitHub
   release, and runs the `publish-hex` job. That job publishes the core, then
   `snodo_tasks`, `snodo_plug`, and `snodo_jsv`, then the two Tasks stores,
   waiting for each tier to appear in the Hex index. It skips a package whose
   version is already on Hex, so a failed run can be rerun. It then builds six
   tarballs, fetches the published archives from Hex, and requires byte-for-byte
   matches before attesting the local builds and attaching them to the GitHub
   release. A rerun checks existing release assets instead of replacing them.

The workflow needs two secrets:

- `RELEASE_PLEASE_TOKEN`: a fine-grained personal access token for this
  repository with read and write access to Contents, Pull requests, and Issues.
  When the secret is empty or absent, release-please falls back to the workflow
  token: the release pull request's workflows then wait for approval
  (`gh api -X POST repos/joshrotenberg/snodo/actions/runs/<id>/approve` for
  each). A set but invalid token fails the run with "Bad credentials".
- `HEX_API_KEY`: a Hex API key that can publish the six packages. The
  `publish-hex` job runs in the `hex` environment and passes the key only to
  its publish step. Keep the key as a secret of that environment, and limit the
  environment's deployment branches and tags to `v*` tags.

The repository setting "Allow GitHub Actions to create and approve pull
requests" must stay on for the fallback to work.

Every action in the workflows is pinned to a commit SHA, with its version in a
comment. Dependabot updates both.

## Verifying release assets

Download an archive from the GitHub release and verify its build provenance:

```sh
gh release download vX.Y.Z --pattern 'snodo-X.Y.Z.tar'
gh attestation verify snodo-X.Y.Z.tar -R joshrotenberg/snodo \
  --signer-workflow joshrotenberg/snodo/.github/workflows/release-please.yml
```

The attestation binds the tarball's digest to the release workflow run. The
publish job compares each built tarball with the archive fetched from Hex, so
the release asset and the published package have the same bytes. Verification
checks the workflow identity and archive digest; it does not audit the source,
dependencies, or the behavior of the package after installation. A manual
`mix hex.publish` outside this workflow does not create these assets or
attestations. The first release with these assets will exercise the attestation
and upload steps in GitHub Actions. Pull request CI can check workflow syntax
and local package builds, but cannot create a release attestation.

## Before merging a release pull request

- Read the version and the generated `CHANGELOG.md` entry in the pull request.
- Confirm the README and guides describe the release. HexDocs "source" links
  point at the new tag.

CI also runs a packaging dry run on every pull request: `mix hex.build` for the
core, and `SNODO_HEX=1 mix hex.build` plus `mix docs --warnings-as-errors` for
each sibling.

## Publishing by hand

To publish an existing tag again, for example after `publish-hex` failed partway,
run the workflow by hand. Packages already on Hex are skipped. The job refuses a
tag that is not `vX.Y.Z`, is not on `main`, or does not match the version in all
six `mix.exs` files:

```sh
gh workflow run release-please.yml -f tag=vX.Y.Z
```

Without CI, publish from a clean checkout of the tag, in the same order, after
`mix hex.user auth` or with `HEX_API_KEY` set:

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
