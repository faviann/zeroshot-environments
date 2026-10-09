#!/usr/bin/env bash
# Qualifies a built environment image as a Broodling DirectTarget: initialization, startup refusals,
# private mode and restart over its own state, then agent-UID checks of shared-tool immutability and
# tool invocation with run-local caches. Disposable Docker volumes only; no network, provider or real
# credential. Usage: scripts/qualify.sh IMAGE
set -euo pipefail
image=$1
run=zsq-$$
origin=http://127.0.0.1:18770
serve_args=(--listen 0.0.0.0:18770 --public-origin "$origin" --storage /state)
agent=10002:10002  # native's fixed hosted worker identity (HOSTED_WORKER_UID)

cleanup() {
  docker ps -aq --filter "label=$run" | xargs -r docker rm -f -v > /dev/null
  docker volume ls -q --filter "label=$run" | xargs -r docker volume rm > /dev/null
}
trap cleanup EXIT
fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
# The entrypoint over named volumes for state and home (Docker fills a new home from the image),
# with a root-only bootstrap key mounted unless --no-key comes first. --detach starts it in the background.
target() {
  local key=(--mount "src=$run-key,dst=/run/secrets,readonly") mode=--rm
  if [[ $1 == --no-key ]]; then key=(); shift; fi
  if [[ $1 == --detach ]]; then mode=--detach; shift; fi
  docker run "$mode" --label "$run" --network none "${key[@]}" \
    --mount "src=$run-state,dst=/state" --mount "src=$run-home,dst=/home/node" "$image" "$@"
}
refused() {  # refused DESCRIPTION MESSAGE TARGET-ARGUMENTS...
  local description=$1 message=$2 output
  shift 2
  if output=$(target "$@" 2>&1); then fail "$description: accepted"; fi
  [[ $output == *"$message"* ]] || fail "$description: unexpected output: $output"
  pass "$description refused"
}
# Serves the state until it listens, then requires an unauthenticated run request to be refused.
serve() {
  local container status
  container=$(target --detach "${serve_args[@]}")
  for _ in $(seq 60); do
    docker logs "$container" 2>&1 | grep -q "listening on 0.0.0.0:18770 as $origin" && break
    [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] \
      || fail "the target did not serve: $(docker logs "$container" 2>&1)"
    sleep 0.5
  done
  status=$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'content-type: application/json' -d '{}' http://127.0.0.1:18770/native-v2/run)
  [[ $status == 401 ]] || fail "an unauthenticated run request returned $status"
  docker rm -f -v "$container" > /dev/null
}

for volume in key state home tls-key tls-root; do docker volume create --label "$run" "$run-$volume" > /dev/null; done
docker run --rm --label "$run" --network none --mount "src=$run-key,dst=/k" --entrypoint sh "$image" \
  -c "openssl rand -hex 32 | tr -d '\n' > /k/zeroshot-bootstrap-key && chmod 0400 /k/zeroshot-bootstrap-key"

output=$(target --no-key initialize "${serve_args[@]}" 2>&1) || fail "initialization of empty state and home: $output"
[[ $output == *'Native target state initialized'* ]] || fail "initialization of empty state and home: $output"
pass 'initialization of empty state and home'
refused 'initialization over initialized state' 'initialization requires empty state and home' \
  --no-key initialize "${serve_args[@]}"
refused 'startup without a bootstrap key' 'missing bootstrap key' --no-key "${serve_args[@]}"
refused 'startup with another origin' 'not bound to this public origin' \
  --listen 0.0.0.0:18770 --public-origin http://127.0.0.1:18771 --storage /state
tls=(--mount "src=$run-tls-key,dst=/tls-root-key" --mount "src=$run-tls-root,dst=/tls-root")
output=$(docker run --rm --label "$run" --network none "${tls[@]}" "$image" initialize-tls 2>&1) \
  || fail "TLS root initialization: $output"
[[ $output == *'TLS root created'* ]] || fail "TLS root initialization: $output"
pass 'TLS root initialization on empty locations'
if output=$(docker run --rm --label "$run" --network none "${tls[@]}" "$image" initialize-tls 2>&1); then
  fail 'TLS root initialization over an existing root: accepted'
fi
[[ $output == *'an existing root is never replaced'* ]] || fail "TLS root initialization over an existing root: $output"
pass 'TLS root initialization over an existing root refused'
serve
pass 'served privately: an unauthenticated run request is refused (401)'
serve
pass 'restart over its own state'

# Shared tools: nothing outside the temporary directories is writable by the agent UID. Directories
# the agent cannot read are skipped: it cannot reach their contents either.
writable=$(docker run --rm --label "$run" --network none --user "$agent" --workdir / --entrypoint sh "$image" -c \
  'find / -xdev \( -path /proc -o -path /tmp -o -path /var/tmp -o -path /run/lock -o -path /dev/shm \) -prune \
     -o ! -type l -writable -print 2> /dev/null || :')
[[ -z $writable ]] || fail "writable by $agent: $writable"
pass "no shared path outside the temporary directories is writable by $agent"

# Tool invocation as the agent UID on a read-only root, with HOME and TMPDIR of its own. One command
# per line: under set -e, any failing command fails the check.
docker run --rm --label "$run" --network none --read-only --tmpfs /tmp:exec --user "$agent" \
  --env HOME=/tmp/run --env TMPDIR=/tmp/run/tmp --env CODEX_HOME=/tmp/run/.codex --entrypoint bash "$image" -c '
  set -euo pipefail
  mkdir -p "$TMPDIR" "$CODEX_HOME"
  cd "$HOME"
  dotnet new console --output app > /dev/null 2>&1
  dotnet build app --disable-build-servers > /dev/null
  test "$(dotnet run --project app --no-build)" = "Hello, World!"
  test -d "$HOME/.nuget/NuGet"
  test -d "$HOME/.dotnet"
  printf "int main(void) { return 0; }\n" > c.c
  cc c.c -o c
  ./c
  git init --quiet repo
  git -C repo -c user.name=q -c user.email=q@q commit --quiet --allow-empty -m q
  python3 -c "import sqlite3, ssl"
  node -e ""
  cargo --version > /dev/null
  gh --version > /dev/null
  for harness in codex claude copilot; do "$harness" --version > /dev/null 2>&1; done' \
  || fail 'tool invocation with run-local caches'
pass "dotnet build/run, cc, git, python3, node, cargo, gh and harnesses ran as $agent with caches in its HOME"
