# syntax=docker/dockerfile:1

# Self-contained build: downloads the installer, extracts the embedded OCI
# image with binwalk, flattens its layers into a rootfs, and layers the
# entrypoint on top.  No pre-built base image required.

# ---------------------------------------------------------------------------
# Stage 1 – extract the UniFi OS Server rootfs from the installer binary
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS extractor

ARG TARGETARCH
ARG INSTALLER_URL_AMD64="https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64"
ARG INSTALLER_URL_ARM64="https://fw-download.ubnt.com/data/unifi-os-server/df5b-linux-arm64-5.0.6-f35e944c-f4b6-4190-93a8-be61b96c58f4.6-arm64"

RUN apt-get update && apt-get install -y --no-install-recommends \
        binwalk jq p7zip-full curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

RUN if [ "$TARGETARCH" = "arm64" ]; then \
      URL="$INSTALLER_URL_ARM64"; \
    else \
      URL="$INSTALLER_URL_AMD64"; \
    fi && \
    [ -n "$URL" ] || { echo "No installer URL for $TARGETARCH"; exit 1; } && \
    curl -fL --retry 5 --retry-delay 2 -o installer.bin "$URL"

RUN binwalk --run-as=root -e installer.bin

RUN /bin/bash <<'EXTRACT'
set -eo pipefail

IMAGE_TAR=$(find /build -type f -name 'image.tar' -print -quit)
[ -n "$IMAGE_TAR" ] || { echo "image.tar not found after extraction"; exit 1; }

mkdir oci
tar xf "$IMAGE_TAR" -C oci/

MANIFEST=$(jq -r '.manifests[0].digest' oci/index.json | cut -d: -f2)

mkdir /rootfs
jq -r '.layers[].digest' "oci/blobs/sha256/$MANIFEST" | cut -d: -f2 | \
while read -r layer; do
    echo "Extracting layer $layer"
    tar xf "oci/blobs/sha256/$layer" -C /rootfs

    # OCI whiteout markers
    find /rootfs -name '.wh.*' 2>/dev/null | while read -r wh; do
        base=$(basename "$wh"); dir=$(dirname "$wh")
        if [ "$base" = ".wh..wh..opq" ]; then
            find "$dir" -mindepth 1 -maxdepth 1 ! -name '.wh..wh..opq' -exec rm -rf {} +
        else
            rm -rf "$dir/${base#.wh.}"
        fi
        rm -f "$wh"
    done
done
EXTRACT

COPY uos-entrypoint.sh /rootfs/root/uos-entrypoint.sh
COPY site-localhost-bypass.conf /rootfs/root/site-localhost-bypass.conf
RUN chmod +x /rootfs/root/uos-entrypoint.sh

# ---------------------------------------------------------------------------
# Stage 2 – final image from the extracted rootfs
# ---------------------------------------------------------------------------
FROM scratch

COPY --from=extractor /rootfs /

ARG UOS_SERVER_VERSION="5.0.6"

ENV UOS_SERVER_VERSION="${UOS_SERVER_VERSION}" \
    APP_VERSION="${UOS_SERVER_VERSION}" \
    APP_MODEL="UOSSERVER" \
    PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/root/uos-entrypoint.sh"]
