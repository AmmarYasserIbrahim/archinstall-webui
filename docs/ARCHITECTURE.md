# Architecture

## Components

- `install.sh`: session bootstrapper; installs deps, fetches assets, starts server, configures access URL.
- `server.py`: local HTTP API and install orchestrator; validates payload, executes `archinstall`, streams progress.
- `index.html`: client UI; gathers config, validates user input, submits payload, renders progress/logs.

## Data flow

1. UI fetches `/api/status` telemetry.
2. User builds configuration in UI.
3. UI submits config/creds to `/api/submit`.
4. Server validates payload and writes `/tmp/config.json` and `/tmp/creds.json`.
5. Server runs `archinstall` and updates `/tmp/archinstall-state.txt`.
6. UI and terminal consume live progress.

## Safety boundaries

- Backend is source of truth for validation.
- Only real block devices from `lsblk` are accepted.
- Mutating APIs can be protected with `ARCHWEBUI_API_TOKEN`.
- CORS is disabled unless explicitly configured.
