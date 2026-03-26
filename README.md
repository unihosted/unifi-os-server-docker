# UniFi OS Server Docker

Docker images for running UniFi OS Server with support for multiple versions.

## How It Works

This repository uses **git tags** to manage different UniFi OS Server versions. Each tag corresponds to a specific version build:

- Push tag `v4.3.6` → builds image `ghcr.io/unihosted/unifi-os-server-docker:4.3.6`
- Push tag `v5.0.6` → builds image `ghcr.io/unihosted/unifi-os-server-docker:5.0.6`

## Building Images

### Via Git Tag (Recommended)

1. Make sure your `Dockerfile`, `uos-entrypoint.sh`, and other files are configured for the version you want to build
2. Update the installer URL in the workflow (`.github/workflows/extract-image.yml`) if needed
3. Create and push a version tag:
   ```bash
   git tag v5.0.6
   git push origin v5.0.6
   ```

The GitHub Actions workflow will automatically:
- Extract the version from the tag (e.g., `v5.0.6` → `5.0.6`)
- Download the UniFi OS Server installer
- Extract the base image
- Build and push to GHCR

### Via Manual Workflow Dispatch

1. Go to **Actions** → **Extract UniFi OS Server base image and build Docker image**
2. Click **Run workflow**
3. Enter the parameters:
   - `uos_server_version`: The version to build (e.g., `5.0.6`)
   - `installer_url`: Direct download URL for that version's installer
   - Other parameters as needed

## Adding a New Version

To add support for a new UniFi OS version (e.g., 6.0.0):

1. Update the installer URL mapping in `.github/workflows/extract-image.yml`:
   ```yaml
   declare -A VERSION_URLS=(
     ["4.3.6"]="https://fw-download.ubnt.com/data/unifi-os-server/..."
     ["5.0.6"]="https://fw-download.ubnt.com/data/unifi-os-server/..."
     ["6.0.0"]="https://fw-download.ubnt.com/data/unifi-os-server/..."  # Add this
   )
   ```

2. Modify `Dockerfile`, `uos-entrypoint.sh`, or other files if the new version requires changes

3. Commit and push:
   ```bash
   git add .
   git commit -m "Add support for UniFi OS 6.0.0"
   git push
   ```

4. Create and push the version tag:
   ```bash
   git tag v6.0.0
   git push origin v6.0.0
   ```

## Rebuilding an Existing Version

To rebuild an existing version (e.g., after fixing the entrypoint or config files):

```bash
# Delete the old tag locally and remotely, then recreate it on the current commit
git tag -d v5.0.6
git push origin :refs/tags/v5.0.6
git tag v5.0.6
git push origin v5.0.6
```

This re-triggers the workflow, which will rebuild and push the image using the updated files from `main`.

## Image Tags

Images are published to GitHub Container Registry (GHCR):

```
ghcr.io/unihosted/unifi-os-server-docker:{VERSION}
ghcr.io/unihosted/unifi-os-server-docker:latest
```

Example:
- `ghcr.io/unihosted/unifi-os-server-docker:5.0.6`
- `ghcr.io/unihosted/unifi-os-server-docker:latest` (always points to the most recent build)

## Using Docker Compose

Use the included `docker-compose.yaml`:

```bash
docker-compose up -d
```

Or specify a specific version:

```yaml
services:
  unifi-os-server:
    image: ghcr.io/unihosted/unifi-os-server-docker:5.0.6
    platform: linux/amd64
    privileged: true
    cgroup: host
    restart: unless-stopped
    pull_policy: always
    # ... see docker-compose.yaml for full config
```

## File Structure

```
.
├── Dockerfile                    # Main Dockerfile (handles all versions via build args)
├── uos-entrypoint.sh            # Container entrypoint script
├── site-localhost-bypass.conf   # Nginx config for localhost bypass
├── docker-compose.yaml          # Docker Compose configuration
├── .github/workflows/
│   └── extract-image.yml        # GitHub Actions workflow
└── README.md                    # This file
```

## Version-Specific Changes

If a UniFi OS version requires a different Dockerfile or entrypoint:

1. Create a new branch for that version: `git checkout -b v5.0.7`
2. Make the necessary changes to `Dockerfile`, `uos-entrypoint.sh`, etc.
3. Commit and tag from that branch
4. The version-specific files are preserved in that tag forever

This way, each git tag captures the exact state of files needed for that version.
