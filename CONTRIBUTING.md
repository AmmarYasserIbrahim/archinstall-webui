# Contributing

## Workflow

1. Open an issue first for significant changes.
2. Fork and create a focused branch.
3. Keep changes small and scoped.
4. Run local checks before PR:

```bash
python3 -m compileall server.py
python3 -m unittest discover -s tests
shellcheck install.sh
```

5. Submit PR using template and include risk notes for disk/installer changes.

## Standards

- Default to safe behavior.
- Any destructive operation must have both UI and backend safeguards.
- Keep compatibility with official `archinstall` config semantics.
- Document user-facing behavior changes in `CHANGELOG.md`.
