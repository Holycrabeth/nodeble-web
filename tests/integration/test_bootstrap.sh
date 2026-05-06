#!/usr/bin/env bash
# tests/integration/test_bootstrap.sh — Path C Phase B.1 acceptance tests
# Per CTO spec §9 (~/projects/cto/reviews/2026-05-05-bootstrap-sh-design.md).
#
# Status (5/6 SGT Session 2 partial):
#   - Failure-mode tests:  IMPLEMENTED + runnable today (greenlit)
#   - Happy-path tests:    SKIP-stubbed pending CTO arbitration on
#                          nodeble-api-server private-repo blocker
#                          (Options 1/2/3/4 — see DEV_MEMORY.md 5/6).
#
# Substitution: spec §9.2 references `centos:9` which is deprecated on
# Docker Hub. Using `rockylinux:9` instead — same RHEL-derivative class,
# bootstrap rejects with `unsupported_os` (OS_ID=rocky).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_SH="$REPO_ROOT/bootstrap.sh"
LOG_DIR="$SCRIPT_DIR/.logs"

# Distros for happy-path matrix (CTO spec §9.1) — systemd-enabled fixtures
HAPPY_DISTROS=(
    "ubuntu-22|jrei/systemd-ubuntu:22.04"
    "ubuntu-24|jrei/systemd-ubuntu:24.04"
    "debian-12|jrei/systemd-debian:12"
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
# Output helpers (color if tty)
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
# Assertion helpers (STEP/STATUS/RESULT log parsing)
# ──────────────────────────────────────────────────────────────────
# Log contains a STATUS: <pattern> line.
assert_status() {
    local log="$1" pattern="$2"
    grep -qE "^STATUS: $pattern" "$log"
}

# Log contains a STEP: <step> ✓ ... line (with optional message pattern).
assert_step_ok() {
    local log="$1" step="$2"
    grep -qE "^STEP: $step ✓" "$log"
}

# Log contains a STEP: <step> ✗ <reason> line.
assert_step_fail() {
    local log="$1" step="$2" reason_pattern="$3"
    grep -qE "^STEP: $step ✗ $reason_pattern" "$log"
}

# Log contains a RESULT_<key>: <value> line.
assert_result() {
    local log="$1" key="$2" value_pattern="${3:-.+}"
    grep -qE "^RESULT_$key: $value_pattern" "$log"
}

dump_log() {
    local log="$1"
    if [ -r "$log" ]; then
        echo "  --- last 30 lines of $log ---"
        tail -30 "$log" | sed 's/^/  /'
    fi
}

# ──────────────────────────────────────────────────────────────────
# Container helpers
# ──────────────────────────────────────────────────────────────────
register_container() {
    CREATED_CONTAINERS+=("$1")
}

start_plain_container() {
    local name="$1" image="$2"
    shift 2
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" "$@" "$image" sleep 600 >/dev/null
    register_container "$name"
}

start_systemd_container() {
    local name="$1" image="$2"
    docker rm -f "$name" >/dev/null 2>&1 || true
    # cgroup v2 flags: --cgroupns=host + rw cgroup mount (Tower host runs cgroup v2;
    # legacy cgroup v1 ro mount + /sbin/init pattern fails to boot systemd here).
    docker run -d --name "$name" --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$image" >/dev/null
    register_container "$name"
    sleep 3
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode test 1: unsupported OS (rockylinux:9 stand-in for centos:9)
# ──────────────────────────────────────────────────────────────────
test_unsupported_os() {
    info "test_unsupported_os: bootstrap.sh on rockylinux:9 → STATUS: failure: unsupported_os"
    local container="bootstrap-test-rocky9"
    local log="$LOG_DIR/unsupported-os.log"

    start_plain_container "$container" "rockylinux:9"
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    docker exec "$container" bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    if assert_status "$log" "failure: unsupported_os"; then
        pass "test_unsupported_os"
    else
        fail "test_unsupported_os: missing 'STATUS: failure: unsupported_os'"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode test 2: sudo missing → requires_sudo
# ──────────────────────────────────────────────────────────────────
test_requires_sudo() {
    info "test_requires_sudo: non-root user without sudo NOPASSWD → STATUS: failure: requires_sudo"
    local container="bootstrap-test-nosudo"
    local log="$LOG_DIR/requires-sudo.log"

    start_plain_container "$container" "ubuntu:22.04"
    docker exec "$container" useradd -m -s /bin/bash testuser >/dev/null
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    docker exec "$container" chmod 755 /tmp/bootstrap.sh
    docker exec --user testuser "$container" bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    if assert_status "$log" "failure: requires_sudo"; then
        pass "test_requires_sudo"
    else
        fail "test_requires_sudo: missing 'STATUS: failure: requires_sudo'"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode test 3: --network none → network-related step failure
# (precise — not e.g. apt-mirror-misconfig conflated, per 协作总监 5/6 ask)
# ──────────────────────────────────────────────────────────────────
test_network_none() {
    info "test_network_none: --network none → STATUS: failure at a network-touching step"
    local container="bootstrap-test-nonet"
    local log="$LOG_DIR/network-none.log"

    start_plain_container "$container" "ubuntu:22.04" --network none
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    docker exec "$container" bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    # Steps that touch the network (precise expected reasons):
    local network_reasons='(apt_update_failed|software_properties_install_failed|deadsnakes_ppa_failed|python_install_failed|git_clone_failed|git_update_failed)'
    if grep -qE "^STATUS: failure: $network_reasons" "$log"; then
        pass "test_network_none"
    else
        fail "test_network_none: STATUS line not in expected network-failure set"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode test 4 (Option 2): GITHUB_TOKEN env var missing
# Per CTO 2026-05-06 PAT-aware-clone dispatch §5
# ──────────────────────────────────────────────────────────────────
test_github_token_missing() {
    info "test_github_token_missing: no GITHUB_TOKEN env → STATUS: failure: missing_github_token"
    local container="bootstrap-test-no-pat"
    local log="$LOG_DIR/github-token-missing.log"

    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    # Pre-stage prereqs so bootstrap reaches step_clone_repo (where token check fires)
    docker exec "$container" apt-get update -qq >/dev/null 2>&1
    docker exec "$container" apt-get install -qq -y python3.12 python3.12-venv git curl sudo iproute2 ca-certificates >/dev/null 2>&1
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null

    # Run WITHOUT GITHUB_TOKEN env (deliberately not setting it)
    docker exec "$container" bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    if assert_status "$log" "failure: missing_github_token"; then
        pass "test_github_token_missing"
    else
        fail "test_github_token_missing: expected 'STATUS: failure: missing_github_token'"
        dump_log "$log"
    fi
    docker rm -f "$container" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode test 5 (Option 2): PAT redacted in error output
# Per CTO 2026-05-06 PAT-aware-clone dispatch §5 + §1 hygiene #3
# ──────────────────────────────────────────────────────────────────
test_pat_redacted_in_error_output() {
    info "test_pat_redacted_in_error_output: invalid PAT → token must NOT appear in any output"
    local container="bootstrap-test-pat-redact"
    local log="$LOG_DIR/pat-redact.log"
    # Distinctive fake PAT — easy to grep for in log
    local fake_pat="ghp_FAKETESTPATFORREDACTIONVERIFICATION1234567890"

    start_systemd_container "$container" "jrei/systemd-ubuntu:24.04"
    docker exec "$container" apt-get update -qq >/dev/null 2>&1
    docker exec "$container" apt-get install -qq -y python3.12 python3.12-venv git curl sudo iproute2 ca-certificates >/dev/null 2>&1
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null

    # Run with INVALID PAT — clone will fail (401); verify PAT not leaked anywhere
    docker exec --env "GITHUB_TOKEN=$fake_pat" "$container" bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    if grep -q "$fake_pat" "$log"; then
        fail "test_pat_redacted_in_error_output: fake PAT '$fake_pat' appeared in log!"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi

    # Sanity: clone should have failed (with redacted output evident OR distinct status)
    if ! grep -qE "^STATUS: failure:" "$log"; then
        fail "test_pat_redacted_in_error_output: expected clone failure but no failure STATUS"
        dump_log "$log"
        docker rm -f "$container" >/dev/null
        return
    fi

    pass "test_pat_redacted_in_error_output"
    docker rm -f "$container" >/dev/null
}

# ──────────────────────────────────────────────────────────────────
# Happy-path tests (CTO spec §9.1 + Option 2 PAT contract)
#
# Container reuse pattern: test_happy_path creates container, leaves it
# running for test_idempotent_rerun + test_uninstall_reinstall on the
# same label. Cleanup at script-exit trap.
# ──────────────────────────────────────────────────────────────────
container_running() {
    docker ps --format '{{.Names}}' | grep -qx "$1"
}

test_happy_path() {
    local label="$1" image="$2"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_happy_path[$label]: NODEBLE_TEST_PAT env not set (export NODEBLE_TEST_PAT=\$(cat ~/.config/nodeble-bootstrap-pat) to resume)"
        return
    fi
    # Debian 12 hard constraint (5/6 SGT verify-from-source): bookworm + bookworm-backports
    # ship only python3.11; no path to python3.12 short of source-build / pyenv / deadsnakes-
    # equivalent. Surfaced to 协作总监 + CTO for arbitration (drop Debian 12 vs relax to
    # python3.11 vs source-build vs deadsnakes-equivalent). Tests held until decision.
    if [ "$label" = "debian-12" ]; then
        skip "test_happy_path[debian-12]: HOLD — Debian 12 lacks python3.12 in main+backports (5/6 SGT escalation)"
        return
    fi

    info "test_happy_path[$label]: fresh install on $image → STATUS: success + RESULT_*"
    local container="bootstrap-test-happy-$label"
    local log="$LOG_DIR/happy-$label-fresh.log"

    start_systemd_container "$container" "$image"
    docker exec "$container" apt-get update -qq >/dev/null 2>&1 || true
    docker exec "$container" apt-get install -qq -y curl git sudo iproute2 ca-certificates >/dev/null 2>&1 || true
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    # Defensive: scan for PAT leak in any log (security regression check)
    if grep -q "$NODEBLE_TEST_PAT" "$log"; then
        fail "test_happy_path[$label]: PAT leaked into log!"
        dump_log "$log"
        return
    fi

    if ! assert_status "$log" "success"; then
        fail "test_happy_path[$label]: expected STATUS: success"
        dump_log "$log"
        return
    fi
    if ! assert_result "$log" "TOKEN" \
       || ! assert_result "$log" "FINGERPRINT" \
       || ! assert_result "$log" "PORT" "8765"; then
        fail "test_happy_path[$label]: missing one or more RESULT_* lines"
        dump_log "$log"
        return
    fi

    # systemctl --user verification needs XDG_RUNTIME_DIR exported in this fresh
    # docker exec session (PAM doesn't run in non-interactive exec).
    if ! docker exec --env "XDG_RUNTIME_DIR=/run/user/0" "$container" \
            systemctl --user is-active nodeble-api-server.service >/dev/null 2>&1; then
        fail "test_happy_path[$label]: STATUS: success but systemd service not active"
        dump_log "$log"
        return
    fi

    pass "test_happy_path[$label]"
}

test_idempotent_rerun() {
    local label="$1"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_idempotent_rerun[$label]: NODEBLE_TEST_PAT env not set"
        return
    fi
    if [ "$label" = "debian-12" ]; then
        skip "test_idempotent_rerun[debian-12]: HOLD downstream of test_happy_path[debian-12]"
        return
    fi
    local container="bootstrap-test-happy-$label"
    if ! container_running "$container"; then
        skip "test_idempotent_rerun[$label]: container missing (test_happy_path failed?)"
        return
    fi

    info "test_idempotent_rerun[$label]: 2nd run → STATUS: already_installed"
    local log="$LOG_DIR/happy-$label-rerun.log"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    if assert_status "$log" "already_installed"; then
        pass "test_idempotent_rerun[$label]"
    else
        fail "test_idempotent_rerun[$label]: expected STATUS: already_installed"
        dump_log "$log"
    fi
}

test_uninstall_reinstall() {
    local label="$1"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_uninstall_reinstall[$label]: NODEBLE_TEST_PAT env not set"
        return
    fi
    if [ "$label" = "debian-12" ]; then
        skip "test_uninstall_reinstall[debian-12]: HOLD downstream of test_happy_path[debian-12]"
        return
    fi
    local container="bootstrap-test-happy-$label"
    if ! container_running "$container"; then
        skip "test_uninstall_reinstall[$label]: container missing"
        return
    fi

    info "test_uninstall_reinstall[$label]: clean state + reinstall → STATUS: success"
    local log="$LOG_DIR/happy-$label-reinstall.log"

    docker exec "$container" bash -c '
        systemctl --user stop nodeble-api-server.service 2>/dev/null || true
        systemctl --user disable nodeble-api-server.service 2>/dev/null || true
        rm -rf "$HOME/projects/nodeble-api-server" "$HOME/.nodeble-api"
        rm -f "$HOME/.config/systemd/user/nodeble-api-server.service"
        systemctl --user daemon-reload 2>/dev/null || true
    ' >/dev/null 2>&1 || true

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh > "$log" 2>&1 || true

    if assert_status "$log" "success"; then
        pass "test_uninstall_reinstall[$label]"
    else
        fail "test_uninstall_reinstall[$label]: expected STATUS: success on reinstall"
        dump_log "$log"
    fi

    # Cleanup: this is the last test for this distro, can drop the container
    docker rm -f "$container" >/dev/null 2>&1 || true
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
    rm -f "$LOG_DIR"/*.log 2>/dev/null || true

    info "test_bootstrap.sh starting (5/6 SGT Phase B.1 Session 2 partial)"
    info "bootstrap.sh: $BOOTSTRAP_SH ($(wc -l < "$BOOTSTRAP_SH") lines)"
    info ""
    info "=== Failure-mode tests (greenlit by 协作总监 5/6) ==="
    test_unsupported_os
    test_requires_sudo
    test_network_none
    test_github_token_missing
    test_pat_redacted_in_error_output
    info ""
    info "=== Happy-path tests (need NODEBLE_TEST_PAT env) ==="
    local entry label image
    for entry in "${HAPPY_DISTROS[@]}"; do
        label="${entry%%|*}"
        image="${entry#*|}"
        test_happy_path "$label" "$image"
        test_idempotent_rerun "$label"
        test_uninstall_reinstall "$label"
    done

    info ""
    info "=== Summary ==="
    info "PASS: $PASS"
    info "FAIL: $FAIL"
    info "SKIP: $SKIP"

    [ "$FAIL" -eq 0 ]
}

main "$@"
