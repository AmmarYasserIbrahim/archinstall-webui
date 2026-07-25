# Compatibility Policy

## Archinstall compatibility

- Target integration: official `archinstall` config/creds interfaces.
- Policy: maintain compatibility with currently shipped `archinstall` in latest Arch ISO and one previous known-good variant when feasible.
- Breaking behavior changes must be documented in `CHANGELOG.md`.

## Backward compatibility guarantees

- Minor releases: no intentional breaking API/UI payload changes.
- Major releases: may change payload generation rules with migration notes.

## Known-good baseline

- Baseline validated on Arch ISO sessions with Python 3 and `archinstall` available in path.
