# UniFi OS Server Docker

Docker images for running UniFi OS Server with support for multiple versions.

## Versioning Structure

This repository supports building Docker images for multiple UniFi OS Server versions. Each version can have its own custom Dockerfile, entrypoint script, and configuration files.

### Directory Structure

```
versions/
├── 5.0.6/
│   ├── Dockerfile          # Version-specific Dockerfile
│   ├── uos-entrypoint.sh   # Version-specific entrypoint
│   └── site-localhost-bypass.conf  # Version-specific nginx config
└── (add new versions here)

# Root level files serve as templates/defaults
Dockerfile                  # Template Dockerfile
uos-entrypoint.sh          # Template entrypoint script
site-localhost-bypass.conf # Template nginx config
```

### Adding a New Version

To add support for a new UniFi OS version (e.g., 5.0.7):

1. Create the version directory:
   ```bash
   mkdir -p versions/5.0.7
   ```

2. Copy and customize the files from an existing version or the templates:
   ```bash
   cp versions/5.0.6/Dockerfile versions/5.0.7/
   cp versions/5.0.6/uos-entrypoint.sh versions/5.0.7/
   cp versions/5.0.6/site-localhost-bypass.conf versions/5.0.7/
   ```

3. Modify the files as needed for the new version.

4. Update the workflow default URL mapping in `.github/workflows/extract-image.yml`:
   ```yaml
   declare -A VERSION_URLS=(
     ["5.0.6"]="https://fw-download.ubnt.com/data/unifi-os-server/..."
     ["5.0.7"]="https://fw-download.ubnt.com/data/unifi-os-server/..."  # Add this
   )
   ```

5. Commit and push. The workflow will automatically build the new version.

## Building Images

### Automatic Builds

Images are built automatically on:
- Push to `main` branch (affects changed versions only)
- Push of version tags (`v5.0.6`, `v5.0.7`, etc.)
- Manual workflow dispatch via GitHub Actions

### Manual Build

To manually trigger a build for a specific version:

1. Go to **Actions** → **Extract UniFi OS Server base image and build Docker image**
2. Click **Run workflow**
3. Enter the parameters:
   - `uos_server_version`: The version to build (e.g., `5.0.6`)
   - `installer_url`: Direct download URL for that version's installer
   - Other parameters as needed

## Image Tags

Images are published to GitHub Container Registry (GHCR):

```
ghcr.io/unihosted/unifi-os-server-docker:{VERSION}
ghcr.io/unihosted/unifi-os-server-docker:latest
```

Example:
- `ghcr.io/unihosted/unifi-os-server-docker:5.0.6`
- `ghcr.io/unihosted/unifi-os-server-docker:latest` (always points to the latest build)

## Using Docker Compose

Each version directory contains a `docker-compose.yaml` specific to that version:

```bash
cd versions/5.0.6
docker-compose up -d
```

Or use a specific version tag:

```yaml
services:
  unifi-os-server:
    image: ghcr.io/unihosted/unifi-os-server-docker:5.0.6
    # ... rest of config
```
