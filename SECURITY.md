# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 5.0.x   | :white_check_mark: |
| < 5.0   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public issue**
2. Email security concerns to: security@unihosted.com (or create a private security advisory on GitHub)
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will:
- Acknowledge receipt within 48 hours
- Provide a timeline for a fix
- Credit you in the security advisory (if desired)

## Security Best Practices

When deploying this container:

1. **Use strong passwords** for MongoDB and PostgreSQL
2. **Restrict network access** - Don't expose ports unnecessarily
3. **Keep images updated** - Pull latest tags regularly
4. **Use reverse proxy** - Put behind nginx/traefik with SSL
5. **Monitor logs** - Watch for unusual activity
6. **Run with least privilege** - Use Docker user namespaces where possible

## Security Features

This project includes:
- Health checks for container monitoring
- Localhost-only access for sensitive services (PostgreSQL, API bypass)
- Support for TLS connections to MongoDB
- Regular base image updates

## Disclosure Policy

We follow responsible disclosure:
- 90-day window for fixes before public disclosure
- Coordinated disclosure with reporters
- CVE assignments when appropriate
