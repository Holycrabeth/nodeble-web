# Changelog

All notable changes to the `nodeble-web` repo (Cloudflare-Pages-fronted at https://nodeble.app).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added (Phase 3 — chain Docker matrix; Path C 4-tier coverage closeout)
- **`tests/integration/test_bootstrap_chain.sh`** extended (412 → 866 LoC) per CTO 2026-05-10 spec (`cto/reviews/2026-05-10-bootstrap-chain-phase-3-docker-matrix-spec.md`). 14 new tests across 4 sections (failure-mode + failure isolation + idempotency-recovery + bundle validation).
- **`tests/integration/fixtures/`** (NEW directory; 7 JSON fixtures): `bundle-multi-module.json` / `bundle-single-bot.json` / `bundle-malformed-json.json` / `bundle-missing-module-field.json` / `bundle-wrong-config-version.json` / `bundle-orch-missing-required.json` / `bundle-failing-orch.json`. Replaces inline heredoc bundle generation; reusable + intentional-schema-violation fixtures.
- **Section 3 — Failure-mode** (4 tests): `test_chain_unsupported_os` (rocky-9 + debian-12 consolidated) / `test_chain_requires_sudo` / `test_chain_network_none` / `test_chain_missing_github_token`.
- **Section 4 — Failure isolation** (3 tests; verifies B.2 §7 contract empirically): `test_chain_orch_clone_failed_isolates_api_server` / `test_chain_orch_install_failed_isolates_api_server` / `test_chain_allocator_install_failed_isolates_prior`. Each verifies (a) earlier sub-deploy stays installed (no rollback), (b) downstream sub-deploys NOT reached, (c) systemd service still active.
- **Section 5 — Idempotency + partial-state recovery** (3 tests): `test_chain_aggregate_already_installed_multi_module` (strict per-step assertions) / `test_chain_partial_state_resumes_from_orch` (api-server-only state → orch + allocator install) / `test_chain_partial_state_resumes_from_allocator` (api-server + orch state → allocator only installs).
- **Section 6 — Bundle JSON validation** (3 tests): `test_chain_bundle_missing_top_level_module_field` / `test_chain_bundle_wrong_config_version` / `test_chain_bundle_orch_missing_required`. Each asserts exit 3 + `STATUS: failure: bundle_invalid: <field-pattern>`.
- **Section 2 — Multi-distro extension** (1 test): `test_chain_single_bot[ubuntu-24]` (B.2 covered ubuntu-22 only).
- **L1 §4 dual-deployment-mode enforcement verified empirically**: `test_chain_single_bot` confirms orch + allocator clone steps NOT attempted in single-bot mode; `test_chain_multi_module` confirms all 3 sub-deploys invoked in multi-module mode.

### Test results 5/10 SGT
- **23 PASS / 0 FAIL / 0 SKIP** (full chain matrix). Single-session ship clean. 0 production bugs surfaced (matches IC mirror pattern per spec §8 expectation; B.2's 5-iter chain logic exhaust pre-empted Phase 3 surface).

### Refactored
- `write_bundle_multi_module` + `write_bundle_single_bot` reduced to one-line wrappers around new `copy_fixture` helper (replaces inline heredoc generation).

### Added (Phase B.2 — chain orchestration)
- **`bootstrap.sh` chain mode** for installing api-server + orchestrator + allocator in one invocation. CTO 2026-05-09 spec (`cto/reviews/2026-05-09-bootstrap-sh-phase-b2-chain-spec.md`) ratified. CEO 2026-05-09 Option A (orch existing CLI-flag contract; orch Phase 2 upgrade tracked P3 backlog).
- New flags: `--mode <multi-module|single-bot>` (REQUIRED — L1 §4 dual-deployment-mode enforcement) + `--config <bundle.json>` (REQUIRED unless `--dry-run`) + `--skip-tiger-test` + `--tiger-properties <path>`.
- New STEPs: `apt-prereqs` (git/jq/bc/cron/curl/ca-certificates) → `bundle-validate` → `orch-install` → `allocator-install`.
- New STATUS contract: `STATUS: already_installed` aggregate when all sub-deploys (api-server + orch + allocator) report already_installed.
- New RESULT lines: `RESULT_MODE` (multi-module|single-bot) + `RESULT_MODULES_INSTALLED` (csv: api-server,orchestrator,allocator OR api-server).
- `tests/integration/test_bootstrap_chain.sh` — 9-test matrix (4 failure-mode + 2 multi-module happy-path × ubuntu-22+24 + 2 idempotent rerun + 1 single-bot).

### Changed (Phase B.2 — production bug fixes caught via matrix-driven discovery)
- `step_python_install` now always runs `apt-get install python3.12 python3.12-venv python3.12-dev` (idempotent for already-installed). Previous early-return-on-binary-detected meant Ubuntu 24's separately-packaged `python3.12-venv` was never installed → `venv-create` failed with `ensurepip not available`.
- `step_python_install` Ubuntu 22.04: ensure `python3` resolves to `python3.12` via `/usr/local/bin/python3` symlink. Allocator deploy.sh and other modules use bare `python3` (not `python3.12` directly) — Ubuntu 22 default `python3=3.10` would fail allocator's `prereq-check-python`.
- `step_enable_linger` exports `XDG_RUNTIME_DIR=/run/user/$(id -u)` after linger creates the dir. PAM normally sets this in interactive sessions; non-interactive `docker exec` and `ssh user@host bash command` (Mac app SSH context) do not, causing `systemctl_daemon_reload_failed`.
- `main()` exports `XDG_RUNTIME_DIR` proactively at start so `idempotency-probe` (Step 0) can talk to user systemd manager. Without this, re-runs on already-installed boxes wrongly fall through to fresh-install path.
- `step_apt_prereqs` (NEW): apt-installs `git ca-certificates curl jq bc cron` before bundle-validate / clone-repo. Robust against minimal VPS images. `bc` and `cron` specifically required by orch's April-21-baseline `deploy.sh` (line 191 / 278).
- `step_orch_install` + `step_allocator_install`: skip clone if `$DIR/.git` already present (partial-recovery: previous run cloned but deploy.sh failed; let module's own deploy.sh idempotency handle re-run).
- Sub-deploy exit code capture: `cmd && rc=0 || rc=$?` pattern (NOT `if ! cmd; rc=$?` which captures `!` operator's exit, always 0 inside body).

### Updated (Phase B.1 tests — new --mode contract)
- All 11 `test_bootstrap.sh` tests updated to pass `--mode single-bot` (with `--dry-run` for fail-early tests OR `--config /tmp/min-bundle.json` for full-flow tests). Phase B.1 test surface now matches Phase B.2 contract; both files exercise different mode paths.
- New helper `write_min_single_bot_bundle` writes minimal valid bundle.json fixture into container.
- Test fixtures no longer pre-install `python3.12` (bootstrap installs via apt-prereqs + python-install) — previous bundling caused atomic apt-install failures on Ubuntu 22.

### Added (Phase B.1)
- `bootstrap.sh` — Path C Phase B.1 installer for `nodeble-api-server` on fresh Ubuntu 22.04+ / 24.04+ VPS. Replaces 24-line placeholder. CTO 2026-05-05 design (`cto/reviews/2026-05-05-bootstrap-sh-design.md`) ratified. Steps: idempotency-probe → sudo-probe → os-check → disk-space-check → python-install → enable-linger → clone-repo → venv-create → pip-install → generate-api-token → generate-tls-cert → write-api-yaml → systemd-install → systemd-start. CLI `--verbose` / `--dry-run`. Env `NODEBLE_HOSTNAME` / `NODEBLE_API_PORT`.
- PAT-aware private-repo clone via `GITHUB_TOKEN` env var (CEO 2026-05-06 ratified Option 2 — `cto/reviews/2026-05-06-bootstrap-pat-aware-clone-dispatch.md`). Mac app injects via SSH env; bootstrap unsets after final clone.
- `tests/integration/test_bootstrap.sh` — acceptance test matrix (Ubuntu 22.04 + Ubuntu 24.04 happy-path × 3 sub-tests + 6 failure-mode tests).

### Removed (Phase B.1)
- **Debian 12 from supported OS list** (CEO 2026-05-06 ratified Option 1). Bookworm + bookworm-backports lack `python3.12` (only `python3.11` + `python3.13` available). `bootstrap.sh` rejects Debian with `STATUS: failure: unsupported_os: debian (Ubuntu 22.04+ only; Debian lacks python3.12 in main+backports)`. Close-circle deployment topology (Tower / 茗茗 / YB) is Ubuntu-only — zero loss.
