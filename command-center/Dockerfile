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

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    NODE_ENV=production \
    STF_HOME=/opt/stf \
    MDF_HOME=/opt/mdf \
    PATH=/opt/node/bin:/opt/stf/bin:/opt/mdf/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Bookworm: qemu, KVM userspace, ZMQ, OpenJDK (for STF auth + adbkit-monkey),
# adb, mitmproxy, supervisord, nginx, lsof, util-linux (taskset for cpu pinning).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq xz-utils \
        qemu-system-x86 qemu-utils ovmf seabios cpu-checker bridge-utils \
        adb scrcpy \
        libzmq5 libprotobuf32 \
        graphicsmagick zip unzip \
        nginx supervisor \
        rethinkdb \
        openjdk-17-jre-headless \
        python3 python3-pip python3-venv \
        lsof procps psmisc taskset \
        gosu tini \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --break-system-packages --no-cache-dir \
        "mitmproxy==${MITMPROXY_VERSION}"

RUN curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /opt && mv /opt/node-v${NODE_VERSION}-linux-x64 /opt/node \
    && ln -sf /opt/node/bin/node /usr/local/bin/node \
    && ln -sf /opt/node/bin/npm  /usr/local/bin/npm \
    && ln -sf /opt/node/bin/npx  /usr/local/bin/npx

WORKDIR ${STF_HOME}
COPY stf/package*.json ./
RUN if [ -f package.json ]; then npm ci --omit=dev; else echo "STF submodule missing -- run: git submodule update --init command-center/stf"; fi
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

RUN cd stf-provider-emulator && npm ci --omit=dev \
    && for p in mdf-plugin-mitm mdf-plugin-recording mdf-plugin-ota-channel mdf-plugin-hvf-preview mdf-plugin-warmpool; do \
         (cd "$p" && npm ci --omit=dev) || true ; \
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
