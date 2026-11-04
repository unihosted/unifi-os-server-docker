# Building and maintaining the image

[Back to the README](../README.md)

These notes are for contributors and maintainers. To run the published image,
follow the README's Quick Start.

## Build pipeline

The [Dockerfile](../Dockerfile) downloads the official Ubiquiti installer,
extracts its embedded OCI image, and packages the filesystem for Docker. The
entrypoint configures MongoDB, networking, and PostgreSQL before starting systemd.
The [build-image workflow](../.github/workflows/build-image.yml) automates image
builds and publishing.

## Supported versions

Every version uses the same Dockerfile, entrypoint, and log forwarder. The
`build-image` workflow defaults to `uos_server_version: all`, rebuilding 4.3.6,
5.0.6, 5.1.15, 5.1.19, 5.1.21, 5.1.37, 5.1.40, and 5.1.42 from the selected Git
ref. All have amd64 and arm64 builds except 4.3.6, which has only amd64.
Older releases that only bundle Node 22 receive Node 24 for the forwarder; their
application runtime stays unchanged.

Set `push` to `false` for a build without publishing. When publishing all versions,
each version gets its own image tag and `latest` points to the newest selected
version (currently 5.1.42). You can also select one version or build a release tag;
custom installer URLs require a single explicit version.

## Node.js security patch

For releases that bundle Node 24, the image replaces `/usr/bin/node24` with the
official Node.js **24.22.1** binary on amd64 and arm64 to address
[Node2Shell (CVE-2026-111497)](https://nodejs.org/en/blog/release/v24.22.1/).
Downloads are checked against pinned SHA-256 hashes. The build verifies the
version, preserves the existing Node 24 native addon ABI, and checks Brotli
compression/decompression inside the extracted rootfs. Releases that bundle
Node 22 receive Node 24 for the log forwarder while retaining their application
runtime.

This is a temporary runtime override until Ubiquiti ships a fixed package. The Debian `node24` package metadata still reports Ubiquiti's original version; check the running binary with `docker exec unifi-os-server /usr/bin/node24 --version`. An in-container package update can overwrite the patched binary, so deploy rebuilt images to retain the fix. When updating the patch, change the version and both architecture hashes together in `Dockerfile`.
