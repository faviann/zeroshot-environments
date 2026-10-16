# Zeroshot environments

Preconfigured stock Zeroshot target images, each with its own release identity, a machine-readable
manifest and qualification evidence. This repository builds and publishes them. It does not adopt or
deploy them: Broodling approves which environment an execution may use
([#234](https://github.com/faviann/broodling/issues/234),
[#235](https://github.com/faviann/broodling/issues/235)), and homelab-iac deploys the images.

| Environment | Recipe | Image | Platform |
| --- | --- | --- | --- |
| `dotnet` | [`environments/dotnet`](environments/dotnet) | `ghcr.io/faviann/zeroshot-environments/dotnet` | `linux/amd64` |

## Release identity

A release is `<environment>-r<N>`, for example `dotnet-r1`. Its image tag is `r<N>`. `N` increases
for any change to the image (an SDK, an OS package, the base, or an integration input) or to its
manifest schema. The release number is independent of the Zeroshot version, which the manifest
records. Published tags are never moved. Select an image by the digest in its manifest, not by its
tag.

## The `dotnet` environment

The image is built on upstream's published target image for stock native 10.12.0, used as published
and pinned by digest. It adds the .NET SDK, Claude Code's managed settings and Broodling's target
entrypoint, which replaces the base's entrypoint and command. Everything the base ships stays as
shipped and is listed in the manifest. Having a tool installed authorizes nothing. No Docker socket
or daemon is provided.

Broodling's build and test prerequisites are a .NET 10 SDK, git, `cc` with libc headers, and
`python3` for its asset check. Package-read and other runtime credentials come through the
consumer's dispatch path. They never appear in the image, its history or a manifest.

### Deviations from the base

- **`/home/node`:** the base ships skeleton files there. The image empties it (root-owned, `0700`),
  because initialization requires an empty home. Without this, Docker would copy those files into a
  new named volume mounted at `/home/node`.
- **Harness updates:** the image sets `DISABLE_AUTOUPDATER=1` for Claude Code and
  `COPILOT_AUTO_UPDATE=false` for Copilot CLI, so neither replaces itself with a version the
  manifest does not record. They reach only processes that inherit the container's environment.
- **Claude Code managed settings:** native's hosted Claude lane starts each agent with a cleared
  environment, so the image's environment variables never reach a Claude Code agent. Claude Code
  reads `/etc/claude-code/managed-settings.json` whatever its environment. The image installs
  [`managed-settings.json`](environments/dotnet/managed-settings.json) there as one line of JSON and
  a newline, owned by root with mode `0644`, in a root-owned `0755` directory. The settings turn off
  nonessential traffic, remove the commit and pull request attribution, and allow only managed hooks
  and managed MCP servers. The image declares no managed hook or MCP server. The settings also set
  every model call's effort to `medium` and its output limit to 32000 tokens, and a repository's own
  settings cannot raise either. They skip WebFetch's domain check, a request to `api.anthropic.com`
  that names the fetched domain. If the file is missing, Claude Code runs without these policies and
  reports nothing. If it cannot read the file, it reports that only on stderr.
- **Unused volume:** the base declares `VOLUME /var/lib/zeroshot`. A derived image cannot remove
  it, so every container gets an anonymous volume there. Nothing uses it, so remove it with the
  container (`docker rm -v`).

### Target interface

The image has two startup interfaces, and the manifest names a version for each under
`startupInterfaces`:

- **`entrypoint`:** `zeroshot-environment.direct-target-startup/v1`, the container interface below.
  Broodling owns this interface and its version value. The manifest records it for the embedded
  entrypoint at `4bd7abb`.
- **`native`:** the discovery document that native serves at `/.well-known/zeroshot-native-v2`
  once the entrypoint has started it. Its `kind`, `zeroshot.native-v2-target/v2`, is native's own
  protocol version, and `authentication` is `private_capability`. The extension kinds are native's
  too, and the manifest declares each extension's `kind`. It records the document as native serves it.

The parts below summarize Broodling's
[deployment guide at `4bd7abb`](https://github.com/faviann/broodling/blob/4bd7abbe308f94ff401196921ef1891f6b414edc/deployment/README.md#explicit-initialization-and-guarded-startup),
which is authoritative:

- **Paths:** state at `/state` and home at `/home/node`, with `CODEX_HOME=/home/node/.codex`.
- **Listener:** `0.0.0.0:18770`.
- **Bootstrap key:** a root-only file at `/run/secrets/zeroshot-bootstrap-key`.
- **Process identity:** the container runs as root with Docker's default capabilities.
- **Commands:** the image entrypoint is `/usr/local/bin/broodling-target`, with no default command.
  Initialize with `initialize --listen 0.0.0.0:18770 --public-origin ORIGIN --storage /state`. Start
  with the same arguments without `initialize`, and use `initialize-tls` once for the TLS root, with
  its key at `/tls-root-key` and its certificate at `/tls-root`.
- **Refusals:** initialization refuses non-empty state or home, ordinary startup refuses a missing
  or unprotected key, and `initialize-tls` never replaces an existing root.

The public origin and the Compose names are deployment parameters. Initialization records the
origin, and ordinary startup refuses any other origin. Moving used state to another origin is a
Broodling stopped-target transition. Never re-initialize over used state. Neither mode changes native
UID ownership.

### Runs on the target

Native 10.12 runs each run's agents as a per-run UID, `20000` for the first run, with GID `10002`
(native `928de8ff`, `zeroshot/src/execution/process.rs:254-258` and `process/tests.rs:68-80`). Each
run gets its own `HOME` and `TMPDIR`, so .NET, NuGet, npm and Cargo caches stay with the run. `/tmp`, `/var/tmp` and
`/run/lock` remain shared, sticky directories. A tool that ignores `TMPDIR` can leave files there
that other runs see: .NET, for example, keeps its IPC endpoints and build-server pipes under `/tmp`.
For strict separation, the consumer should build with `--disable-build-servers`.

A submission's `environment.setup` hook runs as root. It can change OS packages shared by every run.
Excluding it is Broodling's rule, not something this image enforces.

## Manifest

Each release publishes `manifest.json` with schema `zeroshot-environment.manifest/v2`. A change to
the schema that a consumer must handle gets a new version: a new required field, a changed shape or
a changed meaning. `dotnet-r1` was published with `v1`, which lacked the startup interfaces and the
component checksums. The fields are:

- **`environment`:** the `name` and `release`.
- **`image`:** the `repository`, `tag` and the `digest` that the publishing push produced.
- **`recipe`:** this repository, the `revision` built and the recipe `path`.
- **`platform`, `os`:** the target platform and the OS release.
- **`base`:** the pinned `reference`, its `digest`, and its `revision`, read from the base's
  `org.opencontainers.image.revision` label.
- **`native`:** the `version`, the `sourceRevision`, and the path and SHA-256 of `zeroshot` and of
  `restic`, plus restic's `version`.
- **`startupInterfaces`:** the `entrypoint` interface `version` and the image's `command`, and the
  `native` `discovery` document. See [Target interface](#target-interface).
- **`integration`:** each integration input, with its path, source (repository, commit, path) and
  SHA-256. Today that is only `broodling-entrypoint`.
- **`dotnet`:** the installed `sdks` and `runtimes`.
- **`harnesses`:** the `codex`, `claude` and `copilot` versions, each with its npm packages.
  `claude.managedSettings` has the path and SHA-256 of Claude Code's managed settings. It is not a
  component. Its bytes are the recipe's `managed-settings.json`, and `environment.json` declares
  its SHA-256.
- **`tools`:** node, harness-node, npm, yarn, corepack, python, pip, rust, rustup,
  rust-components, gcc, git, gh and docker-cli, each with its version as the tool reports it.
- **`osPackages`:** every installed Debian package, read from dpkg (name, version, architecture).
- **`nativeStateTransitions.from`:** the published images whose native state this release was
  qualified to serve.
- **`qualification`:** the workflow run that qualified and published the image.

### Component checksums

Every component in `native`, `integration`, `dotnet`, `harnesses`, `tools` and `osPackages` has an
exact version and a `fixedBy` value, which says what fixes its bytes:

- **`artifacts`:** the component comes from the downloads in its `artifacts` map, each with its
  `url` and `sha256`. npm packages also have npm's `integrity`, the SHA-512 that the registry
  publishes.
- **`base`:** the component is part of the base image, which the recipe pins by digest. The base's
  bytes cannot change without changing `base.digest`.

| Component | `fixedBy` | Checksum and how it is checked |
| --- | --- | --- |
| .NET SDK, with its runtimes | `artifacts` | The SDK archive's SHA-256, which `ADD --checksum` verifies during the build. The runtimes ship in that archive. |
| `libicu76` | `artifacts` | The `.deb`'s SHA-256, which `ADD --checksum` verifies during the build. |
| `broodling-entrypoint` | `artifacts` | The script's SHA-256, which `ADD --checksum` verifies during the build. |
| Codex, Claude Code, Copilot CLI | `artifacts` | Each npm package's `integrity`. The base installed them, and npm checked those values then. `manifest.sh` downloads each tarball again, requires the declared `integrity`, and requires the installed files to be the tarball's files. |
| `native` (`zeroshot`, `restic`) | `base` | The base digest. The executables' SHA-256 values identify them and are asserted, but they are build outputs with no published checksum. |
| Tools: node, the harness interpreter copy at `/opt/zeroshot/bin/node`, npm, yarn, corepack, python, pip, rust, rustup, the installed Rust components, gcc, git, gh, docker-cli | `base` | The base digest. |
| Other OS packages | `base` | The base digest. |

The base digest encloses the base's OS packages and tools. Upstream publishes per-artifact
checksums for them, for example the `.deb` SHA-256 values in the Debian archive, which
snapshot.debian.org keeps. The manifest does not record those checksums. `manifest.sh` checks that
each OS package and tool is the base's.

[`environment.json`](environments/dotnet/environment.json) is the declared subset of the manifest.
[`scripts/manifest.sh`](scripts/manifest.sh) asserts each declared value against the image, except
the identity, the entrypoint interface version, the measured paths and the transitions. The base
revision is asserted against the base's label. It records everything else from the image. It also fails in these cases:

- An `ADD` in the Dockerfile has no checksum, or a downloaded artifact belongs to no component.
- The base's layers are not the image's first layers.
- `native`, `tools` or the content and links of the Rust toolchain at `/opt/rustup` read
  differently in the base.
- An OS package is neither the base's, with the same version, nor a recipe `.deb`.
- An installed harness npm package is not declared in `environment.json`, or its files differ from
  its published tarball, or it contains links or special files. File modes are not compared.

The harness check downloads about 345 MB of npm tarballs, so `manifest.sh` needs network access to
the npm registry and to pull the base.

## Qualification

[`scripts/qualify.sh`](scripts/qualify.sh) checks the target's startup behaviour and the tools as
the first run's agent, UID `20000` with GID `10002`, with no network, provider or real credential.
It checks that root owns the managed settings and their directory with modes `0644` and `0755`, and
that the agent reads the declared SHA-256. It then starts Claude Code as the agent and fails if its
stderr reports `Managed settings failed to load`. Restart is qualified only over the image's own
fresh state. Before any image is listed in `nativeStateTransitions.from`, add
transition checks like Broodling #125's: an update from that image's state to the new one. Broodling's
adoption (#234) and repository validation (#236) separately establish SDK, workflow, build and test
behaviour.

## Build and publish

```bash
docker build -t zeroshot-env-dotnet:local environments/dotnet
scripts/manifest.sh zeroshot-env-dotnet:local environments/dotnet > manifest.json
scripts/qualify.sh zeroshot-env-dotnet:local
```

To publish a release, push only its tag, for example
`git tag dotnet-r2 && git push origin dotnet-r2`. If a GitHub release of that name exists already,
the workflow refuses to publish. If a run fails after the push, the tag is not a release and has no
record; publish a new `N`. The package is public. Visibility is a package setting, so check it after
the first publication.

## Retention

- **Recipes, manifests and qualification logs:** kept indefinitely, in Git and on GitHub releases.
  Workflow artifacts are only a convenience and expire.
- **Images:** keep every image that active execution uses or that a supported rollback needs, which
  means each environment's adopted release and the release before it. Never delete such an image.
- **Older images:** they may be deleted once no adoption or rollback needs them. Their records
  remain, but keeping old images operable is not promised.
- **Rebuilds:** rebuilding a recipe produces a compatible new environment, not identical bytes. Such
  a rebuild is published as a new release.
