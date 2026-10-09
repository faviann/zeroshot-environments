# The .NET environment: stock Zeroshot target 10.10.0 plus the .NET SDK and Broodling's target
# entrypoint. Every input is pinned by checksum or digest; the base is used as published, not rebuilt.
# Build with this directory as context:
#   docker build -t zeroshot-env-dotnet:local environments/dotnet
FROM ghcr.io/the-open-engine/zeroshot-target:10.10.0@sha256:9769f74865d7e1137b82c9ed2ced4cbedb56cfd5fef6c9e8c0647955ba0c438b

# .NET SDK 10.0.401. ADD verifies sha256 only; these bytes match the sha512 Microsoft publishes in its
# 10.0 releases.json (51c8b999af9e8dd9…ba90311fbce25b), checked when pinned.
ADD --checksum=sha256:137268c8ad939c064ff1ee2a6fdf0899d8725377114ea012fbd1ad5fa2550418 \
    https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.401/dotnet-sdk-10.0.401-linux-x64.tar.gz /tmp/dotnet-sdk.tar.gz
# ICU for .NET globalization; the base ships libc6, libgcc-s1 and libstdc++6, its only dependencies.
ADD --checksum=sha256:c1bf762996de9ecba9b9d871e4928a8090f023a3e9e7fa3240b3d90f892a01dc \
    https://snapshot.debian.org/archive/debian/20260918T000000Z/pool/main/i/icu/libicu76_76.1-4_amd64.deb /tmp/libicu76.deb
# Broodling's target entrypoint from an exact Broodling commit; Broodling owns its source and interface.
ADD --chmod=755 --checksum=sha256:76c526fe8c51be094dbc48527c40181f5b0f23069996f3c4315c456a49107b79 \
    https://raw.githubusercontent.com/faviann/broodling/4bd7abbe308f94ff401196921ef1891f6b414edc/deployment/direct-target-entrypoint.sh \
    /usr/local/bin/broodling-target

RUN dpkg --install /tmp/libicu76.deb \
    && install -d -m 0755 /usr/share/dotnet /etc/dotnet \
    && tar -xzf /tmp/dotnet-sdk.tar.gz -C /usr/share/dotnet --no-same-owner \
    && chmod -R go-w /usr/share/dotnet \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet \
    && echo /usr/share/dotnet > /etc/dotnet/install_location \
    && rm /tmp/dotnet-sdk.tar.gz /tmp/libicu76.deb \
    # The base leaves its Rust toolchain world-writable; agents must not modify shared tools.
    && find /opt/rustup -perm /022 ! -type l -exec chmod go-w {} + \
    # Initialization requires an empty home; Docker would copy the base's skeleton files into a volume.
    && rm -rf /home/node && install -d -m 0700 /home/node \
    && dotnet --info > /dev/null

# Caches and first-run state stay under each run's own HOME: no shared NUGET_PACKAGES or DOTNET_CLI_HOME.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    HOME=/home/node \
    CODEX_HOME=/home/node/.codex
WORKDIR /home/node
ENTRYPOINT ["/usr/local/bin/broodling-target"]
CMD []

ARG RELEASE=unreleased
ARG REVISION=unknown
LABEL org.opencontainers.image.source=https://github.com/faviann/zeroshot-environments \
      org.opencontainers.image.title="Zeroshot environment: dotnet" \
      org.opencontainers.image.version=$RELEASE \
      org.opencontainers.image.revision=$REVISION
