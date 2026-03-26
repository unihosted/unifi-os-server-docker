# Contributing to UniFi OS Server Docker

Thank you for your interest in contributing! This document provides guidelines for contributing to the project.

## Development Setup

1. Fork the repository
2. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/unifi-os-server-docker.git
   cd unifi-os-server-docker
   ```
3. Create a branch for your changes:
   ```bash
   git checkout -b feature/your-feature-name
   ```

## Making Changes

### Code Style

- Use consistent indentation (2 spaces for YAML, 4 for shell scripts)
- Add comments for non-obvious logic
- Follow existing patterns in the codebase

### Testing

Test your changes locally:

```bash
# Build the image
docker compose build

# Run the stack
docker compose up -d

# Check logs
docker compose logs -f

# Run unit tests
./test_set_property.sh
```

### Commit Messages

Use clear, descriptive commit messages:

- `feat: add new feature`
- `fix: resolve bug in entrypoint`
- `docs: update README`
- `refactor: improve code structure`
- `test: add unit tests`

## Submitting Changes

1. Push your branch to your fork
2. Create a Pull Request against the `main` branch
3. Fill out the PR template with:
   - Description of changes
   - Testing performed
   - Any breaking changes

## Release Process

Releases are automated via GitHub Actions when tags are pushed:

```bash
# Create a new version tag
git tag -a v5.0.7 -m "Release version 5.0.7"
git push origin v5.0.7
```

The workflow will:
1. Build the Docker image
2. Push to GHCR with semantic tags (`5.0.7`, `5.0`, `5`, `latest`)
3. Create a GitHub Release with auto-generated notes

## Reporting Issues

When reporting bugs, please include:
- Docker version
- Host OS and architecture
- Image tag used
- Steps to reproduce
- Relevant log output

## Questions?

Join our [Discussions](https://github.com/unihosted/unifi-os-server-docker/discussions) for questions and ideas.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
