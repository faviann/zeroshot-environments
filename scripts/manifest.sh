#!/usr/bin/env bash
# Writes the manifest of a built environment image to stdout, reading every installed fact from the
# image itself. environment.json is a subset of the manifest: the declared identity and the pinned or
# approved facts. The script fails if any of its values differs from what the image records. The OS
# package list is recorded, not asserted. Usage: scripts/manifest.sh IMAGE ENVIRONMENT_DIR
set -euo pipefail
image=$1
dir=${2%/}
in_image() {
  docker run --rm --network none --user 0:0 --env HOME=/root --env CODEX_HOME=/root/.codex \
    --entrypoint "$1" "$image" "${@:2}"
}
sha256() { in_image sha256sum "$1" | cut -d ' ' -f 1; }
version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }  # first x.y.z in a --version output
# The Dockerfile is the only record of the base reference and of the entrypoint's Broodling commit.
# The declared paths are the ones measured.
zeroshot=$(jq -r .native.zeroshot.path "$dir/environment.json")
restic=$(jq -r .native.restic.path "$dir/environment.json")
entrypoint=$(jq -r '.integration["broodling-entrypoint"].path' "$dir/environment.json")
base_reference=$(sed -n 's/^FROM \([^ ]*\).*/\1/p' "$dir/Dockerfile")
entrypoint_url=$(grep -oE 'https://raw\.githubusercontent\.com/faviann/broodling/[0-9a-f]{40}/[^ ]+' "$dir/Dockerfile")
entrypoint_source=${entrypoint_url#https://raw.githubusercontent.com/faviann/broodling/}

observed=$(jq -n \
  --arg platform "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" \
  --arg baseReference "$base_reference" \
  --arg recipeRevision "$(git rev-parse HEAD)" --arg recipePath "$dir" \
  --arg os "$(in_image sh -c '. /etc/os-release && echo "$PRETTY_NAME"')" \
  --arg nativeVersion "$(in_image "$zeroshot" --version | version)" \
  --arg zeroshotSha256 "$(sha256 "$zeroshot")" \
  --arg resticVersion "$(in_image "$restic" version | version)" \
  --arg resticSha256 "$(sha256 "$restic")" \
  --arg entrypointSha256 "$(sha256 "$entrypoint")" \
  --arg entrypointRevision "${entrypoint_source%%/*}" --arg entrypointPath "${entrypoint_source#*/}" \
  --arg sdks "$(in_image dotnet --list-sdks | cut -d ' ' -f 1)" \
  --arg runtimes "$(in_image dotnet --list-runtimes | cut -d ' ' -f 1,2)" \
  --arg codex "$(in_image codex --version 2> /dev/null | version)" \
  --arg claude "$(in_image claude --version | version)" \
  --arg copilot "$(in_image copilot --version | version)" \
  --arg tools "$(in_image sh -c 'printf "node %s\npython %s\nrust %s\ngcc %s\ngit %s\ngh %s\ndocker-cli %s\n" \
      "$(node --version)" "$(python3 --version)" "$(rustc --version)" "$(gcc -dumpfullversion)" \
      "$(git --version)" "$(gh --version | head -n 1)" "$(docker --version)"')" \
  --arg packages "$(in_image dpkg-query -W -f '${Package}\t${Version}\t${Architecture}\n')" \
  'def lines: split("\n") | map(select(. != ""));
  {
    recipe: {repository: "https://github.com/faviann/zeroshot-environments", revision: $recipeRevision, path: $recipePath},
    platform: $platform,
    os: $os,
    base: {reference: $baseReference},
    native: {
      version: $nativeVersion,
      zeroshot: {sha256: $zeroshotSha256},
      restic: {version: $resticVersion, sha256: $resticSha256}
    },
    integration: {"broodling-entrypoint": {
      source: {repository: "https://github.com/faviann/broodling", revision: $entrypointRevision, path: $entrypointPath},
      sha256: $entrypointSha256
    }},
    dotnet: {sdks: ($sdks | lines), runtimes: ($runtimes | lines)},
    harnesses: {codex: $codex, claude: $claude, copilot: $copilot},
    tools: ($tools | lines | map(capture("^(?<key>[^ ]+) (?<value>.*)$")) | from_entries),
    osPackages: ($packages | lines | map(split("\t") | {name: .[0], version: .[1], architecture: .[2]}))
  }')

# Observed facts win the merge; every expected leaf (arrays compare whole) must equal its manifest value.
manifest=$(jq -n --slurpfile expected "$dir/environment.json" --argjson observed "$observed" '
  {schema: "zeroshot-environment.manifest/v1", environment: {release: null}, image: {tag: null, digest: null}}
  * $expected[0] * $observed | .native.sourceRevision = .base.revision')
problems=$(jq -r -n --slurpfile expected "$dir/environment.json" --argjson manifest "$manifest" '
  $expected[0] | (paths(type != "object") | select(all(.[]; type == "string"))) as $path
  | select(($manifest | getpath($path)) != getpath($path))
  | "\($path | map(tostring) | join(".")): image has \($manifest | getpath($path) | tojson), expected \(getpath($path) | tojson)"')
if jq -e '.nativeStateTransitions.from | length > 0' "$dir/environment.json" > /dev/null; then
  problems=${problems:+$problems$'\n'}"nativeStateTransitions.from: add transition qualification to qualify.sh before advertising a source"
fi
if [[ -n $problems ]]; then
  printf 'Manifest check failed:\n%s\n' "$problems" >&2
  exit 1
fi
printf '%s\n' "$manifest"
