# Security Policy

## Supported Versions

Flote is in beta. Only the `main` branch is supported today; an LTS policy will be
defined after the first stable release.

| Version | Supported |
|---------|-----------|
| main    | ✅        |
| < 1.0   | ⚠️ best-effort only |

## Reporting a Vulnerability

If you find a security vulnerability, **do not report it in a public issue**. Use
one of the private channels below.

### Option 1: GitHub Private Vulnerability Reporting (preferred)

1. Open this repository's [Security tab](https://github.com/tomarai85/flote/security)
2. Click "Report a vulnerability"
3. Include steps to reproduce, the blast radius, and a suggested fix if you have one

This keeps everything private until a fix is live.

### Option 2: Without a GitHub account

Reach the maintainer through the website: https://flote-app.vercel.app

### What to expect

- **First acknowledgement**: within 5 business days
- **Initial assessment**: within 14 days (severity plus a fix plan)
- **Fix and advisory**: within 90 days for high severity, per responsible disclosure
- **Credit**: named in the advisory and release notes, if you want to be

## Out of scope

- macOS Gatekeeper and notarization warnings -- known, and documented in the
  [website FAQ](https://flote-app.vercel.app#download)
- Vulnerabilities in Ollama itself when used for AI Organize -- report those to the
  Ollama project
- The website (served by Vercel) is not the primary source, but serious reports are
  still welcome

## Security features in place

- **GitHub secret scanning**: enabled, on push and across history
- **GitHub Push Protection**: enabled, blocks pushes containing secrets
- **Dependabot security updates**: enabled
- **`.env*`, `*.key`, `*.pem`, `DevSecrets.swift`**: structurally excluded via `.gitignore`
- **Source-available licence**: you can audit what the app does with your notes

## Why source-available?

- Insurance against a solo developer disappearing: the fork keeps working
- You can verify in code that your notes are not being read or shipped anywhere
- You keep the right to patch and fix it yourself

See the Why Open section of [README.md](./README.md) for the longer version.
