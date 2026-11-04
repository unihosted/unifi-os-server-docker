# syntax=docker/dockerfile:1

# Self-contained build: downloads the installer, extracts the embedded OCI
# image with binwalk, flattens its layers into a rootfs, and layers the
# entrypoint on top.  No pre-built base image required.

# ---------------------------------------------------------------------------
# Stage 1 – extract the UniFi OS Server rootfs from the installer binary
# ---------------------------------------------------------------------------
FROM ubuntu:22.04 AS extractor

ARG TARGETARCH
ARG INSTALLER_URL_AMD64="https://fw-download.ubnt.com/data/unifi-os-server/5172-linux-x64-5.1.42-12e9e3cf-8f8b-4e54-928c-76b80a10c8a4.42-x64"
ARG INSTALLER_URL_ARM64="https://fw-download.ubnt.com/data/unifi-os-server/f730-linux-arm64-5.1.42-d2bca8bd-d6fc-4d20-99e5-b78235843c2f.42-arm64"

RUN apt-get update && apt-get install -y --no-install-recommends \
        binwalk jq p7zip-full curl ca-certificates xz-utils \
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

# Temporary Node2Shell (CVE-2026-111497) fix until Ubiquiti updates node24.
# Replace the executable used by systemd, preserving Node 24's native addon ABI.
# SHA-256 values are pinned from https://nodejs.org/dist/v24.22.1/SHASUMS256.txt.
RUN /bin/bash <<'PATCH_NODE'
set -euo pipefail

VERSION=24.22.1
case "$TARGETARCH" in
    amd64)
        NODE_ARCH=x64
        SHA256=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
        ;;
    arm64)
        NODE_ARCH=arm64
        SHA256=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e
        ;;
    *) echo "Unsupported Node.js architecture: $TARGETARCH" >&2; exit 1 ;;
esac

# Older UOS releases (including 4.3.6) use node22. Install node24 for the
# log forwarder without replacing those application runtimes. If node24 is
# already bundled, retain the patch's runtime layout and ABI checks.
test ! -L /rootfs/usr/bin/node24
OLD_ABI=""
if [ -e /rootfs/usr/bin/node24 ]; then
    test -f /rootfs/usr/bin/node24
    OLD_VERSION=$(chroot /rootfs /usr/bin/node24 -p 'process.versions.node')
    test "${OLD_VERSION%%.*}" = 24
    OLD_ABI=$(chroot /rootfs /usr/bin/node24 -p 'process.versions.modules')
fi

ARCHIVE="node-v${VERSION}-linux-${NODE_ARCH}.tar.xz"
curl -fL --retry 5 --retry-delay 2 -o "$ARCHIVE" "https://nodejs.org/dist/v${VERSION}/${ARCHIVE}"
echo "$SHA256  $ARCHIVE" | sha256sum -c -
mkdir -p /build/node-patch
tar -xJf "$ARCHIVE" -C /build/node-patch --strip-components=1 \
    "node-v${VERSION}-linux-${NODE_ARCH}/bin/node" \
    "node-v${VERSION}-linux-${NODE_ARCH}/LICENSE"
install -m 0755 /build/node-patch/bin/node /rootfs/usr/bin/node24
install -Dm 0644 /build/node-patch/LICENSE /rootfs/usr/share/doc/node24/LICENSE

test "$(chroot /rootfs /usr/bin/node24 --version)" = "v${VERSION}"
if [ -n "$OLD_ABI" ]; then
    test "$(chroot /rootfs /usr/bin/node24 -p 'process.versions.modules')" = "$OLD_ABI"
fi
chroot /rootfs /usr/bin/node24 --openssl-legacy-provider -e '
    const assert = require("node:assert/strict");
    const zlib = require("node:zlib");
    const input = Buffer.from("UniFi Node.js runtime smoke test");
    assert.deepEqual(zlib.brotliDecompressSync(zlib.brotliCompressSync(input)), input);
'
rm -rf /build/node-patch "$ARCHIVE"
PATCH_NODE

COPY uos-entrypoint.sh /rootfs/root/uos-entrypoint.sh
COPY uos-logs.cjs /rootfs/root/uos-logs.cjs
RUN chmod +x /rootfs/root/uos-entrypoint.sh

# ---------------------------------------------------------------------------
# Stage 2 – final image from the extracted rootfs
# ---------------------------------------------------------------------------
FROM scratch

COPY --from=extractor /rootfs /

ARG UOS_SERVER_VERSION="5.1.42"

ENV UOS_SERVER_VERSION="${UOS_SERVER_VERSION}" \
    APP_VERSION="${UOS_SERVER_VERSION}" \
    APP_MODEL="UOSSERVER" \
    PRODUCT_NAME="UniFi OS Server"

STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/root/uos-entrypoint.sh"]
