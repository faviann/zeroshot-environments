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
for any change to the image: an SDK, an OS package, the base, or an integration input. The release
number is independent of the Zeroshot version, which the manifest records. Published tags are never
moved. Select an image by the digest in its manifest, not by its tag.

## The `dotnet` environment

The image is built on upstream's published target image for stock native 10.10.0. The base is used
as published, pinned by digest, and not rebuilt. Its contents are recorded by inspecting the built
image. The image adds:

- .NET SDK 10.0.401, with ASP.NET Core and .NET runtimes 10.0.12, in `/usr/share/dotnet`. It is
  registered in `/etc/dotnet/install_location`, and `libicu76` is added for globalization.
- Broodling's target entrypoint at `/usr/local/bin/broodling-target`, from Broodling commit
  [`4bd7abb`](https://github.com/faviann/broodling/blob/4bd7abbe308f94ff401196921ef1891f6b414edc/deployment/direct-target-entrypoint.sh),
  verified by SHA-256. It replaces the base's entrypoint and command.

The image keeps everything the base ships, as shipped: Codex, Claude Code and Copilot CLI, Node 24,
Python 3.12, Rust 1.97, a C toolchain, git, gh and the Docker CLI. The manifest lists them. Having a
tool installed authorizes nothing. No Docker socket or daemon is provided.

Broodling's build and test prerequisites are a .NET 10 SDK, git, `cc` with libc headers, and
`python3` for its asset check. Package-read and other runtime credentials come through the
consumer's dispatch path. They never appear in the image, its history or a manifest.

### Deviations from the base

- **`/opt/rustup`:** the base leaves its Rust toolchain world-writable, including `rustc`. The
  image removes group and other write permission, so agents cannot modify a shared tool.
- **`/home/node`:** the base ships skeleton files there. The image empties it (root-owned, `0700`),
  because initialization requires an empty home. Without this, Docker would copy those files into a
  new named volume mounted at `/home/node`.
- **Unused volume:** the base declares `VOLUME /var/lib/zeroshot`. A derived image cannot remove
  it, so every container gets an anonymous volume there. Nothing uses it, so remove it with the
  container (`docker rm -v`).
- **Broodling's `check-target`:** at `4bd7abb`, it pins Codex 0.153.4 and the release-archive
  `zeroshot` checksum (`d0c84ffb…`). It rejects this image until Broodling takes the native identity
  from the adopted manifest ([#234](https://github.com/faviann/broodling/issues/234)). This image's
  native is the base's source build, SHA-256 `fd5ffef2…`, with Codex 0.155.0.

### Target interface

The entrypoint's interface is Broodling's, documented in its
[deployment guide at `4bd7abb`](https://github.com/faviann/broodling/blob/4bd7abbe308f94ff401196921ef1891f6b414edc/deployment/README.md#explicit-initialization-and-guarded-startup).
The fixed parts are:

- **Paths:** state at `/state` and home at `/home/node`, with `CODEX_HOME=/home/node/.codex`.
- **Listener:** `0.0.0.0:18770`.
- **Bootstrap key:** a root-only file at `/run/secrets/zeroshot-bootstrap-key`.
- **Process identity:** the container runs as root with Docker's default capabilities.

Initialize with `initialize --listen 0.0.0.0:18770 --public-origin ORIGIN --storage /state`. Start
with the same arguments without `initialize`, and use `initialize-tls` once for the TLS root.

The public origin and the Compose names are deployment parameters. Initialization records the
origin, and ordinary startup refuses any other origin. Moving used state to another origin is a
Broodling stopped-target transition. Never re-initialize over used state. Neither mode changes native
UID ownership.

### Runs on the target

Native runs every agent as its fixed hosted identity, UID/GID `10002`. Each run gets its own `HOME`
and `TMPDIR`, so .NET, NuGet, npm and Cargo caches stay with the run. `/tmp`, `/var/tmp` and
`/run/lock` remain shared, sticky directories. A tool that ignores `TMPDIR` can leave files there
that other runs see: .NET, for example, keeps its IPC endpoints and build-server pipes under `/tmp`.
For strict separation, the consumer should build with `--disable-build-servers`.

A submission's `environment.setup` hook runs as root. It can change OS packages shared by every run.
Excluding it is Broodling's rule, not something this image enforces.

## Manifest

Each release publishes `manifest.json` with schema `zeroshot-environment.manifest/v1`. A breaking
change to the schema gets a new version. The fields are:

- **`environment`:** the `name` and `release`.
- **`image`:** the `repository`, `tag` and the `digest` that the publishing push produced.
- **`recipe`:** this repository, the `revision` built and the recipe `path`.
- **`platform`, `os`:** the target platform and the OS release.
- **`base`:** the pinned `reference` and its `revision` label. `layersArePrefix` confirms that the
  image is built on exactly those layers.
- **`native`:** the `version`, the `sourceRevision`, and the path and SHA-256 of `zeroshot` and of
  `restic`, plus restic's `version`.
- **`integration`:** each integration input, with its path, source (repository, commit, path) and
  SHA-256. Today that is only `broodling-entrypoint`.
- **`dotnet`:** the installed `sdks` and `runtimes`.
- **`harnesses`:** the `codex`, `claude` and `copilot` versions.
- **`tools`:** node, python, rust, gcc, git, gh and docker-cli, as each reports its version.
- **`imageAdjustments`:** the deviations from the base.
- **`osPackages`:** every installed Debian package, read from dpkg (name, version, architecture).
- **`nativeStateTransitions.from`:** the published images whose native state this release was
  qualified to serve.
- **`qualification`:** the workflow run that qualified and published the image.

[`scripts/manifest.sh`](scripts/manifest.sh) reads every fact from the built image. It fails if any
pinned or approved fact differs from [`environment.json`](environments/dotnet/environment.json): the
platform, base layers and revision, native and restic versions and checksums, the entrypoint
checksum, the .NET SDKs and runtimes, and the harness versions. The OS package list is recorded, not
asserted.

## Qualification

[`scripts/qualify.sh`](scripts/qualify.sh) runs against disposable Docker volumes with no network,
provider or real credential. It checks that:

- Initialization succeeds on empty state and home, and is refused over initialized state or a
  nonempty home.
- Startup is refused without a bootstrap key, with a `0644` key, and with another origin.
- The target serves only in private mode: the key copy is unlinked, discovery advertises
  `private_capability`, and an unauthenticated run request gets `401`.
- The target restarts over its own state. It also serves the state of each image listed in
  `nativeStateTransitions.from` (none yet). A transition is advertised only when that check passes.
- As UID 10002, nothing outside the temporary directories is writable.
- As UID 10002, on a read-only root filesystem, two runs with separate homes each build and run a
  .NET console app, compile C, use git, python3, node, cargo and gh, and start each harness. Caches
  land in each run's home.

Broodling's adoption (#234) and repository validation (#236) separately establish SDK, workflow,
build and test behaviour.

## Build, check and publish

Locally:

```bash
docker build -t zeroshot-env-dotnet:local environments/dotnet
scripts/manifest.sh zeroshot-env-dotnet:local environments/dotnet > manifest.json
scripts/qualify.sh zeroshot-env-dotnet:local environments/dotnet
```

The [workflow](.github/workflows/environments.yml) runs the same three steps on every pull request
and push to `main`. To publish a release, push its tag, `git tag dotnet-r1 && git push origin
dotnet-r1`. Do not create the GitHub release first: that creates the tag too, and the workflow's
release creation then fails after the image is pushed.

On a release tag, the workflow does the following:

1. Builds, checks and qualifies the image.
2. Refuses if the tag already exists in GHCR.
3. Pushes the image and records the pushed digest in the manifest.
4. Creates the GitHub release with `manifest.json` and `qualification.log`.

If the run fails after the push, the tag is not a release and has no record. Publish a new `N`. The
package is public. Visibility is a package setting, so check it after the first publication.

## Retention

- **Recipes, manifests and qualification logs:** kept indefinitely, in Git and on GitHub releases.
  Workflow artifacts are only a convenience and expire.
- **Images:** keep every image that active execution uses or that a supported rollback needs, which
  means each environment's adopted release and the release before it. Never delete such an image.
- **Older images:** they may be deleted once no adoption or rollback needs them. Their records
  remain, but keeping old images operable is not promised.
- **Rebuilds:** rebuilding a recipe produces a compatible new environment, not identical bytes. Such
  a rebuild is published as a new release.
