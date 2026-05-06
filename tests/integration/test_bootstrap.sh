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
    docker run -d --name "$name" --privileged \
        --tmpfs /run --tmpfs /run/lock \
        -v /sys/fs/cgroup:/sys/fs/cgroup:ro \
        "$image" /sbin/init >/dev/null
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
# Happy-path test stubs — HOLD pending CTO arbitration
# (private-repo blocker on Holycrabeth/nodeble-api-server; 5/6 SGT)
#
# When CTO ratifies one of Options 1/2/3/4, fill in:
#   - Option 1 (public repo):       no test code change; clone-repo just works
#   - Option 2 (--github-token):    pass token via env to bootstrap.sh invocation
#   - Option 3 (release-tarball):   verify curl + tar -xz path; assert tarball checksum
#   - Option 4 (Mac SCP delivery):  pre-stage source via docker cp to mimic SCP
# ──────────────────────────────────────────────────────────────────
test_happy_path() {
    local label="$1"
    skip "test_happy_path[$label]: HOLD pending CTO option choice on private-repo blocker"
}

test_idempotent_rerun() {
    local label="$1"
    skip "test_idempotent_rerun[$label]: HOLD (downstream of test_happy_path)"
}

test_uninstall_reinstall() {
    local label="$1"
    skip "test_uninstall_reinstall[$label]: HOLD (downstream of test_happy_path)"
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
    info ""
    info "=== Happy-path tests (HOLD pending CTO option choice) ==="
    local entry label
    for entry in "${HAPPY_DISTROS[@]}"; do
        label="${entry%%|*}"
        test_happy_path "$label"
        test_idempotent_rerun "$label"
        test_uninstall_reinstall "$label"
    done

    info ""
    info "=== Summary ==="
    info "PASS: $PASS"
    info "FAIL: $FAIL"
    info "SKIP: $SKIP (held; resume on CTO ack of Option 1/2/3/4)"

    [ "$FAIL" -eq 0 ]
}

main "$@"
