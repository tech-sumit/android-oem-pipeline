# MayaOS Device Farm — unified container.
#
# Bundles in one image:
#   - DeviceFarmer/stf (orchestrator + web UI)            -- from ./stf submodule
#   - stf-provider-emulator (boots N qemu instances)      -- from ./stf-provider-emulator
#   - mdf-plugin-{mitm,recording,ota-channel,hvf-preview,warmpool}
#   - qemu-system-x86_64 + KVM (for x86_64 emulator)
#   - rethinkdb (in-container by default; cluster mode via Compose for HA)
#   - mitmproxy (per-instance, supervised by mdf-plugin-mitm)
#   - nginx (TLS termination + Cloudflare Tunnel sidecar in fleet compose)
#   - supervisord (the in-container PID 1 that ties it all together)
#
# Sizing rationale (rev 5.1 §6):
#   per-instance: 1.5 GB RAM with KSM, 1.0 vCPU avg with cgroups,
#                 ~250 MB qcow2 overlay, 30 s warm boot.
#   one A6000 pod (48 GB GPU / 252 GB RAM / 64 vCPU) -> ~80-100 instances tuned.

FROM node:18-bookworm AS node-builder
WORKDIR /opt/build
COPY stf-provider-emulator/package*.json ./stf-provider-emulator/
RUN cd stf-provider-emulator && npm ci --omit=dev || true

FROM debian:bookworm-slim

ARG STF_REF=master
ARG NODE_VERSION=18.20.4
ARG MITMPROXY_VERSION=11.0.2
ARG SCRCPY_VERSION=3.3.4

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NODE_ENV=production \
    STF_HOME=/opt/stf \
    MDF_HOME=/opt/mdf \
    PATH=/opt/node/bin:/opt/stf/bin:/opt/mdf/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Bookworm: qemu, KVM userspace, ZMQ, OpenJDK (for STF auth + adbkit-monkey),
# adb, mitmproxy, supervisord, nginx, lsof, util-linux (taskset for cpu pinning).
#
# Notes on the moving parts:
#   * scrcpy    -- NOT packaged in bookworm or bookworm-backports (it lives in
#                  bullseye, trixie-backports, forky, and sid only). Installed
#                  from the upstream Genymobile/scrcpy GitHub release tarball
#                  in a separate RUN below. We do install the runtime libs
#                  (libsdl2, libav*, libusb) here so the dynamic linker is
#                  satisfied when the binary runs.
#   * rethinkdb -- removed from Debian after stretch when its license was in
#                  limbo; install from the upstream community apt repo at
#                  download.rethinkdb.com (debian-bookworm channel exists and
#                  serves the 2.4.4 stable line, which is what STF expects).
#   * taskset   -- not its own package; lives inside util-linux which is
#                  already in the base image, so we drop it from the apt list.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq xz-utils \
        qemu-system-x86 qemu-utils ovmf seabios cpu-checker bridge-utils \
        adb \
        libzmq5 libprotobuf32 \
        graphicsmagick zip unzip \
        nginx supervisor \
        openjdk-17-jre-headless \
        python3 python3-pip python3-venv \
        lsof procps psmisc util-linux \
        gosu tini \
        libsdl2-2.0-0 libavcodec59 libavformat59 libavutil57 libswresample4 \
        libusb-1.0-0 \
    && curl -fsSL https://download.rethinkdb.com/repository/raw/pubkey.gpg \
        | gpg --dearmor -o /usr/share/keyrings/rethinkdb-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/rethinkdb-keyring.gpg] https://download.rethinkdb.com/repository/debian-bookworm bookworm main" \
        > /etc/apt/sources.list.d/rethinkdb.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends rethinkdb \
    && rm -rf /var/lib/apt/lists/*

# scrcpy upstream-binary install. The release tarball ships:
#   - scrcpy        (single statically-linkable binary; our libsdl2/libav*/libusb
#                   apt installs above satisfy its dynamic deps)
#   - scrcpy-server (Android-side dex pushed to the device on each connection;
#                   lives in /usr/local/share/scrcpy/ where SCRCPY_SERVER_PATH
#                   defaults to)
#   - adb           (we keep the upstream platform-tools adb already installed
#                   above and skip this duplicate)
RUN curl -fsSL "https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-linux-x86_64-v${SCRCPY_VERSION}.tar.gz" \
        | tar -xz -C /tmp \
    && install -m 0755 "/tmp/scrcpy-linux-x86_64-v${SCRCPY_VERSION}/scrcpy" /usr/local/bin/scrcpy \
    && install -d -m 0755 /usr/local/share/scrcpy \
    && install -m 0644 "/tmp/scrcpy-linux-x86_64-v${SCRCPY_VERSION}/scrcpy-server" /usr/local/share/scrcpy/scrcpy-server \
    && rm -rf "/tmp/scrcpy-linux-x86_64-v${SCRCPY_VERSION}" \
    && scrcpy --version 2>&1 | head -1

RUN python3 -m pip install --break-system-packages --no-cache-dir \
        "mitmproxy==${MITMPROXY_VERSION}"

RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /opt && mv /opt/node-v${NODE_VERSION}-linux-x64 /opt/node \
    && ln -sf /opt/node/bin/node /usr/local/bin/node \
    && ln -sf /opt/node/bin/npm  /usr/local/bin/npm \
    && ln -sf /opt/node/bin/npx  /usr/local/bin/npx

WORKDIR ${STF_HOME}
COPY stf/package*.json ./
# Upstream DeviceFarmer/stf at v3.7.2 ships package.json but NOT
# package-lock.json (their dev workflow uses `npm shrinkwrap` only on
# release, and v3.7.2 wasn't tagged from a shrinkwrapped tree). `npm ci`
# refuses to run without a lockfile, so fall back to `npm install` whose
# only behavioral difference is that it WRITES the resulting lockfile if
# missing -- which is fine inside a build layer.
RUN if [ -f package.json ]; then \
        if [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then \
            npm ci --omit=dev; \
        else \
            npm install --omit=dev --no-audit --no-fund; \
        fi; \
    else \
        echo "STF submodule missing -- run: git submodule update --init command-center/stf"; \
    fi
COPY stf/ ./
RUN if [ -f bin/stf ]; then echo "STF source present"; else echo "STF source missing"; fi

WORKDIR ${MDF_HOME}
COPY stf-provider-emulator/  stf-provider-emulator/
COPY mdf-plugin-mitm/        mdf-plugin-mitm/
COPY mdf-plugin-recording/   mdf-plugin-recording/
COPY mdf-plugin-ota-channel/ mdf-plugin-ota-channel/
COPY mdf-plugin-hvf-preview/ mdf-plugin-hvf-preview/
COPY mdf-plugin-warmpool/    mdf-plugin-warmpool/
COPY templates/              templates/
COPY scripts/                scripts/
COPY perf/                   perf/
COPY sql/                    sql/

# Same lockfile-fallback story as STF: our in-tree workspaces commit
# package.json without a lockfile (deliberate -- we want `npm install` to
# resolve fresh deps from the registry on each image bake, not pin to a
# stale tree). `|| true` on the plugin loops because some plugins are still
# scaffolds without a real package.json yet.
RUN _npm_install_dir() { \
        local dir="$1"; \
        if [ ! -f "$dir/package.json" ]; then return 0; fi; \
        if [ -f "$dir/package-lock.json" ] || [ -f "$dir/npm-shrinkwrap.json" ]; then \
            (cd "$dir" && npm ci --omit=dev); \
        else \
            (cd "$dir" && npm install --omit=dev --no-audit --no-fund); \
        fi; \
    } \
    && _npm_install_dir stf-provider-emulator \
    && for p in mdf-plugin-mitm mdf-plugin-recording mdf-plugin-ota-channel mdf-plugin-hvf-preview mdf-plugin-warmpool; do \
         _npm_install_dir "$p" || true ; \
       done

RUN install -d -m 0755 /var/lib/mdf /var/lib/mdf/instances /var/lib/mdf/snapshots \
                       /var/lib/mdf/recordings /var/lib/mdf/mitm \
                       /var/log/mdf /var/log/stf /run/mdf

COPY supervisord/supervisord.conf /etc/supervisor/supervisord.conf
COPY supervisord/conf.d/          /etc/supervisor/conf.d/
COPY nginx/nginx.conf             /etc/nginx/nginx.conf
COPY nginx/conf.d/                /etc/nginx/conf.d/

RUN useradd --system --home /var/lib/mdf --shell /bin/bash mdf \
    && chown -R mdf:mdf /var/lib/mdf /var/log/mdf /run/mdf

EXPOSE 7100 7110 7400 7410 7170 7160 28015 29015 8080

VOLUME ["/var/lib/mdf", "/srv/mayaos-images"]

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
