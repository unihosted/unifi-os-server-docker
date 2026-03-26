# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial public release preparation
- Comprehensive README with usage instructions
- MIT License
- `.env.example` configuration template
- CHANGELOG for version tracking
- GitHub issue templates

## [5.0.6] - 2024-XX-XX

### Added
- Initial Docker containerization of UniFi OS Server 5.0.6
- Localhost bypass on port 7443 for direct API access
- PostgreSQL exposed on port 5432 for external access
- Synology NAS hardware detection and patches
- External MongoDB support with configurable connection parameters
- GitHub Actions CI/CD workflow for automated builds
- Unit tests for property setting functions (`test_set_property.sh`)

### Features
- Base image extraction from official Ubiquiti installer
- Systemd init system support
- Nginx localhost bypass configuration
- MongoDB URI construction with TLS and auth source support
- Automatic UUID generation (v5 spoofing)

[Unreleased]: https://github.com/unihosted/unifi-os-server-docker/compare/v5.0.6...HEAD
[5.0.6]: https://github.com/unihosted/unifi-os-server-docker/releases/tag/v5.0.6
