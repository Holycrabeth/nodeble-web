#!/usr/bin/env bash
# tests/integration/test_bootstrap.sh — Path C Phase B.1 acceptance tests
# Per CTO spec §9 (~/projects/cto/reviews/2026-05-05-bootstrap-sh-design.md).
#
# Status (5/6 SGT Session 2 ship — CEO Option 1 ratified, Debian 12 dropped):
#   - Failure-mode tests:  rocky-9 + debian-12 (unsupported_os) + sudo-missing
#                          + network-none + github-token-missing + pat-redacted
#   - Happy-path tests:    Ubuntu 22.04 + Ubuntu 24.04 only
#
# Spec §9.2 referenced `centos:9` (deprecated on Docker Hub) → `rockylinux:9`.
# `debian:12` added to unsupported_os family per CEO 5/6 Option 1 ratification
# (bookworm + bookworm-backports lack python3.12).

set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOOTSTRAP_SH="$REPO_ROOT/bootstrap.sh"
LOG_DIR="$SCRIPT_DIR/.logs"

# Distros for happy-path matrix — systemd-enabled fixtures.
# Debian 12 dropped per CEO 5/6 Option 1 (bookworm lacks python3.12);
# verified via `unsupported_os` failure-mode test below instead.
HAPPY_DISTROS=(
    "ubuntu-22|jrei/systemd-ubuntu:22.04"
    "ubuntu-24|jrei/systemd-ubuntu:24.04"
)

# Distros for python-install fallback verification (Yongtao 5/14 P0
# T-20260514-160943 — non-LTS Ubuntu fallback, mirrors PR #9
# nodeble-api-server@9950b0f). Plain containers (NOT systemd-enabled);
# bootstrap dies later at enable-linger (no systemd) but `STEP:
# python-install ✓` marker is the gate. Tests all 3 supported Ubuntu
# release paths:
#   ubuntu:22.04 → Attempt 3 (deadsnakes, system python3=3.10)
#   ubuntu:24.04 → Attempt 1 (main repos, python3.12 in 24.04 main)
#   ubuntu:25.10 → Attempt 2 (system python3=3.13 symlinked, NEW)
# debian:12 excluded — intentionally rejected at os-check per CEO 5/6
# Option 1 (covered by test_unsupported_os).
PYINSTALL_DISTROS=(
    "ubuntu-22|ubuntu:22.04"
    "ubuntu-24|ubuntu:24.04"
    "ubuntu-25|ubuntu:25.10"
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

# Phase B.2 contract: --mode required, --config required (unless --dry-run).
# Helper writes a minimal single-bot bundle for tests that exercise full flow.
write_min_single_bot_bundle() {
    local container="$1"
    docker exec -i "$container" bash -c 'cat > /tmp/min-bundle.json' <<'EOF'
{"module":"bootstrap-bundle","config_version":1,"mode":"single-bot","api_server":{"module":"api-server","config_version":1}}
EOF
}

# ──────────────────────────────────────────────────────────────────
# Failure-mode test 1: unsupported OS family
# - rockylinux:9 (RHEL-derivative; substitute for centos:9 deprecated in Docker Hub)
# - debian:12 (CEO 5/6 Option 1 — Debian dropped from supported OS)
# Both must fail at os-check with STATUS: failure: unsupported_os
# ──────────────────────────────────────────────────────────────────
test_unsupported_os() {
    info "test_unsupported_os: rockylinux:9 + debian:12 must both STATUS: failure: unsupported_os"
    local distros=(
        "rocky-9|rockylinux:9"
        "debian-12|debian:12"
    )
    local entry label image container log fails=0
    for entry in "${distros[@]}"; do
        label="${entry%%|*}"
        image="${entry#*|}"
        container="bootstrap-test-unsupp-$label"
        log="$LOG_DIR/unsupported-os-$label.log"

        start_plain_container "$container" "$image"
        docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
        # --mode + --dry-run: dry-run probes os-check (which fails with unsupported_os
        # before reaching anything that needs --config)
        docker exec "$container" bash /tmp/bootstrap.sh --mode single-bot --dry-run > "$log" 2>&1 || true

        if ! assert_status "$log" "failure: unsupported_os"; then
            echo "  [$label] expected 'STATUS: failure: unsupported_os' in $log" >&2
            dump_log "$log"
            fails=$((fails + 1))
        fi
        docker rm -f "$container" >/dev/null
    done

    if [ "$fails" -eq 0 ]; then
        pass "test_unsupported_os (rocky-9 + debian-12)"
    else
        fail "test_unsupported_os: $fails sub-test(s) failed"
    fi
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
    docker exec --user testuser "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --dry-run > "$log" 2>&1 || true

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
    write_min_single_bot_bundle "$container"
    docker exec "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json > "$log" 2>&1 || true

    # Steps that touch the network (precise expected reasons; apt_prereqs_failed
    # added to set per Phase B.2 — apt-prereqs runs before python-install):
    local network_reasons='(apt_update_failed|apt_prereqs_failed|software_properties_install_failed|deadsnakes_ppa_failed|python_install_failed|git_clone_failed|git_update_failed)'
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
    # Phase B.2 bootstrap apt-installs git/jq/etc itself (step_apt_prereqs); fixture
    # only needs sudo + iproute2 + ca-certs (NOT python3.12 — bootstrap installs).
    docker exec "$container" apt-get update -qq >/dev/null 2>&1 || true
    docker exec "$container" apt-get install -qq -y sudo iproute2 ca-certificates >/dev/null 2>&1 || true
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    write_min_single_bot_bundle "$container"

    # Run WITHOUT GITHUB_TOKEN env (deliberately not setting it)
    docker exec "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json > "$log" 2>&1 || true

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
    docker exec "$container" apt-get update -qq >/dev/null 2>&1 || true
    docker exec "$container" apt-get install -qq -y sudo iproute2 ca-certificates >/dev/null 2>&1 || true
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    write_min_single_bot_bundle "$container"

    # Run with INVALID PAT — clone will fail (401); verify PAT not leaked anywhere
    docker exec --env "GITHUB_TOKEN=$fake_pat" "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json > "$log" 2>&1 || true

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

    info "test_happy_path[$label]: fresh install on $image → STATUS: success + RESULT_*"
    local container="bootstrap-test-happy-$label"
    local log="$LOG_DIR/happy-$label-fresh.log"

    start_systemd_container "$container" "$image"
    docker exec "$container" apt-get update -qq >/dev/null 2>&1 || true
    docker exec "$container" apt-get install -qq -y sudo iproute2 ca-certificates >/dev/null 2>&1 || true
    docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
    write_min_single_bot_bundle "$container"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json \
        > "$log" 2>&1 || true

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
    # Canonical key `RESULT_BEARER_TOKEN` per CTO Q4 ack 2026-05-11 (Option A rename).
    if ! assert_result "$log" "BEARER_TOKEN" \
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
    local container="bootstrap-test-happy-$label"
    if ! container_running "$container"; then
        skip "test_idempotent_rerun[$label]: container missing (test_happy_path failed?)"
        return
    fi

    info "test_idempotent_rerun[$label]: 2nd run → STATUS: already_installed"
    local log="$LOG_DIR/happy-$label-rerun.log"

    docker exec --env "GITHUB_TOKEN=$NODEBLE_TEST_PAT" "$container" \
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json \
        > "$log" 2>&1 || true

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
        bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json \
        > "$log" 2>&1 || true

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
# Contract test (CTO Q4 ack 2026-05-11 Option A rename): bootstrap.sh
# stdout MUST emit `RESULT_BEARER_TOKEN: <uuid-v4>` line on happy-path
# install success. UUID v4 = 32 hex digits + 4 hyphens in 8-4-4-4-12 grouping
# (matches python uuid.uuid4() output used in step_generate_api_token).
# Mac wizard Journey 1 SetupWizard.tsx parser regex
# `^RESULT_BEARER_TOKEN:\s*(.+)$` consumes this line.
# ──────────────────────────────────────────────────────────────────
# ──────────────────────────────────────────────────────────────────
# Test: python-install fallback succeeds on each supported Ubuntu distro
# (Yongtao 5/14 P0 T-20260514-160943 — non-LTS support, mirrors PR #9
# nodeble-api-server@9950b0f test 6). Plain containers + gate on
# `STEP: python-install ✓` marker. Bootstrap dies later at enable-linger
# (no systemd in plain containers) — that's expected.
#
# Expected fallback per distro:
#   ubuntu-22 → Attempt 3 (deadsnakes PPA; system python3=3.10 < 3.12)
#   ubuntu-24 → Attempt 1 (main repos; python3.12 in 24.04 main)
#   ubuntu-25 → Attempt 2 (system python3=3.13 symlinked; NEW path,
#               deadsnakes returns 404 on questing)
# ──────────────────────────────────────────────────────────────────
test_python_install() {
    info "test_python_install: step_python_install ✓ on 3 Ubuntu distros (mirror PR #9 api-server@9950b0f)"
    local entry label image container log rc detail fails=0
    for entry in "${PYINSTALL_DISTROS[@]}"; do
        label="${entry%%|*}"
        image="${entry#*|}"
        container="bootstrap-test-pyinstall-$label"
        log="$LOG_DIR/python-install-$label.log"

        start_plain_container "$container" "$image"
        # Pre-install tooling. software-properties-common needed by Attempt 3
        # (deadsnakes) — provides add-apt-repository on minimal images that
        # may not include it. `-e DEBIAN_FRONTEND=noninteractive` prevents
        # apt from prompting on tzdata / libc6 service restart (would
        # otherwise hang docker exec waiting for stdin — PR #9 first CI run
        # cancellation root cause).
        docker exec -e DEBIAN_FRONTEND=noninteractive "$container" \
            apt-get update -y >/dev/null 2>&1 || true
        docker exec -e DEBIAN_FRONTEND=noninteractive "$container" \
            apt-get install -y curl git openssl sudo software-properties-common \
            >/dev/null 2>&1 || true

        docker cp "$BOOTSTRAP_SH" "$container:/tmp/bootstrap.sh" >/dev/null
        write_min_single_bot_bundle "$container"

        # `timeout 600` defensive cap. Bootstrap dies at enable-linger
        # downstream (no systemd in plain containers); we gate on
        # python-install ✓ marker, not overall exit. --mode single-bot
        # + min bundle avoids needing PAT (api-server clone happens
        # AFTER python-install, never reached due to enable-linger fail).
        set +e
        timeout 600 docker exec -e DEBIAN_FRONTEND=noninteractive "$container" \
            bash /tmp/bootstrap.sh --mode single-bot --config /tmp/min-bundle.json \
            > "$log" 2>&1
        rc=$?
        set -e

        if assert_step_ok "$log" "python-install"; then
            detail=$(grep "^STEP: python-install ✓" "$log" | head -1 | sed 's|^STEP: python-install ✓ *||')
            pass "test_python_install[$label] ($detail)"
        elif [ "$rc" -eq 124 ]; then
            fail "test_python_install[$label]: bootstrap.sh exceeded 600s timeout"
            dump_log "$log"
            fails=$((fails + 1))
        else
            fail "test_python_install[$label]: STEP: python-install ✓ not found (rc=$rc)"
            dump_log "$log"
            fails=$((fails + 1))
        fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    done
}

test_bootstrap_emits_bearer_token_uuid_v4() {
    info "test_bootstrap_emits_bearer_token_uuid_v4: canonical RESULT_BEARER_TOKEN UUID v4 contract"
    if [ -z "${NODEBLE_TEST_PAT:-}" ]; then
        skip "test_bootstrap_emits_bearer_token_uuid_v4: NODEBLE_TEST_PAT not set"
        return
    fi
    # Reuse test_happy_path[ubuntu-22]'s log (runs earlier in same suite). No need
    # for own container — contract assertion is pure log-grep.
    local log="$LOG_DIR/happy-ubuntu-22-fresh.log"
    if [ ! -r "$log" ]; then
        skip "test_bootstrap_emits_bearer_token_uuid_v4: prereq log $log missing (test_happy_path[ubuntu-22] didn't run)"
        return
    fi
    # Strict UUID v4 shape: 8-4-4-4-12 hex grouping; python uuid.uuid4() lowercase output
    local uuid_re='^RESULT_BEARER_TOKEN: [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    if grep -qE "$uuid_re" "$log"; then
        pass "test_bootstrap_emits_bearer_token_uuid_v4"
    else
        fail "test_bootstrap_emits_bearer_token_uuid_v4: no RESULT_BEARER_TOKEN UUID v4 line in $log"
        dump_log "$log"
    fi
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
    test_python_install
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
    info "=== Contract test (CTO Q4 ack 2026-05-11 — Option A rename) ==="
    test_bootstrap_emits_bearer_token_uuid_v4

    info ""
    info "=== Summary ==="
    info "PASS: $PASS"
    info "FAIL: $FAIL"
    info "SKIP: $SKIP"

    [ "$FAIL" -eq 0 ]
}

main "$@"
