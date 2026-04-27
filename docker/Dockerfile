# syntax=docker/dockerfile:1.6
#
# AOSP 16 (android-16.0.0_r4) build environment.
#
# Patterns borrowed from:
#   - lineageos4microg/docker-lineage-cicd  (env-var + volume + hook contract)
#   - alexanderwolz/aosp-docker             (AOSP 14+ apt deps)
#   - cdlee/aosp-builder                    (Ubuntu 22.04 minimal base)
#
# This is intentionally NOT based on a third-party AOSP image; we want full
# control of the apt set so we can pin AOSP 16 prereqs (which need a newe
# build-essential and JDK than older bases ship).
#
FROM ubuntu:22.04

LABEL org.opencontainers.image.source="https://github.com/tech-sumit/android-oem-pipeline"
LABEL org.opencontainers.image.description="AOSP 16 build environment for the CustomOS OEM flavor"
LABEL org.opencontainers.image.licenses="Proprietary"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    USE_CCACHE=1 \
    CCACHE_DIR=/srv/ccache \
    CCACHE_EXEC=/usr/bin/ccache

# ---------------------------------------------------------------------------
# Build dependencies for AOSP 16. These are the union of the official AOSP
# "Establishing a build environment" list (https://source.android.com/docs/setup/start/initializing)
# and the deps actually pulled in by lineageos4microg's image, dropping things
# only LineageOS needs (e.g. signature-spoofing patches, microG keys).
# ---------------------------------------------------------------------------
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
        bc bison bsdmainutils build-essential ca-certificates ccache cgpt clang \
        cmake cpio cron curl flex g++-multilib gcc-multilib git git-lfs gnupg \
        gperf imagemagick kmod \
        lib32ncurses5-dev lib32readline-dev lib32z1-dev liblz4-tool \
        libelf-dev libncurses5 libncurses5-dev libsdl1.2-dev libssl-dev \
        libxml2 libxml2-utils lsof lzop \
        m4 maven nano \
        openjdk-21-jdk-headless openssl \
        pigz pkg-config pngcrush procps python3 python3-pip python3-distutils \
        rsync schedtool squashfs-tools sudo tzdata unzip \
        wget xdelta3 xsltproc xxd xz-utils \
        yasm zip zlib1g-dev zstd \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates

# Python 'python' shim (some older AOSP scripts still expect /usr/bin/python).
RUN ln -sf /usr/bin/python3 /usr/bin/python

# ---------------------------------------------------------------------------
# repo tool. Pinned to a recent stable hash; we re-fetch on every build via
# 'repo selfupdate' from inside init.sh, but bake a known-good version so a
# cold build can succeed without depending on git-repo's CDN at boot time.
# ---------------------------------------------------------------------------
RUN install -d /usr/local/bin && \
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo && \
    chmod +x /usr/local/bin/repo

# ---------------------------------------------------------------------------
# A non-root build user keeps host UID/GID alignment trivial when bind-mounting
# /srv/src from the Vast.ai instance's NVMe. UID/GID are arg-overridable.
# ---------------------------------------------------------------------------
ARG BUILD_UID=1000
ARG BUILD_GID=1000
RUN groupadd -g "${BUILD_GID}" build \
    && useradd -m -u "${BUILD_UID}" -g build -s /bin/bash build \
    && echo "build ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/build

# ---------------------------------------------------------------------------
# Volume contract (matches docker-lineage-cicd's layout for muscle memory).
# All large directories live OUTSIDE the image so the container stays small
# and ccache/source survive container recreation.
# ---------------------------------------------------------------------------
ENV SRC_DIR=/srv/src \
    CCACHE_DIR=/srv/ccache \
    OUT_DIR=/srv/out \
    KEYS_DIR=/srv/keys \
    LOGS_DIR=/srv/logs \
    LMANIFEST_DIR=/srv/local_manifests \
    DEVICETREE_DIR=/srv/devicetree \
    CACERTS_DIR=/srv/cacerts

RUN install -d -o build -g build \
        "$SRC_DIR" "$CCACHE_DIR" "$OUT_DIR" "$KEYS_DIR" "$LOGS_DIR" \
        "$LMANIFEST_DIR" "$DEVICETREE_DIR" "$CACERTS_DIR"

VOLUME ["/srv/src", "/srv/ccache", "/srv/out", "/srv/keys", "/srv/logs", \
        "/srv/local_manifests", "/srv/devicetree", "/srv/cacerts"]

# ---------------------------------------------------------------------------
# Pipeline scripts. init.sh is the entrypoint; hooks/ are sourced at the
# documented phases (see pipeline/hooks/README.md).
# ---------------------------------------------------------------------------
COPY --chown=build:build pipeline/ /opt/pipeline/
RUN chmod +x /opt/pipeline/init.sh /opt/pipeline/hooks/*.sh /opt/pipeline/lib.sh

USER build
WORKDIR /srv/src

# Default ccache size; override at run time with -e CCACHE_MAX_SIZE=100G.
ENV CCACHE_MAX_SIZE=50G \
    AOSP_BRANCH=android-16.0.0_r4 \
    AOSP_MANIFEST_URL=https://android.googlesource.com/platform/manifest \
    LUNCH_TARGET=customos_cf_x86_64_phone-userdebug \
    PARALLEL_JOBS=

ENTRYPOINT ["/opt/pipeline/init.sh"]
