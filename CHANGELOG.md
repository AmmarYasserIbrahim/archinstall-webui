# Changelog

All notable changes are tracked here.

## [0.1.0] - 2026-07-25

### Added
- Server-side payload validation for device paths, username, and hostname.
- Restrictive-by-default CORS with optional explicit allowed origin.
- Optional API token gate for mutating endpoints.
- UI destructive-action confirmation checkbox before install submit.
- Safe/Advanced mode selection in deployment step.
- Project governance and support documents.
- CI workflow and unit tests for validation functions.

### Changed
- Removed hardcoded mirror/IP defaults from installer and frontend payload.
- Installer networking now defaults to LAN with optional tunnel modes.
- API submit flow now returns explicit validation errors to the UI.
