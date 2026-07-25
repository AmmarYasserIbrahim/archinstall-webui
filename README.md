# Archinstall WebUI

Safe remote UI wrapper for the official Arch Linux `archinstall` flow.

## Project Scope

This project provides a browser-based configuration UI and a lightweight local API that generates and executes `archinstall` configuration on an Arch ISO environment.

- In scope: guided config, disk layout modeling, telemetry display, execution orchestration, progress streaming.
- Out of scope: replacing `archinstall`, persistent cloud service, unattended fleet provisioning, non-Arch installers.

## Supported Environments

- Arch Linux live ISO environments.
- Boot modes: UEFI and BIOS (with bootloader validation in UI).
- Networking:
  - Default: LAN URL (`http://<local-ip>:5000`).
  - Optional tunnel mode via `localhost.run` when enabled.
- Hardware assumptions:
  - Target block device visible via `lsblk` as type `disk`.
  - Destructive install flow (selected disk will be wiped).

See `/home/runner/work/archinstall-webui/archinstall-webui/docs/COMPATIBILITY.md` for compatibility policy.

## Secure Quick Start (Release Artifact + Checksum)

1. Download versioned release assets from GitHub Releases (example uses `v0.1.0`):

```bash
VERSION="v0.1.0"
curl -fLO "https://github.com/AmmarYasserIbrahim/archinstall-webui/releases/download/${VERSION}/install.sh"
curl -fLO "https://github.com/AmmarYasserIbrahim/archinstall-webui/releases/download/${VERSION}/checksums.txt"
sha256sum -c checksums.txt --ignore-missing
chmod +x install.sh
sudo ./install.sh
```

2. Optional runtime env flags:

```bash
ARCHWEBUI_TUNNEL_MODE=none ./install.sh
ARCHWEBUI_TUNNEL_MODE=localhostrun ./install.sh
ARCHWEBUI_CORS_ORIGIN="https://your-origin.example" ARCHWEBUI_API_TOKEN="strong-token" ./install.sh
```

## Security Model

- Threat model:
  - Local/LAN attacker trying to submit malicious install payloads.
  - User mistakes that can wipe unintended disks.
- Controls:
  - Device path and payload validation server-side.
  - Disk targets restricted to actual `lsblk` disk devices.
  - No wildcard CORS by default; opt-in specific origin only.
  - Optional API token requirement for mutating endpoints.
  - Explicit UI acknowledgment before destructive install submission.
- Data handling:
  - Runtime config and credentials stored in `/tmp/config.json` and `/tmp/creds.json`.
  - Logs stored in `/tmp/archinstall-webui.log`.
  - Files are ephemeral for the live session; users should reboot and clear session media post-install.

See `/home/runner/work/archinstall-webui/archinstall-webui/SECURITY.md` for disclosure policy.

## Operations and Recovery

- If tunnel setup fails, installer falls back to LAN mode automatically.
- If API submission fails, UI presents server-side validation error and allows retry.
- If install fails, check `/tmp/archinstall-webui.log` and state output `/tmp/archinstall-state.txt`.

## Open Source Standards

- Contributing guide: `/home/runner/work/archinstall-webui/archinstall-webui/CONTRIBUTING.md`
- Code of conduct: `/home/runner/work/archinstall-webui/archinstall-webui/CODE_OF_CONDUCT.md`
- Support policy: `/home/runner/work/archinstall-webui/archinstall-webui/SUPPORT.md`
- Roadmap: `/home/runner/work/archinstall-webui/archinstall-webui/ROADMAP.md`
- Changelog: `/home/runner/work/archinstall-webui/archinstall-webui/CHANGELOG.md`
- Architecture: `/home/runner/work/archinstall-webui/archinstall-webui/docs/ARCHITECTURE.md`
- ADRs: `/home/runner/work/archinstall-webui/archinstall-webui/docs/adr/`

## License

MIT.
