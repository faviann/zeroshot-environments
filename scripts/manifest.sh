#!/usr/bin/env bash
# Writes the manifest of a built environment image to stdout, reading every installed fact from the
# image itself. environment.json is a subset of the manifest: the declared identity and the pinned or
# approved facts. The script fails if any of its values differs from what the image records. It also
# fails unless every component is fixed by artifact checksums or by the enclosing base image:
#   - every ADD in the Dockerfile carries a checksum and belongs to a component;
#   - the base's layers are the image's first layers, and what the manifest attributes to the base
#     (native, tools, OS packages) reads the same in the base;
#   - every installed harness npm package is declared, its published tarball has the declared
#     integrity, and the installed files are that tarball's files.
# Needs network access to pull the base and fetch the harness packages. The OS package list is
# recorded, not asserted. Usage: scripts/manifest.sh IMAGE ENVIRONMENT_DIR
set -euo pipefail
image=$1
dir=${2%/}
declared=$dir/environment.json
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
run_in() {  # run_in IMAGE COMMAND ARGUMENTS...
  local target=$1
  shift
  docker run --rm --network none --user 0:0 --env HOME=/root --env CODEX_HOME=/root/.codex \
    --entrypoint "$1" "$target" "${@:2}"
}
in_image() { run_in "$image" "$@"; }
version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1; }  # first x.y.z in a --version output
problems=$scratch/problems
problem() { printf '%s\n' "$@" >> "$problems"; }

# The Dockerfile is the only record of the base reference and of the recipe's downloaded artifacts,
# including the entrypoint's Broodling commit. The declared paths are the ones measured.
zeroshot=$(jq -r .native.zeroshot.path "$declared")
restic=$(jq -r .native.restic.path "$declared")
entrypoint=$(jq -r '.integration["broodling-entrypoint"].path' "$declared")
managed_settings=$(jq -r .harnesses.claude.managedSettings.path "$declared")
base_reference=$(sed -n 's/^FROM \([^ ]*\).*/\1/p' "$dir/Dockerfile")
base_digest=${base_reference#*@}
base_repository=${base_reference%@*}
base=${base_repository%:*}@$base_digest
# Each ADD with its continuation lines, as "sha256 url" when it carries a checksum.
adds=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ta' -e '}' "$dir/Dockerfile" | grep -E '^ADD ' || :)
artifacts=$(printf '%s\n' "$adds" | sed -nE 's/.*--checksum=sha256:([0-9a-f]{64}) +(https:[^ ]+).*/\1 \2/p' \
  | jq -R -n '[inputs | split(" ") | {key: (.[1] | sub(".*/"; "")), value: {url: .[1], sha256: .[0]}}] | from_entries')
if [[ $(printf '%s\n' "$adds" | grep -c '^ADD ') != $(jq length <<< "$artifacts") ]]; then
  problem 'Dockerfile: every ADD must download one https artifact pinned by --checksum=sha256'
fi
entrypoint_url=$(jq -r '[.[].url | select(startswith("https://raw.githubusercontent.com/faviann/broodling/"))] | first // ""' <<< "$artifacts")
entrypoint_source=${entrypoint_url#https://raw.githubusercontent.com/faviann/broodling/}

# The base, pinned by digest. A derived image keeps the base's layers as its first layers.
docker pull --quiet "$base" > /dev/null
if ! jq -e -n --argjson base "$(docker image inspect --format '{{json .RootFS.Layers}}' "$base")" \
  --argjson image "$(docker image inspect --format '{{json .RootFS.Layers}}' "$image")" \
  '$image[:($base | length)] == $base' > /dev/null; then
  problem "base: the image does not start with the layers of $base"
fi
# What the manifest attributes to the base. It must read the same in the image as in the base.
# The Rust toolchain tree is compared by content and links.
base_facts() {
  run_in "$1" sh -c 'printf "native %s\nzeroshot %s\nrestic %s\nresticSha256 %s\n" \
      "$("$0" --version)" "$(sha256sum "$0" | cut -d " " -f 1)" "$("$1" version)" "$(sha256sum "$1" | cut -d " " -f 1)"
    printf "rustupTree %s\n" "$(cd /opt/rustup && { find . -type f -exec sha256sum {} +; \
      find . -type l -exec sh -c "for l; do echo \"\$l -> \$(readlink \"\$l\")\"; done" sh {} +; } | sort | sha256sum)"
    printf "node %s\nharness-node %s\nnpm %s\nyarn %s\ncorepack %s\npython %s\npip %s\n" \
      "$(node --version)" "$(/opt/zeroshot/bin/node --version)" "$(npm --version)" "$(yarn --version)" \
      "$(corepack --version)" "$(python3 --version)" "$(pip --version | cut -d " " -f 1,2)"
    printf "rust %s\nrustup %s\nrust-components %s\ngcc %s\ngit %s\ngh %s\ndocker-cli %s\n" \
      "$(rustc --version)" "$(rustup --version 2> /dev/null)" "$(rustup default | cut -d " " -f 1): $(rustup component list --installed | paste -sd " ")" \
      "$(gcc -dumpfullversion)" "$(git --version)" "$(gh --version | head -n 1)" "$(docker --version)"' "$zeroshot" "$restic"
}
facts=$(base_facts "$image")
[[ $facts == "$(base_facts "$base")" ]] || problem "base: native, the Rust toolchain or tool versions differ from the base's"
fact() { sed -n "s/^$1 //p" <<< "$facts"; }
packages() { run_in "$1" dpkg-query -W -f '${Package}\t${Version}\t${Architecture}\n'; }

# The native startup interface: the discovery document native serves in the private mode the entrypoint
# starts it in, on loopback over throwaway state and key.
discovery=$(in_image sh -c 'umask 077 && mkdir /tmp/state && openssl rand -hex 32 | tr -d "\n" > /tmp/key
  "$0" target serve --listen 127.0.0.1:18770 --public-origin http://127.0.0.1:18770 --storage /tmp/state \
    --bootstrap-key-file /tmp/key > /tmp/serve.log 2>&1 &
  for _ in $(seq 100); do curl -fsS http://127.0.0.1:18770/.well-known/zeroshot-native-v2 2> /dev/null && exit; sleep 0.1; done
  cat /tmp/serve.log >&2; exit 1' "$zeroshot")

# Harnesses: every npm package installed under the harness prefix, as "path name version" relative to
# its node_modules root. Each must be declared under a harness, and its published tarball must have the
# declared integrity before it is unpacked.
harness_root=/opt/zeroshot/harness/lib/node_modules
installed=$(in_image node -e '
  const fs = require("fs"), path = require("path"), root = process.argv[1];
  const walk = (modules) => fs.readdirSync(path.join(root, modules), {withFileTypes: true}).forEach((entry) => {
    const dir = path.join(modules, entry.name);
    if (!entry.isDirectory() || entry.name.startsWith(".")) return;  // .bin links; stray files fail the count
    if (entry.name.startsWith("@")) return walk(dir);
    if (!fs.existsSync(path.join(root, dir, "package.json"))) return;
    const p = require(path.join(root, dir, "package.json"));
    console.log(`${dir}\t${p.name}\t${p.version}`);
    if (fs.existsSync(path.join(root, dir, "node_modules"))) walk(path.join(dir, "node_modules"));
  });
  walk("");' "$harness_root")
npm=$(jq -n '{}')
while IFS=$'\t' read -r installed_path name package_version; do
  key=$name@$package_version
  harness=$(jq -r --arg key "$key" '[.harnesses | to_entries[] | select(.value.artifacts[$key]) | .key] | first // ""' "$declared")
  if [[ -z $harness ]]; then
    problem "harnesses: installed npm package $key is not declared"
    continue
  fi
  url=https://registry.npmjs.org/$name/-/${name##*/}-$package_version.tgz
  tarball=$scratch/$(printf '%s' "$key" | tr '/@' '__').tgz
  curl --proto '=https' -fsSL --retry 3 -o "$tarball" "$url"
  integrity=sha512-$(openssl dgst -sha512 -binary "$tarball" | base64 -w 0)
  expected=$(jq -r --arg harness "$harness" --arg key "$key" '.harnesses[$harness].artifacts[$key].integrity' "$declared")
  if [[ $integrity != "$expected" ]]; then
    printf 'Manifest check failed:\nharnesses.%s: %s has integrity %s, expected %s\n' "$harness" "$url" "$integrity" "$expected" >&2
    exit 1
  fi
  mkdir -p "$scratch/unpacked/$installed_path"
  tar -xzf "$tarball" -C "$scratch/unpacked/$installed_path" --no-same-owner
  printf '%s\t%s\n' "$installed_path" "$name" >> "$scratch/unpacked.tsv"
  npm=$(jq --arg harness "$harness" --arg key "$key" --arg url "$url" --arg integrity "$integrity" \
    --arg sha256 "$(sha256sum "$tarball" | cut -d ' ' -f 1)" \
    '.[$harness][$key] = {url: $url, sha256: $sha256, integrity: $integrity}' <<< "$npm")
done <<< "$installed"
# Each installed package has exactly its tarball's files, byte for byte, and nothing else is installed:
# the counts match. Claude Code's install script replaces its placeholder bin/claude.exe with the
# binary of its platform package, which is verified on its own.
if [[ -s $scratch/unpacked.tsv ]]; then
  harness_files=$(docker run --rm --network none --user 0:0 --mount "type=bind,src=$scratch,dst=/verify,readonly" \
    --entrypoint bash "$image" -c '
    set -euo pipefail
    root=$1 count=0
    while IFS=$'"'\t'"' read -r dir name; do
      unpacked=/verify/unpacked/$dir/package installed=$root/$dir
      diff <(cd "$unpacked" && find . -type f | sort) \
        <(cd "$installed" && find . -path ./node_modules -prune -o -type f -print | sort) > /dev/null \
        || { echo "$name: installed files differ from its tarball"; continue; }
      [[ -z $(find "$installed" -path "$installed/node_modules" -prune -o ! -type f ! -type d -print) ]] \
        || echo "$name: installed links or special files are not in its tarball"
      while IFS= read -r -d "" file; do
        count=$((count + 1))
        source=$unpacked/$file
        [[ $name/$file == "@anthropic-ai/claude-code/./bin/claude.exe" ]] \
          && source=$installed/node_modules/@anthropic-ai/claude-code-linux-x64/claude
        cmp -s "$source" "$installed/$file" || echo "$name: $file differs from its tarball"
      done < <(cd "$unpacked" && find . -type f -print0)
    done < /verify/unpacked.tsv
    [[ $count == $(find "$root" -type f | wc -l) ]] || echo "$root holds files of no verified package"' \
    bash "$harness_root")
  [[ -z $harness_files ]] || sed 's/^/harnesses: /' <<< "$harness_files" >> "$problems"
fi

observed=$(jq -n \
  --arg platform "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" \
  --arg baseReference "$base_reference" --arg baseDigest "$base_digest" \
  --arg baseRevision "$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$base")" \
  --arg recipeRevision "$(git rev-parse HEAD)" --arg recipePath "$dir" \
  --arg os "$(in_image sh -c '. /etc/os-release && echo "$PRETTY_NAME"')" \
  --arg nativeVersion "$(fact native | version)" \
  --arg zeroshotSha256 "$(fact zeroshot)" \
  --arg resticVersion "$(fact restic | version)" \
  --arg resticSha256 "$(fact resticSha256)" \
  --argjson entrypointCommand "$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image")" \
  --argjson discovery "$discovery" \
  --arg entrypointSha256 "$(in_image sha256sum "$entrypoint" | cut -d ' ' -f 1)" \
  --arg entrypointRevision "${entrypoint_source%%/*}" --arg entrypointPath "${entrypoint_source#*/}" \
  --arg sdks "$(in_image dotnet --list-sdks | cut -d ' ' -f 1)" \
  --arg runtimes "$(in_image dotnet --list-runtimes | cut -d ' ' -f 1,2)" \
  --arg codex "$(in_image codex --version 2> /dev/null | version)" \
  --arg claude "$(in_image claude --version | version)" \
  --arg managedSettingsSha256 "$(in_image sha256sum "$managed_settings" | cut -d ' ' -f 1)" \
  --arg copilot "$(in_image copilot --version | version)" \
  --argjson npm "$npm" \
  --arg tools "$(sed -n '/^node /,$p' <<< "$facts")" \
  --arg packages "$(packages "$image")" --arg basePackages "$(packages "$base")" \
  --argjson artifacts "$artifacts" \
  'def lines: split("\n") | map(select(. != ""));
  def artifact(f): {fixedBy: "artifacts", artifacts: ($artifacts | with_entries(select(.key | f)))};
  ($basePackages | lines) as $base
  | {
    recipe: {repository: "https://github.com/faviann/zeroshot-environments", revision: $recipeRevision, path: $recipePath},
    platform: $platform,
    os: $os,
    base: {reference: $baseReference, digest: $baseDigest, revision: $baseRevision},
    native: {
      version: $nativeVersion,
      zeroshot: {sha256: $zeroshotSha256},
      restic: {version: $resticVersion, sha256: $resticSha256},
      fixedBy: "base"
    },
    startupInterfaces: {entrypoint: {command: $entrypointCommand}, native: {discovery: $discovery}},
    integration: {"broodling-entrypoint": ({
      source: {repository: "https://github.com/faviann/broodling", revision: $entrypointRevision, path: $entrypointPath},
      sha256: $entrypointSha256
    } + artifact(. == ($entrypointPath | sub(".*/"; ""))))},
    dotnet: ({sdks: ($sdks | lines), runtimes: ($runtimes | lines)} + artifact(startswith("dotnet-sdk-"))),
    harnesses: ({codex: $codex, claude: $claude, copilot: $copilot}
      | with_entries(.value = {version: .value, fixedBy: "artifacts", artifacts: ($npm[.key] // {})})
      | .claude.managedSettings = {sha256: $managedSettingsSha256}),
    tools: ($tools | lines | map(capture("^(?<key>[^ ]+) (?<value>.*)$") | .value = {version: .value, fixedBy: "base"})
      | from_entries),
    osPackages: ($packages | lines | map(. as $line | split("\t") | {name: .[0], version: .[1], architecture: .[2]}
      | "\(.name)_\(.version | sub("^[0-9]+:"; ""))_\(.architecture).deb" as $file
      | if $artifacts[$file] then . + artifact(. == $file)
        elif $line | IN($base[]) then . + {fixedBy: "base"}
        else . end))
  }')

# Every recipe artifact belongs to a component, every component fixed by artifacts names one, and every
# OS package is the base's or a recipe artifact.
jq -r --argjson artifacts "$artifacts" '
  ([.. | objects | select(.fixedBy == "artifacts") | .artifacts | keys[]] | unique) as $used
  | ($artifacts | keys - $used | .[] | "Dockerfile: artifact \(.) belongs to no component"),
    (paths(type == "object" and .fixedBy == "artifacts" and (.artifacts | length) == 0)
      | "\(map(tostring) | join(".")): fixed by artifacts but has none"),
    (.osPackages[] | select(.fixedBy == null) | "osPackages: \(.name) \(.version) is neither the base'"'"'s nor a recipe artifact")
  ' <<< "$observed" >> "$problems"
manifest=$(jq -n --slurpfile expected "$declared" --argjson observed "$observed" '
  {schema: "zeroshot-environment.manifest/v2", environment: {release: null}, image: {tag: null, digest: null}}
  * $expected[0] * $observed | .native.sourceRevision = .base.revision')
# Every declared leaf (arrays compare whole) must equal what the image shows, except the declarations
# themselves: identity, the entrypoint's interface version, the paths that get measured, and transitions.
jq -r -n --slurpfile expected "$declared" --argjson observed "$observed" '
  $expected[0] | (paths(type != "object") | select(all(.[]; type == "string"))) as $path
  | select(($path | IN(["environment", "name"], ["image", "repository"],
      ["startupInterfaces", "entrypoint", "version"], ["nativeStateTransitions", "from"])) or $path[-1] == "path" | not)
  | ($path | join(".")) as $name | ($observed | try getpath($path) catch null) as $actual
  | if $actual == null then "\($name): declared but not measured from the image"
    elif $actual != getpath($path) then "\($name): image has \($actual | tojson), expected \(getpath($path) | tojson)"
    else empty end' >> "$problems"
if jq -e '.nativeStateTransitions.from | length > 0' "$declared" > /dev/null; then
  problem 'nativeStateTransitions.from: add transition qualification to qualify.sh before advertising a source'
fi
if [[ -s $problems ]]; then
  printf 'Manifest check failed:\n%s\n' "$(cat "$problems")" >&2
  exit 1
fi
printf '%s\n' "$manifest"
