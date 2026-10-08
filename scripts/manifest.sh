#!/usr/bin/env bash
# Writes the manifest of a built environment image to stdout, reading every installed fact from the
# image itself, and fails if a pinned or approved fact differs from the environment's
# environment.json. Usage: scripts/manifest.sh IMAGE ENVIRONMENT_DIR
set -euo pipefail
image=$1
expected=$2/environment.json
in_image() { docker run --rm --network none --user 0:0 --env HOME=/root --env CODEX_HOME=/root/.codex --entrypoint "$1" "$image" "${@:2}"; }
sha256() { in_image sha256sum "$1" | cut -d ' ' -f 1; }
version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }  # first x.y.z in a --version output

base=$(jq -r .base.reference "$expected")
docker pull --quiet "$base" > /dev/null
base_layers=$(docker image inspect --format '{{json .RootFS.Layers}}' "$base")
image_layers=$(docker image inspect --format '{{json .RootFS.Layers}}' "$image")
base_revision=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$base")
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
entrypoint=$(jq -r '.integration["broodling-entrypoint"].path' "$expected")

manifest=$(jq -n \
  --slurpfile env "$expected" \
  --argjson baseLayers "$base_layers" --argjson imageLayers "$image_layers" \
  --arg baseRevision "$base_revision" --arg platform "$platform" \
  --arg recipeRevision "$(git rev-parse HEAD)" --arg recipePath "${2#./}" \
  --arg nativeVersion "$(in_image zeroshot --version | version)" \
  --arg zeroshotSha256 "$(sha256 /usr/local/bin/zeroshot)" \
  --arg resticVersion "$(in_image restic version | version)" \
  --arg resticSha256 "$(sha256 /usr/local/bin/restic)" \
  --arg entrypointSha256 "$(sha256 "$entrypoint")" \
  --arg sdks "$(in_image dotnet --list-sdks | cut -d ' ' -f 1)" \
  --arg runtimes "$(in_image dotnet --list-runtimes | cut -d ' ' -f 1,2)" \
  --arg codex "$(in_image codex --version 2>/dev/null | version)" \
  --arg claude "$(in_image claude --version | version)" \
  --arg copilot "$(in_image copilot --version | version)" \
  --arg os "$(in_image sh -c '. /etc/os-release && echo "$PRETTY_NAME"')" \
  --arg tools "$(in_image sh -c 'printf "node %s\npython %s\nrust %s\ngcc %s\ngit %s\ngh %s\ndocker-cli %s\n" \
      "$(node --version)" "$(python3 --version)" "$(rustc --version)" "$(gcc -dumpfullversion)" \
      "$(git --version)" "$(gh --version | head -n 1)" "$(docker --version)"')" \
  --arg packages "$(in_image dpkg-query -W -f '${Package}\t${Version}\t${Architecture}\n')" \
  '$env[0] as $env | def lines: split("\n") | map(select(. != ""));
  {
    schema: "zeroshot-environment.manifest/v1",
    environment: {name: $env.name, release: null},
    image: {repository: $env.repository, tag: null, digest: null},
    recipe: {repository: "https://github.com/faviann/zeroshot-environments", revision: $recipeRevision, path: $recipePath},
    platform: $platform,
    os: $os,
    base: {
      reference: $env.base.reference,
      revision: $baseRevision,
      layersArePrefix: ($imageLayers[:($baseLayers | length)] == $baseLayers)
    },
    native: {
      version: $nativeVersion,
      sourceRevision: $baseRevision,
      zeroshot: {path: $env.native.zeroshot.path, sha256: $zeroshotSha256},
      restic: {path: $env.native.restic.path, version: $resticVersion, sha256: $resticSha256}
    },
    integration: {"broodling-entrypoint": ($env.integration["broodling-entrypoint"] + {sha256: $entrypointSha256})},
    dotnet: {sdks: ($sdks | lines), runtimes: ($runtimes | lines)},
    harnesses: {codex: $codex, claude: $claude, copilot: $copilot},
    tools: ($tools | lines | map(capture("^(?<key>[^ ]+) (?<value>.*)$")) | from_entries),
    imageAdjustments: [
      "/opt/rustup: group/other write removed from the base toolchain",
      "/home/node: emptied, root-owned 0700"
    ],
    osPackages: ($packages | lines | map(split("\t") | {name: .[0], version: .[1], architecture: .[2]})),
    nativeStateTransitions: $env.nativeStateTransitions
  }')

# Only the pinned and approved facts are asserted; the OS package list is recorded, not asserted.
problems=$(jq -r -n --argjson m "$manifest" --slurpfile env "$expected" '$env[0] as $e |
  def check($name; $actual; $wanted): if $actual == $wanted then empty else "\($name): image has \($actual | tojson), expected \($wanted | tojson)" end;
  check("platform"; $m.platform; $e.platform),
  check("base layers"; $m.base.layersArePrefix; true),
  check("base revision"; $m.base.revision; $e.base.revision),
  check("native version"; $m.native.version; $e.native.version),
  check("native source revision"; $m.native.sourceRevision; $e.native.sourceRevision),
  check("zeroshot sha256"; $m.native.zeroshot.sha256; $e.native.zeroshot.sha256),
  check("restic version"; $m.native.restic.version; $e.native.restic.version),
  check("restic sha256"; $m.native.restic.sha256; $e.native.restic.sha256),
  check("broodling-entrypoint sha256"; $m.integration["broodling-entrypoint"].sha256; $e.integration["broodling-entrypoint"].sha256),
  check(".NET SDKs"; $m.dotnet.sdks; $e.dotnet.sdks),
  check(".NET runtimes"; $m.dotnet.runtimes; $e.dotnet.runtimes),
  check("harnesses"; $m.harnesses; $e.harnesses)')
if [[ -n $problems ]]; then
  printf 'Manifest check failed: %s\n' "$problems" >&2
  exit 1
fi
printf '%s\n' "$manifest"
