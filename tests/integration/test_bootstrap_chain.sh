#!/usr/bin/env bash
# tests/integration/test_bootstrap_chain.sh — Phase B.2 chain acceptance tests
# Per CTO spec ~/projects/cto/reviews/2026-05-09-bootstrap-sh-phase-b2-chain-spec.md §9.
#
# Test set:
#   - 4 failure-mode (--mode missing / invalid / --config missing / bad-bundle)
#   - 2 happy-path multi-module × distros (ubuntu-22, ubuntu-24)
#   - 2 idempotent-rerun multi-module × distros (reuses container)
#   - 1 happy-path single-bot (ubuntu-22)
# Total: 9 tests target.

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
# Bundle JSON fixtures (heredocs piped to container files)
# ──────────────────────────────────────────────────────────────────
write_bundle_multi_module() {
    local container="$1"
    docker exec -i "$container" bash -c 'cat > /tmp/bundle.json' <<'EOF'
{
    "module": "bootstrap-bundle",
    "config_version": 1,
    "mode": "multi-module",
    "api_server": {
        "module": "api-server",
        "config_version": 1
    },
    "orchestrator": {
        "nlv": 320000,
        "floor": 20,
        "reserve": 30,
        "fred_key": "test-fred-key"
    },
    "allocator": {
        "module": "allocator",
        "config_version": 1,
        "broker": {
            "tiger_id": "test-tiger-id",
            "account": "test-account",
            "private_key_path": "/tmp/test-tiger.pem"
        },
        "portfolio": {
            "base_cash_floor_pct": 0.20,
            "max_additional_reserve_pct": 0.30
        },
        "base_weights": {
            "ic": 1.0
        }
    }
}
EOF
}

write_bundle_single_bot() {
    local container="$1"
    docker exec -i "$container" bash -c 'cat > /tmp/bundle.json' <<'EOF'
{
    "module": "bootstrap-bundle",
    "config_version": 1,
    "mode": "single-bot",
    "api_server": {
        "module": "api-server",
        "config_version": 1
    }
}
EOF
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

    info "test_bootstrap_chain.sh starting (Phase B.2)"
    info "bootstrap.sh: $BOOTSTRAP_SH ($(wc -l < "$BOOTSTRAP_SH") lines)"

    info ""
    info "=== Failure-mode tests ==="
    test_chain_missing_mode_flag
    test_chain_invalid_mode_flag
    test_chain_missing_bundle_config
    test_chain_invalid_bundle

    info ""
    info "=== Happy-path tests (multi-module + idempotent rerun × 2 distros + single-bot) ==="
    local entry label image
    for entry in "${DISTROS[@]}"; do
        label="${entry%%|*}"
        image="${entry#*|}"
        test_chain_multi_module "$label" "$image"
        test_chain_idempotent_rerun_multi_module "$label"
    done
    test_chain_single_bot "ubuntu-22" "jrei/systemd-ubuntu:22.04"

    info ""
    info "=== Summary ==="
    info "PASS: $PASS"
    info "FAIL: $FAIL"
    info "SKIP: $SKIP"

    [ "$FAIL" -eq 0 ]
}

main "$@"
