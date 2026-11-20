#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Keep the consumer outside the worktree, even if TMPDIR points inside it.
scratch=$(mktemp -d /tmp/snodo-release-smoke.XXXXXXXX)
server_pid=
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Leave the caller's Hex repositories and cache alone. Mix still uses the
# installed Hex archive and Rebar.
export HEX_HOME="$scratch/hex"
export MIX_ENV=prod
unset MIX_BUILD_PATH MIX_DEPS_PATH MIX_LOCKFILE MIX_EXS HEX_UNSAFE_HTTPS HEX_UNSAFE_REGISTRY HEX_NO_VERIFY_REPO_ORIGIN

cd "$repo_root"
version=$(awk -F '"' '/^  @version "/ {print $2}' mix.exs)
registry="$scratch/public"
mkdir -p "$registry/tarballs" "$scratch/consumer"

build() {
  local package=$1 directory=$2
  (cd "$directory" && SNODO_HEX=1 mix hex.build --output "$registry/tarballs/$package-$version.tar")
}

build snodo .
build snodo_tasks extensions/tasks
build snodo_plug integrations/plug
build snodo_jsv integrations/schema_jsv
build snodo_oauth integrations/oauth
build snodo_telemetry integrations/telemetry
build snodo_proxy integrations/proxy
build snodo_otp integrations/otp
build snodo_tasks_postgres extensions/tasks_postgres
build snodo_tasks_sqlite extensions/tasks_sqlite

cd "$scratch"
openssl genrsa -out private_key.pem 2048
mix hex.registry build public --name=local --private-key=private_key.pem

# Let the OS choose a free port and report it only after the socket is ready.
python3 - "$registry" "$scratch/port" <<'PY' &
import functools
import http.server
import pathlib
import sys

handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1])
with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
    pathlib.Path(sys.argv[2]).write_text(f"{server.server_port}\n")
    server.serve_forever()
PY
server_pid=$!
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ ! -s port ]] || break
  kill -0 "$server_pid"
  sleep 0.1
done
if ! read -r port < port; then
  echo "Local Hex registry did not report a port" >&2
  exit 1
fi
export NO_PROXY="127.0.0.1${NO_PROXY:+,$NO_PROXY}"
export no_proxy="127.0.0.1${no_proxy:+,$no_proxy}"
mix hex.repo add local "http://127.0.0.1:$port" --public-key=public/public_key

cd consumer
cp "$repo_root/scripts/release_smoke/"{mix.exs,smoke.exs} .
export SNODO_SMOKE_VERSION="$version"
export SNODO_HEX=1
mix deps.get
mix compile --warnings-as-errors
mix run smoke.exs
