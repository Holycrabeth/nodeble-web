#!/usr/bin/env bash
# tests/integration/test_bootstrap_chain.sh — Path C chain Docker matrix
#
# Sections:
#   1. B.2 chain tests (CTO 2026-05-09 ratified, 9 tests)
#   2. Phase 3 multi-distro extension (single-bot ubuntu-24)
#   3. Phase 3 failure-mode (rocky+debian / sudo / network / missing-PAT)
#   4. Phase 3 failure isolation (orch_clone / orch_install / allocator)
#   5. Phase 3 idempotency + recovery (aggregate / partial-orch / partial-allocator)
#   6. Phase 3 bundle JSON validation (top-level / config_version / orch_missing)
#
# Specs:
#   - B.2 chain:    ~/projects/cto/reviews/2026-05-09-bootstrap-sh-phase-b2-chain-spec.md §9
#   - Phase 3:      ~/projects/cto/reviews/2026-05-10-bootstrap-chain-phase-3-docker-matrix-spec.md
#
# Bundle fixtures live at tests/integration/fixtures/ (copied into containers per test).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_SH="$REPO_ROOT/bootstrap.sh"
LOG_DIR="$SCRIPT_DIR/.logs"

DISTROS=(
    "ubuntu-22|jrei/systemd-ubuntu:22.04"
    "ubuntu-24|jrei/systemd-ubuntu:24.04"
)

# ──────────────────────────────────────────────────────────────────
# Result tracking
# ──────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
SKIP=0
declare -a CREATED_CONTAINERS=()

cleanup() {
    local c
    for c in "${CREATED_CONTAINERS[@]:-}"; do
        [ -z "$c" ] || docker rm -f "$c" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────
# Output helpers
# ──────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    G=$'\e[0;32m'
    R=$'\e[0;31m'
    Y=$'\e[0;33m'
    B=$'\e[0;34m'
    N=$'\e[0m'
else
    G=''; R=''; Y=''; B=''; N=''
fi

info() { printf '%s[INFO]%s %s\n' "$B" "$N" "$*"; }
pass() { printf '%s[PASS]%s %s\n' "$G" "$N" "$*"; PASS=$((PASS+1)); }
fail() { printf '%s[FAIL]%s %s\n' "$R" "$N" "$*"; FAIL=$((FAIL+1)); }
skip() { printf '%s[SKIP]%s %s\n' "$Y" "$N" "$*"; SKIP=$((SKIP+1)); }

# ──────────────────────────────────────────────────────────────────
# Assertion helpers
# ──────────────────────────────────────────────────────────────────
assert_status()  { local log="$1" pat="$2"; grep -qE "^STATUS: $pat" "$log"; }
assert_step_ok() { local log="$1" step="$2"; grep -qE "^STEP: $step ✓" "$log"; }
assert_result()  { local log="$1" key="$2" pat="${3:-.+}"; grep -qE "^RESULT_$key: $pat" "$log"; }

dump_log() {
    local log="$1"
    if [ -r "$log" ]; then
        echo "  --- last 40 of $log ---"
        tail -40 "$log" | sed 's/^/  /'
    fi
}

# ──────────────────────────────────────────────────────────────────
# Container helpers (mirror test_bootstrap.sh patterns)
# ──────────────────────────────────────────────────────────────────
register_container() { CREATED_CONTAINERS+=("$1"); }
container_running()  { docker ps --format '{{.Names}}' | grep -qx "$1"; }

start_plain_container() {
    local name="$1" image="$2"
    shift 2
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" "$@" "$image" sleep 1800 >/dev/null
    register_container "$name"
}

start_systemd_container() {
    local name="$1" image="$2"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$image" >/dev/null
    register_container "$name"
    sleep 3
}

# Pre-stage container with prereqs for chain-install tests.
# IMPORTANT: do NOT install python3.12 here — main repos on Ubuntu 22.04 lack
# it (only deadsnakes PPA has it for 22.04). Including it makes apt-get fail
# atomically and leave git/curl/etc uninstalled. Let bootstrap.sh handle python.
stage_container() {
    local container="$1"
    docker exec "$container" apt-get update -qq >/dev/null 2>&1 || true
    docker exec "$container" apt-get install -qq -y \
        git curl sudo iproute2 ca-certificates jq \
        > /dev/null 2>&1 || true
    # Dummy Tiger PEM file for allocator broker.private_key_path schema requirement
    docker exec "$container" bash -c \
        'printf -- "-----BEGIN PRIVATE KEY-----\nFAKEKEY\n-----END PRIVATE KEY-----\n" > /tmp/test-tiger.pem'
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Bundle JSON fixtures (copied from tests/integration/fixtures/ into containers)
# ──────────────────────────────────────────────────────────────────
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

copy_fixture() {
    local container="$1" fixture="$2" target="${3:-/tmp/bundle.json}"
    docker cp "$FIXTURES_DIR/$fixture" "$container:$target" >/dev/null
}

write_bundle_multi_module() {
    copy_fixture "$1" bundle-multi-module.json
}

write_bundle_single_bot() {
    copy_fixture "$1" bundle-single-bot.json
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode tests — exit before any sub-deploy runs
# ──────────────────────────────────────────────────────────────────
test_chain_missing_mode_flag() {
    info "test_chain_missing_mode_flag: --config X (no --mode) → exit 2"
    local container="bootstrap-chain-no-mode"
    local log="$LOG_DIR/chain-missing-mode.log"

    start_plain_container "$container" "ubuntu:24.04"
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null

    local rc=0
    docker exec "$container" bash /tmp/bootstrap.sh --config /tmp/x > "$log" 2>&1 || rc=$?

    if [ "$rc" = "2" ]; then
        pass "test_chain_missing_mode_flag"
    else
        fail "test_chain_missing_mode_flag: expected exit 2, got $rc"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_invalid_mode_flag() {
    info "test_chain_invalid_mode_flag: --mode invalid → exit 2"
    local container="bootstrap-chain-invalid-mode"
    local log="$LOG_DIR/chain-invalid-mode.log"

    start_plain_container "$container" "ubuntu:24.04"
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null

    local rc=0
    docker exec "$container" bash /tmp/bootstrap.sh --mode invalid --config /tmp/x > "$log" 2>&1 || rc=$?

    if [ "$rc" = "2" ]; then
        pass "test_chain_invalid_mode_flag"
    else
        fail "test_chain_invalid_mode_flag: expected exit 2, got $rc"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_missing_bundle_config() {
    info "test_chain_missing_bundle_config: --mode multi-module (no --config) → exit 2"
    local container="bootstrap-chain-no-config"
    local log="$LOG_DIR/chain-no-config.log"

    start_plain_container "$container" "ubuntu:24.04"
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null

    local rc=0
    docker exec "$container" bash /tmp/bootstrap.sh --mode multi-module > "$log" 2>&1 || rc=$?

    if [ "$rc" = "2" ]; then
        pass "test_chain_missing_bundle_config"
    else
        fail "test_chain_missing_bundle_config: expected exit 2, got $rc"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_invalid_bundle() {
    info "test_chain_invalid_bundle: bad bundle.json → exit 3 STATUS: bundle_invalid"
    local container="bootstrap-chain-bad-bundle"
    local log="$LOG_DIR/chain-bad-bundle.log"

    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_invalid_bundle: NODEBLE_TEST_PAT not set"
        return
    fi

    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    stage_container "$container"
    # Bad bundle: missing required `mode` field at top level
    docker exec "$container" bash -c \
        'echo "{\"module\":\"bootstrap-bundle\",\"config_version\":1}" > /tmp/bad-bundle.json'

    local rc=0
    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bad-bundle.json \
        > "$log" 2>&1 || rc=$?

    if [ "$rc" = "3" ] && assert_status "$log" "failure: bundle_invalid"; then
        pass "test_chain_invalid_bundle"
    else
        fail "test_chain_invalid_bundle: expected exit 3 + bundle_invalid (got rc=$rc)"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Happy-path tests
# ──────────────────────────────────────────────────────────────────
test_chain_multi_module() {
    local label="$1" image="$2"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_multi_module[$label]: NODEBLE_TEST_PAT not set"
        return
    fi

    info "test_chain_multi_module[$label]: full chain on $image"
    local container="bootstrap-chain-multi-$label"
    local log="$LOG_DIR/chain-multi-$label-fresh.log"

    start_systemd_container "$container" "$image"
    stage_container "$container"
    write_bundle_multi_module "$container"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$log" 2>&1 || true

    if grep -q "$NODEBLE_TEST_PAT" "$log"; then
        fail "test_chain_multi_module[$label]: PAT leaked into log!"
        dump_log "$log"
        return
    fi

    if assert_status "$log" "success" \
       && assert_step_ok "$log" "orch-install" \
       && assert_step_ok "$log" "allocator-install" \
       && assert_result "$log" "MODE" "multi-module" \
       && assert_result "$log" "MODULES_INSTALLED" "api-server,orchestrator,allocator"; then
        pass "test_chain_multi_module[$label]"
    else
        fail "test_chain_multi_module[$label]: missing STATUS: success or RESULT_*/STEP"
        dump_log "$log"
    fi
}

test_chain_idempotent_rerun_multi_module() {
    local label="$1"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_idempotent_rerun_multi_module[$label]: NODEBLE_TEST_PAT not set"
        return
    fi
    local container="bootstrap-chain-multi-$label"
    if ! container_running "$container"; then
        skip "test_chain_idempotent_rerun_multi_module[$label]: container missing (multi_module test failed?)"
        return
    fi

    info "test_chain_idempotent_rerun_multi_module[$label]: 2nd run → already_installed"
    local log="$LOG_DIR/chain-multi-$label-rerun.log"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$log" 2>&1 || true

    if assert_status "$log" "already_installed"; then
        pass "test_chain_idempotent_rerun_multi_module[$label]"
    else
        fail "test_chain_idempotent_rerun_multi_module[$label]: expected STATUS: already_installed"
        dump_log "$log"
    fi

    # Last test using this container; cleanup
    docker rm -f "$container" >/dev/null 2>&1 || true
}

test_chain_single_bot() {
    local label="$1" image="$2"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_single_bot[$label]: NODEBLE_TEST_PAT not set"
        return
    fi

    info "test_chain_single_bot[$label]: api-server only on $image"
    local container="bootstrap-chain-single-$label"
    local log="$LOG_DIR/chain-single-$label.log"

    start_systemd_container "$container" "$image"
    stage_container "$container"
    write_bundle_single_bot "$container"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/bundle.json \
        > "$log" 2>&1 || true

    if assert_status "$log" "success" \
       && assert_result "$log" "MODE" "single-bot" \
       && assert_result "$log" "MODULES_INSTALLED" "api-server"; then
        # Verify orch-install + allocator-install were SKIPPED (not run)
        if grep -qE "STEP: orch-install ✓ skipped" "$log" \
           && grep -qE "STEP: allocator-install ✓ skipped" "$log"; then
            pass "test_chain_single_bot[$label]"
        else
            fail "test_chain_single_bot[$label]: orch/allocator should be skipped in single-bot mode"
            dump_log "$log"
        fi
    else
        fail "test_chain_single_bot[$label]: missing STATUS: success or RESULT_*"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ══════════════════════════════════════════════════════════════════
# Phase 3 — Section 3: Failure-mode tests (Path C 4-tier coverage)
# Mirror 4-module Phase 3 canonical pattern (rocky+debian / sudo / network / PAT).
# ══════════════════════════════════════════════════════════════════

test_chain_unsupported_os() {
    info "test_chain_unsupported_os: rockylinux:9 + debian:12 must STATUS: failure: unsupported_os"
    local distros=("rocky-9|rockylinux:9" "debian-12|debian:12")
    local entry label image container log fails=0
    for entry in "${distros[@]}"; do
        label="${entry%%|*}"
        image="${entry#*|}"
        container="bootstrap-chain-unsupp-$label"
        log="$LOG_DIR/chain-unsupp-$label.log"
        start_plain_container "$container" "$image"
        docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
        # --dry-run satisfies parse_args without requiring --config; os-check still runs
        docker exec "$container" \
            bash /tmp/bootstrap.sh --mode multi-module --dry-run > "$log" 2>&1 || true
        if ! assert_status "$log" "failure: unsupported_os"; then
            echo "  [$label] expected unsupported_os in $log" >&2
            dump_log "$log"
            fails=$((fails + 1))
        fi
        docker rm -f "$container" >/dev/null
    done
    if [ "$fails" -eq 0 ]; then
        pass "test_chain_unsupported_os (rocky-9 + debian-12)"
    else
        fail "test_chain_unsupported_os: $fails sub-test(s) failed"
    fi
}

test_chain_requires_sudo() {
    info "test_chain_requires_sudo: non-root user without NOPASSWD → STATUS: failure: requires_sudo"
    local container="bootstrap-chain-no-sudo"
    local log="$LOG_DIR/chain-no-sudo.log"
    start_plain_container "$container" "ubuntu:22.04"
    docker exec "$container" useradd -m -s /bin/bash testuser >/dev/null
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    docker exec "$container" chmod 755 /tmp/bootstrap.sh

    docker exec --user testuser "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --dry-run > "$log" 2>&1 || true

    if assert_status "$log" "failure: requires_sudo"; then
        pass "test_chain_requires_sudo"
    else
        fail "test_chain_requires_sudo: expected requires_sudo"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_network_none() {
    info "test_chain_network_none: --network none → STATUS: failure at network-touching step"
    local container="bootstrap-chain-no-net"
    local log="$LOG_DIR/chain-no-net.log"
    start_plain_container "$container" "ubuntu:22.04" --network none
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    copy_fixture "$container" bundle-single-bot.json

    docker exec "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/bundle.json \
        > "$log" 2>&1 || true

    local network_reasons='(apt_update_failed|apt_prereqs_failed|software_properties_install_failed|deadsnakes_ppa_failed|python_install_failed|git_clone_failed|git_update_failed)'
    if grep -qE "^STATUS: failure: $network_reasons" "$log"; then
        pass "test_chain_network_none"
    else
        fail "test_chain_network_none: STATUS not in network-failure set"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_missing_github_token() {
    info "test_chain_missing_github_token: GITHUB_TOKEN env unset → STATUS: failure: missing_github_token"
    local container="bootstrap-chain-no-pat"
    local log="$LOG_DIR/chain-no-pat.log"
    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    stage_container "$container"
    copy_fixture "$container" bundle-single-bot.json

    # Run WITHOUT GITHUB_TOKEN (deliberate)
    docker exec "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/bundle.json \
        > "$log" 2>&1 || true

    if assert_status "$log" "failure: missing_github_token"; then
        pass "test_chain_missing_github_token"
    else
        fail "test_chain_missing_github_token: expected missing_github_token"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ══════════════════════════════════════════════════════════════════
# Phase 3 — Section 4: Failure isolation (verify B.2 §7 contract empirically)
# Each test verifies that a sub-deploy failure isolates earlier successful
# installs (no rollback) AND prevents downstream sub-deploys from running.
# ══════════════════════════════════════════════════════════════════

# Small helper: assert systemd service is active in the container.
assert_service_active() {
    local container="$1" service="$2"
    docker exec --env "XDG_RUNTIME_DIR=/run/user/0" "$container" \
        systemctl --user is-active "$service" >/dev/null 2>&1
}

test_chain_orch_clone_failed_isolates_api_server() {
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_orch_clone_failed_isolates_api_server: NODEBLE_TEST_PAT not set"
        return
    fi
    info "test_chain_orch_clone_failed_isolates_api_server: orch clone fail → api-server stays installed"
    local container="bootstrap-chain-orch-clone-fail"
    local log="$LOG_DIR/chain-orch-clone-fail.log"
    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    stage_container "$container"
    copy_fixture "$container" bundle-multi-module.json

    # Pre-create blocking content at orch dir (non-git, but dir not empty →
    # bootstrap's clone-skip check sees no .git → tries to clone → fails)
    docker exec "$container" bash -c \
        'mkdir -p /opt/nodeble/orchestrator && touch /opt/nodeble/orchestrator/blocker'

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$log" 2>&1 || true

    # 1. api-server installed before orch step (systemd-start ✓ emitted)
    if ! assert_step_ok "$log" "systemd-start"; then
        fail "test_chain_orch_clone_failed_isolates_api_server: api-server didn't install before orch fail"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    # 2. orch step failed with orch_clone_failed
    if ! assert_status "$log" "failure: orch_clone_failed"; then
        fail "test_chain_orch_clone_failed_isolates_api_server: expected orch_clone_failed"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    # 3. allocator-install step NOT reached
    if grep -qE "^STEP: allocator-install" "$log"; then
        fail "test_chain_orch_clone_failed_isolates_api_server: allocator step shouldn't have started"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    # 4. api-server systemd service still active (no rollback)
    if ! assert_service_active "$container" "nodeble-api-server.service"; then
        fail "test_chain_orch_clone_failed_isolates_api_server: api-server should stay active"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    pass "test_chain_orch_clone_failed_isolates_api_server"
    docker rm -f "$container" >/dev/null
}

test_chain_orch_install_failed_isolates_api_server() {
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_orch_install_failed_isolates_api_server: NODEBLE_TEST_PAT not set"
        return
    fi
    info "test_chain_orch_install_failed_isolates_api_server: orch deploy fail → api-server stays installed"
    local container="bootstrap-chain-orch-install-fail"
    local log="$LOG_DIR/chain-orch-install-fail.log"
    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    stage_container "$container"
    copy_fixture "$container" bundle-failing-orch.json

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$log" 2>&1 || true

    if ! assert_step_ok "$log" "systemd-start"; then
        fail "test_chain_orch_install_failed_isolates_api_server: api-server didn't install"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    if ! grep -qE "^STATUS: failure: orch_install_failed" "$log"; then
        fail "test_chain_orch_install_failed_isolates_api_server: expected orch_install_failed"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    if grep -qE "^STEP: allocator-install" "$log"; then
        fail "test_chain_orch_install_failed_isolates_api_server: allocator should NOT start"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    if ! assert_service_active "$container" "nodeble-api-server.service"; then
        fail "test_chain_orch_install_failed_isolates_api_server: api-server should stay active"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    pass "test_chain_orch_install_failed_isolates_api_server"
    docker rm -f "$container" >/dev/null
}

test_chain_allocator_install_failed_isolates_prior() {
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_allocator_install_failed_isolates_prior: NODEBLE_TEST_PAT not set"
        return
    fi
    info "test_chain_allocator_install_failed_isolates_prior: allocator fail → api-server + orch stay installed"
    local container="bootstrap-chain-alloc-fail"
    local log="$LOG_DIR/chain-alloc-fail.log"
    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    stage_container "$container"
    copy_fixture "$container" bundle-multi-module.json

    # Make allocator fail by clearing base_weights (schema requires minProperties:1 →
    # parse_config.py validation fails; allocator deploy.sh exits 3 → bootstrap propagates 14)
    docker exec "$container" bash -c \
        "jq '.allocator.base_weights = {}' /tmp/bundle.json > /tmp/b.json && mv /tmp/b.json /tmp/bundle.json"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$log" 2>&1 || true

    if ! assert_step_ok "$log" "systemd-start" \
       || ! assert_step_ok "$log" "orch-install"; then
        fail "test_chain_allocator_install_failed_isolates_prior: api-server or orch didn't install"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    if ! grep -qE "^STATUS: failure: allocator_install_failed" "$log"; then
        fail "test_chain_allocator_install_failed_isolates_prior: expected allocator_install_failed"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    if ! assert_service_active "$container" "nodeble-api-server.service"; then
        fail "test_chain_allocator_install_failed_isolates_prior: api-server should stay active"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    # orch should still have its cron entries (no rollback)
    if ! docker exec "$container" crontab -l 2>/dev/null | grep -q "nodeble-orchestrator\|nodeble_orchestrator"; then
        fail "test_chain_allocator_install_failed_isolates_prior: orch cron entries missing (rollback?)"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi
    pass "test_chain_allocator_install_failed_isolates_prior"
    docker rm -f "$container" >/dev/null
}

# ══════════════════════════════════════════════════════════════════
# Phase 3 — Section 5: Idempotency + partial-state recovery
# Verify chain-level aggregate idempotency + recovery from partial state
# (api-server-only, api-server+orch-only).
# ══════════════════════════════════════════════════════════════════

# Setup helper: install full multi-module chain in a fresh container.
# Returns 0 on success, 1 on install failure (caller may skip).
setup_full_install() {
    local container="$1" image="$2" log="$3"
    start_systemd_container "$container" "$image"
    stage_container "$container"
    copy_fixture "$container" bundle-multi-module.json
    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$log" 2>&1
}

test_chain_aggregate_already_installed_multi_module() {
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_aggregate_already_installed_multi_module: NODEBLE_TEST_PAT not set"
        return
    fi
    info "test_chain_aggregate_already_installed_multi_module: 2nd run all 3 already_installed → STATUS: already_installed"
    local container="bootstrap-chain-aggregate"
    local fresh_log="$LOG_DIR/chain-aggregate-fresh.log"
    local rerun_log="$LOG_DIR/chain-aggregate-rerun.log"

    if ! setup_full_install "$container" "jrei/systemd-ubuntu:24.04" "$fresh_log"; then
        fail "test_chain_aggregate_already_installed_multi_module: initial install failed"
        dump_log "$fresh_log"
        docker rm -f "$container" >/dev/null
        return
    fi

    # 2nd run — expect aggregate already_installed
    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$rerun_log" 2>&1 || true

    # Verify aggregate STATUS + per-step "already installed" messages
    if assert_status "$rerun_log" "already_installed" \
       && grep -qE "^STEP: idempotency-probe ✓ api-server already installed" "$rerun_log" \
       && grep -qE "^STEP: orch-install ✓ already installed" "$rerun_log"; then
        pass "test_chain_aggregate_already_installed_multi_module"
    else
        fail "test_chain_aggregate_already_installed_multi_module: aggregate not already_installed"
        dump_log "$rerun_log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_partial_state_resumes_from_orch() {
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_partial_state_resumes_from_orch: NODEBLE_TEST_PAT not set"
        return
    fi
    info "test_chain_partial_state_resumes_from_orch: api-server-only state → orch + allocator install"
    local container="bootstrap-chain-partial-orch"
    local fresh_log="$LOG_DIR/chain-partial-orch-fresh.log"
    local rerun_log="$LOG_DIR/chain-partial-orch-rerun.log"

    if ! setup_full_install "$container" "jrei/systemd-ubuntu:24.04" "$fresh_log"; then
        fail "test_chain_partial_state_resumes_from_orch: initial install failed"
        dump_log "$fresh_log"
        docker rm -f "$container" >/dev/null
        return
    fi

    # Nuke orch + allocator state (api-server stays); also clear orch cron entries
    docker exec "$container" bash -c '
        rm -rf /opt/nodeble/orchestrator /opt/nodeble/allocator
        rm -rf /root/.nodeble-orchestrator /root/.nodeble-allocator
        crontab -l 2>/dev/null \
            | grep -vE "nodeble-orchestrator|nodeble_orchestrator|nodeble-allocator|nodeble_allocator" \
            | crontab - 2>/dev/null || crontab -r 2>/dev/null || true
    ' >/dev/null 2>&1 || true

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$rerun_log" 2>&1 || true

    # api-server: already_installed (idempotency-probe at start)
    # orch: fresh install ("STEP: orch-install ✓ installed at" not "already installed at")
    # allocator: fresh install
    # Final: STATUS: success (mixed, not all already_installed)
    if grep -qE "^STEP: idempotency-probe ✓ api-server already installed" "$rerun_log" \
       && grep -qE "^STEP: orch-install ✓ installed at" "$rerun_log" \
       && grep -qE "^STEP: allocator-install ✓" "$rerun_log" \
       && assert_status "$rerun_log" "success"; then
        pass "test_chain_partial_state_resumes_from_orch"
    else
        fail "test_chain_partial_state_resumes_from_orch: didn't resume cleanly from api-server-only state"
        dump_log "$rerun_log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_partial_state_resumes_from_allocator() {
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_chain_partial_state_resumes_from_allocator: NODEBLE_TEST_PAT not set"
        return
    fi
    info "test_chain_partial_state_resumes_from_allocator: api-server+orch state → allocator installs fresh"
    local container="bootstrap-chain-partial-alloc"
    local fresh_log="$LOG_DIR/chain-partial-alloc-fresh.log"
    local rerun_log="$LOG_DIR/chain-partial-alloc-rerun.log"

    if ! setup_full_install "$container" "jrei/systemd-ubuntu:24.04" "$fresh_log"; then
        fail "test_chain_partial_state_resumes_from_allocator: initial install failed"
        dump_log "$fresh_log"
        docker rm -f "$container" >/dev/null
        return
    fi

    # Nuke ONLY allocator state (api-server + orch stay)
    docker exec "$container" bash -c '
        rm -rf /opt/nodeble/allocator /root/.nodeble-allocator
        crontab -l 2>/dev/null \
            | grep -vE "nodeble-allocator|nodeble_allocator" \
            | crontab - 2>/dev/null || true
    ' >/dev/null 2>&1 || true

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json --skip-tiger-test \
        > "$rerun_log" 2>&1 || true

    # api-server already_installed; orch already_installed (cron + .git intact);
    # allocator fresh; final STATUS: success
    if grep -qE "^STEP: idempotency-probe ✓ api-server already installed" "$rerun_log" \
       && grep -qE "^STEP: orch-install ✓ already installed at" "$rerun_log" \
       && grep -qE "^STEP: allocator-install ✓" "$rerun_log" \
       && assert_status "$rerun_log" "success"; then
        pass "test_chain_partial_state_resumes_from_allocator"
    else
        fail "test_chain_partial_state_resumes_from_allocator: didn't resume cleanly"
        dump_log "$rerun_log"
    fi
    docker rm -f "$container" >/dev/null
}

# ══════════════════════════════════════════════════════════════════
# Phase 3 — Section 6: Bundle JSON validation
# Extends B.2's basic test_chain_invalid_bundle with specific schema
# violations (missing module field, wrong config_version, orch missing required).
# ══════════════════════════════════════════════════════════════════

# Internal helper for bundle validation tests — shared structure.
_bundle_validation_test() {
    local test_name="$1" fixture="$2" expect_pattern="$3"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "$test_name: NODEBLE_TEST_PAT not set"
        return
    fi
    info "$test_name: $fixture → exit 3 STATUS: bundle_invalid"
    local container="bootstrap-chain-${test_name#test_chain_}"
    container="${container//_/-}"
    local log="$LOG_DIR/chain-${test_name#test_chain_}.log"
    log="${log//_/-}"

    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    stage_container "$container"
    copy_fixture "$container" "$fixture"

    local rc=0
    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode multi-module --config /tmp/bundle.json \
        > "$log" 2>&1 || rc=$?

    if [ "$rc" = "3" ] && grep -qE "^STATUS: failure: bundle_invalid: $expect_pattern" "$log"; then
        pass "$test_name"
    else
        fail "$test_name: expected exit 3 + 'bundle_invalid: $expect_pattern' (got rc=$rc)"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

test_chain_bundle_missing_top_level_module_field() {
    _bundle_validation_test \
        "test_chain_bundle_missing_top_level_module_field" \
        "bundle-missing-module-field.json" \
        "module="
}

test_chain_bundle_wrong_config_version() {
    _bundle_validation_test \
        "test_chain_bundle_wrong_config_version" \
        "bundle-wrong-config-version.json" \
        "config_version="
}

test_chain_bundle_orch_missing_required() {
    _bundle_validation_test \
        "test_chain_bundle_orch_missing_required" \
        "bundle-orch-missing-required.json" \
        "orchestrator\\."
}

# ──────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────
main() {
    [ -r "$BOOTSTRAP_SH" ] || {
        echo "bootstrap.sh not found at $BOOTSTRAP_SH" >&2
        exit 1
    }
    mkdir -p "$LOG_DIR"
    rm -f "$LOG_DIR"/chain-*.log 2>/dev/null || true

    info "test_bootstrap_chain.sh starting (Path C 4-tier coverage)"
    info "bootstrap.sh: $BOOTSTRAP_SH ($(wc -l < "$BOOTSTRAP_SH") lines)"

    info ""
    info "=== Section 1: B.2 chain CLI/bundle parse ==="
    test_chain_missing_mode_flag
    test_chain_invalid_mode_flag
    test_chain_missing_bundle_config
    test_chain_invalid_bundle

    info ""
    info "=== Section 2: B.2 happy-path + multi-distro extension ==="
    local entry label image
    for entry in "${DISTROS[@]}"; do
        label="${entry%%|*}"
        image="${entry#*|}"
        test_chain_multi_module "$label" "$image"
        test_chain_idempotent_rerun_multi_module "$label"
    done
    # Phase 3 multi-distro extension: single-bot on both Ubuntu distros (B.2 covered ubuntu-22 only)
    test_chain_single_bot "ubuntu-22" "jrei/systemd-ubuntu:22.04"
    test_chain_single_bot "ubuntu-24" "jrei/systemd-ubuntu:24.04"

    info ""
    info "=== Section 3: Phase 3 failure-mode (rocky/debian/sudo/network/PAT) ==="
    test_chain_unsupported_os
    test_chain_requires_sudo
    test_chain_network_none
    test_chain_missing_github_token

    info ""
    info "=== Section 4: Phase 3 failure isolation (B.2 §7 contract verification) ==="
    test_chain_orch_clone_failed_isolates_api_server
    test_chain_orch_install_failed_isolates_api_server
    test_chain_allocator_install_failed_isolates_prior

    info ""
    info "=== Section 5: Phase 3 idempotency + recovery ==="
    test_chain_aggregate_already_installed_multi_module
    test_chain_partial_state_resumes_from_orch
    test_chain_partial_state_resumes_from_allocator

    info ""
    info "=== Section 6: Phase 3 bundle JSON validation ==="
    test_chain_bundle_missing_top_level_module_field
    test_chain_bundle_wrong_config_version
    test_chain_bundle_orch_missing_required

    info ""
    info "=== Summary ==="
    info "PASS: $PASS"
    info "FAIL: $FAIL"
    info "SKIP: $SKIP"

    [ "$FAIL" -eq 0 ]
}

main "$@"
