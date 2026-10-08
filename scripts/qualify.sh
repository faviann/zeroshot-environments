#!/usr/bin/env bash
# Qualifies a built environment image as a Broodling DirectTarget: initialization, startup refusals,
# private mode, restart over its own state and each listed state transition, then agent-UID checks of
# shared-tool immutability, run-local caches and tool invocation. Disposable Docker volumes only; no
# network, provider or real credential. Usage: scripts/qualify.sh IMAGE ENVIRONMENT_DIR
set -euo pipefail
image=$1
transitions=$(jq -r '.nativeStateTransitions.from[]' "$2/environment.json")
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
volume() { docker volume create --label "$run" "$run-$1" > /dev/null; }
# A bootstrap key file in its own volume, mounted as /run/secrets; root-owned with the given mode.
key() {
  volume "$1"
  docker run --rm --label "$run" --network none --user 0:0 --mount "src=$run-$1,dst=/k" --entrypoint sh "$image" \
    -c "openssl rand -hex 32 | tr -d '\n' > /k/zeroshot-bootstrap-key && chmod $2 /k/zeroshot-bootstrap-key"
}
# target IMAGE STATE HOME KEY [docker run options --] ARGS...: the entrypoint with these volumes.
target() {
  local img=$1 state=$2 home=$3 key=$4 options=()
  shift 4
  if [[ ${1-} == -* && " $* " == *" -- "* ]]; then
    while [[ $1 != -- ]]; do options+=("$1"); shift; done
    shift
  fi
  docker run --label "$run" --network none "${options[@]}" \
    --mount "src=$run-$state,dst=/state" --mount "src=$run-$home,dst=/home/node" \
    ${key:+--mount "src=$run-$key,dst=/run/secrets,readonly"} "$img" "$@"
}
refused() {  # refused DESCRIPTION MESSAGE IMAGE STATE HOME KEY ARGS...
  local description=$1 message=$2 img=$3 state=$4 home=$5 key=$6 output
  shift 6
  if output=$(target "$img" "$state" "$home" "$key" --rm -- "$@" 2>&1); then fail "$description: accepted"; fi
  [[ $output == *"$message"* ]] || fail "$description: unexpected output: $output"
  pass "$description refused"
}
# Serves STATE/HOME with IMAGE until it listens, then checks native's private mode and stops it.
serve() {
  local img=$1 state=$2 home=$3 container
  container=$(target "$img" "$state" "$home" key --detach -- "${serve_args[@]}")
  for _ in $(seq 60); do
    docker logs "$container" 2>&1 | grep -q "listening on 0.0.0.0:18770 as $origin" && break
    [[ $(docker inspect --format '{{.State.Running}}' "$container") == true ]] \
      || fail "$img did not serve $state: $(docker logs "$container" 2>&1)"
    sleep 0.5
  done
  docker exec "$container" sh -c '
    [ -z "$(ls -A /run/broodling-target)" ] || { echo "bootstrap key copy remains"; exit 1; }
    curl -fsS http://127.0.0.1:18770/.well-known/zeroshot-native-v2 | grep -q "\"authentication\":\"private_capability\"" \
      || { echo "discovery does not advertise private mode"; exit 1; }
    status=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "content-type: application/json" -d "{}" \
      http://127.0.0.1:18770/native-v2/run)
    [ "$status" = 401 ] || { echo "unauthenticated run request returned $status"; exit 1; }' \
    || fail "$img serving $state"
  docker rm -f -v "$container" > /dev/null
}
# Initializes fresh state with SOURCE, serves it, then serves the same state with this image.
transition() {
  local source=$1 id=$2
  volume "state-$id"; volume "home-$id"
  target "$source" "state-$id" "home-$id" "" --rm -- initialize "${serve_args[@]}" | grep -q 'Native target state initialized' \
    || fail "initializing with $source"
  serve "$source" "state-$id" "home-$id"
  serve "$image" "state-$id" "home-$id"
  pass "served state written by $source after a restart"
}

key key 0400
key loose-key 0644

# Initialization and its refusals.
volume state; volume home
target "$image" state home "" --rm -- initialize "${serve_args[@]}" | grep -q 'Native target state initialized' \
  || fail 'initialization of empty state and home'
pass 'initialization of empty state and home'
volume fresh-state; volume used-home
docker run --rm --label "$run" --network none --mount "src=$run-used-home,dst=/h" --entrypoint touch "$image" /h/file
empty='initialization requires empty state and home'
refused 'initialization over initialized state' "$empty" "$image" state home "" initialize "${serve_args[@]}"
refused 'initialization with only the home nonempty' "$empty" "$image" fresh-state used-home "" initialize "${serve_args[@]}"

# Ordinary startup refusals over the initialized state.
refused 'startup without a bootstrap key' 'missing bootstrap key' "$image" state home "" "${serve_args[@]}"
refused 'startup with a 0644 bootstrap key' 'must be owned by root with no group or other access' \
  "$image" state home loose-key "${serve_args[@]}"
refused 'startup with another origin' 'not bound to this public origin' "$image" state home key \
  --listen 0.0.0.0:18770 --public-origin http://127.0.0.1:18771 --storage /state

# Private serving, then a restart over the state it served, then each listed transition source.
serve "$image" state home
pass 'served privately: key copy unlinked, unauthenticated run request refused (401)'
serve "$image" state home
pass 'restart over its own state'
for source in $transitions; do transition "$source" "from-${source##*:}"; done

# Shared tools: nothing outside the temporary directories is writable by the agent UID.
# Directories the agent cannot read are skipped: it cannot reach their contents either.
writable=$(docker run --rm --label "$run" --network none --user "$agent" --workdir / --entrypoint sh "$image" -c \
  'find / -xdev \( -path /proc -o -path /tmp -o -path /var/tmp -o -path /run/lock -o -path /dev/shm \) -prune \
     -o ! -type l -writable -print 2> /dev/null || :')
[[ -z $writable ]] || fail "writable by $agent: $writable"
pass "no shared path outside the temporary directories is writable by $agent"

# Tool invocation and run-local caches: two runs with separate HOME/TMPDIR on a read-only root.
docker run --rm --label "$run" --network none --read-only --tmpfs /tmp:exec --user "$agent" --entrypoint bash "$image" -c '
  set -euo pipefail
  for run in a b; do
    export HOME=/tmp/$run TMPDIR=/tmp/$run/tmp CODEX_HOME=/tmp/$run/.codex
    mkdir -p "$TMPDIR" "$CODEX_HOME" && cd "$HOME"
    dotnet new console --output app > /dev/null 2>&1
    dotnet build app --disable-build-servers > /dev/null
    [ "$(dotnet run --project app --no-build)" = "Hello, World!" ]
    [ -d "$HOME/.nuget/NuGet" ] && [ -d "$HOME/.dotnet" ]
    printf "int main(void) { return 0; }\n" > c.c && cc c.c -o c && ./c
    git init --quiet repo && git -C repo -c user.name=q -c user.email=q@q commit --quiet --allow-empty -m q
    python3 -c "import sqlite3, ssl" && node -e "" && cargo --version > /dev/null && gh --version > /dev/null
    for harness in codex claude copilot; do $harness --version > /dev/null 2>&1; done
  done
  # Only directories (.NET IPC) may appear outside the two runs.
  stray=$(find /tmp -mindepth 1 \( -path /tmp/a -o -path /tmp/b \) -prune -o ! -type d -print)
  [ -z "$stray" ] || { echo "written outside the runs: $stray"; exit 1; }' \
  || fail 'tool invocation with run-local caches'
pass "dotnet build/run, cc, git, python3, node, cargo, gh and harnesses ran as $agent with caches in each run's HOME"
