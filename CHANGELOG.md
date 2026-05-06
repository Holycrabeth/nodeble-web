# Changelog

All notable changes to the `nodeble-web` repo (Cloudflare-Pages-fronted at https://nodeble.app).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- `bootstrap.sh` — Path C Phase B.1 installer for `nodeble-api-server` on fresh Ubuntu 22.04+ / 24.04+ VPS. Replaces 24-line placeholder. CTO 2026-05-05 design (`cto/reviews/2026-05-05-bootstrap-sh-design.md`) ratified. Steps: idempotency-probe → sudo-probe → os-check → disk-space-check → python-install → enable-linger → clone-repo → venv-create → pip-install → generate-api-token → generate-tls-cert → write-api-yaml → systemd-install → systemd-start. CLI `--verbose` / `--dry-run`. Env `NODEBLE_HOSTNAME` / `NODEBLE_API_PORT`.
- PAT-aware private-repo clone via `GITHUB_TOKEN` env var (CEO 2026-05-06 ratified Option 2 — `cto/reviews/2026-05-06-bootstrap-pat-aware-clone-dispatch.md`). Mac app injects via SSH env; bootstrap unsets after final clone.
- `tests/integration/test_bootstrap.sh` — acceptance test matrix (Ubuntu 22.04 + Ubuntu 24.04 happy-path × 3 sub-tests + 6 failure-mode tests).

### Removed
- **Debian 12 from supported OS list** (CEO 2026-05-06 ratified Option 1). Bookworm + bookworm-backports lack `python3.12` (only `python3.11` + `python3.13` available). `bootstrap.sh` rejects Debian with `STATUS: failure: unsupported_os: debian (Ubuntu 22.04+ only; Debian lacks python3.12 in main+backports)`. Close-circle deployment topology (Tower / 茗茗 / YB) is Ubuntu-only — zero loss.
