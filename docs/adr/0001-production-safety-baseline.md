# ADR 0001: Production Safety Baseline

## Status
Accepted

## Context
The project needed stronger defaults before wider adoption: no hardcoded infra values, stronger validation, and clearer runtime security boundaries.

## Decision
- Remove hardcoded mirror endpoints and force no mirror override by default.
- Restrict backend disk operations to validated `lsblk` disk devices.
- Disable wildcard CORS; allow explicit opt-in origin.
- Add optional API token for mutating endpoints.
- Require explicit UI confirmation before destructive install.

## Consequences
- Better safety and trust for first-time users.
- Slightly more setup required for cross-origin/remote API workflows.
- Cleaner foundation for release and compliance hardening.
