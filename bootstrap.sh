#!/usr/bin/env bash
# NODEBLE bootstrap.sh — Path C Phase B installer for nodeble-api-server.
# https://nodeble.app/bootstrap.sh
# Spec: ~/projects/cto/reviews/2026-05-05-bootstrap-sh-design.md (CTO 2026-05-05).
#
# Usage:
#   curl -sSL https://nodeble.app/bootstrap.sh | bash
#   curl -sSL https://nodeble.app/bootstrap.sh | bash -s -- --verbose
#   curl -sSL https://nodeble.app/bootstrap.sh | bash -s -- --dry-run
#
# Stdout:  STEP / STATUS / RESULT_* lines only (parsed by Mac install_runner)
# Stderr:  diagnostic output (verbose mode streams everything here)
# Exits:   0 success | 0 already_installed | 0 dry_run_ok | 1 failure | 2 args

set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────
readonly BOOTSTRAP_VERSION="0.1.0"
readonly REPO_PATH="Holycrabeth/nodeble-api-server"
readonly REPO_DIR="$HOME/projects/nodeble-api-server"
readonly NODEBLE_API_HOME="$HOME/.nodeble-api"
readonly CONFIG_DIR="$NODEBLE_API_HOME/config"
readonly TLS_DIR="$NODEBLE_API_HOME/tls"
readonly CONFIG_YAML="$CONFIG_DIR/api.yaml"
readonly CERT_PATH="$TLS_DIR/cert.pem"
readonly KEY_PATH="$TLS_DIR/key.pem"
readonly FINGERPRINT_PATH="$TLS_DIR/fingerprint.txt"
readonly SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
readonly SYSTEMD_UNIT="$SYSTEMD_USER_DIR/nodeble-api-server.service"
readonly SERVICE_NAME="nodeble-api-server.service"
readonly DEFAULT_PORT="${NODEBLE_API_PORT:-8765}"
readonly NODEBLE_HOSTNAME_SAN="${NODEBLE_HOSTNAME:-}"
readonly MIN_DISK_FREE_MB=500
readonly STARTUP_WAIT_SECS=10
# Resolve username — $USER is unset in non-interactive docker exec / SSH env.
readonly USER_NAME="${USER:-$(id -un)}"

# ──────────────────────────────────────────────────────────────────
# Mutable state
# ──────────────────────────────────────────────────────────────────
CURRENT_STEP=""
BOOTSTRAP_TOKEN=""
BOOTSTRAP_FINGERPRINT=""
PUBLIC_IP=""
VERBOSE=false
DRY_RUN=false
OS_ID=""
OS_VERSION_ID=""

# ──────────────────────────────────────────────────────────────────
# Output helpers — stdout reserved for STEP/STATUS/RESULT lines
# ──────────────────────────────────────────────────────────────────
emit_step()      { echo "STEP: $1"; }
emit_step_ok()   { echo "STEP: $1 ✓ ${2:-}"; }
emit_step_fail() { echo "STEP: $1 ✗ $2"; }
emit_status()    { echo "STATUS: $1"; }
emit_result()    { echo "RESULT_$1: $2"; }

die() {
    emit_step_fail "${CURRENT_STEP:-bootstrap}" "$1"
    emit_status "failure: $1"
    exit 1
}

run_step() {
    CURRENT_STEP="$1"
    emit_step "$CURRENT_STEP"
    shift
    if "$@"; then
        return 0
    fi
    die "${CURRENT_STEP}_failed"
}

# Run a noisy command. Output → stderr unless --verbose.
quiet() {
    if [ "$VERBOSE" = "true" ]; then
        "$@"
    else
        "$@" >&2 2>&1
    fi
}

# Run a command with sudo only if not already root.
maybe_sudo() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ──────────────────────────────────────────────────────────────────
# CLI args
# ──────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
NODEBLE bootstrap.sh v${BOOTSTRAP_VERSION}
Installs nodeble-api-server on a fresh Ubuntu 22.04+ / Debian 12+ VPS.

Usage: bash bootstrap.sh [--verbose] [--dry-run]

Flags:
  --verbose   Stream all command output to stdout (default: STEP/STATUS only)
  --dry-run   Run probes only; skip side-effecting operations
  -h, --help  Show this message

Environment:
  NODEBLE_HOSTNAME   Optional DNS hostname added to TLS SAN
  NODEBLE_API_PORT   Override default port 8765
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --verbose) VERBOSE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                echo "Unknown flag: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

# ──────────────────────────────────────────────────────────────────
# Idempotency helpers
# ──────────────────────────────────────────────────────────────────
probe_existing_install() {
    [ -x "$REPO_DIR/.venv/bin/python" ] || return 1
    [ -r "$CONFIG_YAML" ] || return 1
    systemctl --user is-active "$SERVICE_NAME" >/dev/null 2>&1 || return 1
    return 0
}

read_existing_token() {
    [ -x "$REPO_DIR/.venv/bin/python" ] || return 1
    [ -r "$CONFIG_YAML" ] || return 1
    local token
    token=$("$REPO_DIR/.venv/bin/python" - "$CONFIG_YAML" 2>/dev/null <<'PY' || true
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
    for t in cfg.get("auth", {}).get("valid_tokens", []):
        if t.get("label") == "bootstrap-initial":
            print(t.get("token", ""))
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
)
    if [ -n "$token" ]; then
        echo "$token"
        return 0
    fi
    return 1
}

read_existing_port() {
    if [ -x "$REPO_DIR/.venv/bin/python" ] && [ -r "$CONFIG_YAML" ]; then
        local port
        port=$("$REPO_DIR/.venv/bin/python" - "$CONFIG_YAML" 2>/dev/null <<'PY' || true
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
    print(cfg.get("server", {}).get("port", 8765))
except Exception:
    print(8765)
PY
)
        if [ -n "$port" ]; then
            echo "$port"
            return 0
        fi
    fi
    echo "$DEFAULT_PORT"
}

read_existing_fingerprint() {
    if [ -r "$FINGERPRINT_PATH" ]; then
        cat "$FINGERPRINT_PATH"
        return 0
    fi
    if [ -r "$CERT_PATH" ]; then
        openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha256 2>/dev/null \
            | cut -d= -f2 || true
        return 0
    fi
    if [ -x "$REPO_DIR/.venv/bin/python" ] && [ -r "$CONFIG_YAML" ]; then
        local fp
        fp=$("$REPO_DIR/.venv/bin/python" - "$CONFIG_YAML" 2>/dev/null <<'PY' || true
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f) or {}
    fp = cfg.get("tls", {}).get("fingerprint", "")
    if fp:
        print(fp)
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
)
        if [ -n "$fp" ]; then
            echo "$fp"
            return 0
        fi
    fi
    return 1
}

# ──────────────────────────────────────────────────────────────────
# Step 0 — idempotency probe
# ──────────────────────────────────────────────────────────────────
step_idempotency_probe() {
    if probe_existing_install; then
        local token port fingerprint
        token=$(read_existing_token || true)
        port=$(read_existing_port)
        fingerprint=$(read_existing_fingerprint || true)
        emit_step_ok "idempotency-probe" "api-server already installed + running"
        if [ -n "$token" ]; then
            emit_result TOKEN "$token"
        fi
        if [ -n "$fingerprint" ]; then
            emit_result FINGERPRINT "$fingerprint"
        fi
        emit_result PORT "$port"
        emit_status "already_installed"
        exit 0
    fi
    emit_step_ok "idempotency-probe" "fresh install (no existing setup detected)"
}

# ──────────────────────────────────────────────────────────────────
# Step 1 — sudo probe (per spec §11 question 1)
# ──────────────────────────────────────────────────────────────────
step_sudo_probe() {
    if [ "$EUID" -eq 0 ]; then
        emit_step_ok "sudo-probe" "running as root"
        return 0
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        emit_step_ok "sudo-probe" "passwordless sudo available"
        return 0
    fi
    die "requires_sudo"
}

# ──────────────────────────────────────────────────────────────────
# Step 2 — OS check
# ──────────────────────────────────────────────────────────────────
step_os_check() {
    if [ ! -r /etc/os-release ]; then
        die "unsupported_os: /etc/os-release not readable"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    local major="${OS_VERSION_ID%%.*}"
    case "$OS_ID" in
        ubuntu)
            if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 22 ]; then
                die "ubuntu_too_old: $OS_VERSION_ID (need 22.04+)"
            fi
            ;;
        debian)
            if ! [[ "$major" =~ ^[0-9]+$ ]] || [ "$major" -lt 12 ]; then
                die "debian_too_old: $OS_VERSION_ID (need 12+)"
            fi
            ;;
        *)
            die "unsupported_os: $OS_ID (need ubuntu|debian)"
            ;;
    esac
    emit_step_ok "os-check" "$OS_ID $OS_VERSION_ID"
}

# ──────────────────────────────────────────────────────────────────
# Disk space (per spec §7.3)
# ──────────────────────────────────────────────────────────────────
step_disk_check() {
    local free_mb
    free_mb=$(df -m "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$free_mb" ] || [ "$free_mb" -lt "$MIN_DISK_FREE_MB" ]; then
        die "insufficient_disk: ${free_mb:-?}M free, need ${MIN_DISK_FREE_MB}M"
    fi
    emit_step_ok "disk-space-check" "${free_mb}M free at $HOME"
}

# ──────────────────────────────────────────────────────────────────
# Step 3 — Python 3.12+
# ──────────────────────────────────────────────────────────────────
step_python_install() {
    # Ensure python3.12 + venv + dev all installed (binary alone insufficient —
    # Ubuntu 24.04 ships python3.12 in main but python3.12-venv as separate pkg
    # that may be absent on minimal images). apt-get install is idempotent.
    # Ubuntu 22.04 main lacks python3.12 → deadsnakes PPA fallback.
    # Debian 12 main lacks python3.12 → bookworm-backports.
    quiet maybe_sudo apt-get update -y || die "apt_update_failed"

    if [ "$OS_ID" = "ubuntu" ]; then
        if ! quiet maybe_sudo apt-get install -y python3.12 python3.12-venv python3.12-dev; then
            quiet maybe_sudo apt-get install -y software-properties-common \
                || die "software_properties_install_failed"
            quiet maybe_sudo add-apt-repository -y ppa:deadsnakes/ppa \
                || die "deadsnakes_ppa_failed"
            quiet maybe_sudo apt-get update -y || die "apt_update_failed"
            quiet maybe_sudo apt-get install -y python3.12 python3.12-venv python3.12-dev \
                || die "python_install_failed"
        fi
    elif [ "$OS_ID" = "debian" ]; then
        if ! grep -rq "bookworm-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
            echo "deb http://deb.debian.org/debian bookworm-backports main" \
                | maybe_sudo tee /etc/apt/sources.list.d/bookworm-backports.list >/dev/null
            quiet maybe_sudo apt-get update -y || die "apt_update_failed"
        fi
        quiet maybe_sudo apt-get install -y -t bookworm-backports \
                python3.12 python3.12-venv python3.12-dev \
            || die "python_install_failed"
    fi

    if ! command -v python3.12 >/dev/null 2>&1; then
        die "python_install_failed"
    fi
    local v
    v=$(python3.12 --version 2>&1 | awk '{print $2}')
    emit_step_ok "python-install" "Python $v ready"
}

# ──────────────────────────────────────────────────────────────────
# Step 4 — loginctl enable-linger
# ──────────────────────────────────────────────────────────────────
step_enable_linger() {
    quiet loginctl enable-linger "$USER_NAME" || die "enable_linger_failed"
    if loginctl show-user "$USER_NAME" 2>/dev/null | grep -q "Linger=yes"; then
        # Export XDG_RUNTIME_DIR for subsequent systemctl --user calls.
        # PAM (pam_systemd) sets this in interactive sessions; non-interactive
        # SSH / docker exec environments do not. Linger ensures /run/user/<uid>
        # persists, so this directory exists from this point on.
        local uid
        uid=$(id -u)
        export XDG_RUNTIME_DIR="/run/user/$uid"
        emit_step_ok "enable-linger" "linger active for $USER_NAME, XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
        return 0
    fi
    die "enable_linger_verify_failed"
}

# ──────────────────────────────────────────────────────────────────
# Step 5 — clone repo (PAT-aware, Option 2 per CTO 2026-05-06 dispatch
# `bootstrap-pat-aware-clone-dispatch.md`)
# ──────────────────────────────────────────────────────────────────

# Token-authenticated clone of a private NODEBLE repo using fine-grained PAT
# delivered via $GITHUB_TOKEN env var. PAT must have repo:read scope.
# Mac app injects via SSH env at install time; direct CLI use requires
# `export GITHUB_TOKEN=<pat>` before invocation.
clone_private_repo() {
    local repo_path="$1"
    local target_dir="$2"

    if [ -z "${GITHUB_TOKEN:-}" ]; then
        echo "ERROR: GITHUB_TOKEN env var not set." >&2
        echo "  Private NODEBLE repo clone requires fine-grained PAT with repo:read scope." >&2
        echo "  Mac app delivers via SSH env at install time." >&2
        echo "  Direct CLI use: export GITHUB_TOKEN=<your_pat> before running bootstrap.sh" >&2
        return 1
    fi

    local auth_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_path}.git"

    mkdir -p "$(dirname "$target_dir")"

    # Pipe through sed to redact PAT from any error output (defensive vs accidental log leak).
    # In VERBOSE mode, redacted output goes to stdout (human-debug); else stderr (parser-clean).
    if [ "$VERBOSE" = "true" ]; then
        git clone "$auth_url" "$target_dir" 2>&1 | sed "s|${GITHUB_TOKEN}|<REDACTED>|g"
    else
        git clone "$auth_url" "$target_dir" 2>&1 | sed "s|${GITHUB_TOKEN}|<REDACTED>|g" >&2
    fi
    local rc="${PIPESTATUS[0]}"

    if [ "$rc" -ne 0 ]; then
        echo "ERROR: git clone failed for ${repo_path} (exit $rc)." >&2
        echo "  Verify GITHUB_TOKEN has repo:read scope on ${repo_path}." >&2
        return "$rc"
    fi

    # Defensive: drop any cached credential helper config that may have stored PAT.
    git -C "$target_dir" config --unset-all credential.helper 2>/dev/null || true

    return 0
}

step_clone_repo() {
    if [ -d "$REPO_DIR/.git" ]; then
        # Update path: existing clone's stored remote URL retains x-access-token PAT
        # (acceptable on-disk persistence trade-off — repo:read scope, owner-readable
        # mode 0644 .git/config; flagged for CTO post-verify discussion).
        ( cd "$REPO_DIR" \
            && quiet git fetch origin \
            && quiet git reset --hard origin/main ) \
            || die "git_update_failed"
    else
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            die "missing_github_token"
        fi
        clone_private_repo "$REPO_PATH" "$REPO_DIR" || die "git_clone_failed"
    fi
    local head
    head=$(cd "$REPO_DIR" && git log -1 --format='%h %s' 2>/dev/null || echo "unknown")
    emit_step_ok "clone-repo" "$REPO_DIR @ $head"
}

# ──────────────────────────────────────────────────────────────────
# Step 6 — venv create
# ──────────────────────────────────────────────────────────────────
step_venv_create() {
    if [ -x "$REPO_DIR/.venv/bin/python" ]; then
        emit_step_ok "venv-create" "$REPO_DIR/.venv already exists"
        return 0
    fi
    quiet python3.12 -m venv "$REPO_DIR/.venv" || die "venv_create_failed"
    emit_step_ok "venv-create" "$REPO_DIR/.venv"
}

# ──────────────────────────────────────────────────────────────────
# Step 7 — pip install
# ──────────────────────────────────────────────────────────────────
step_pip_install() {
    quiet "$REPO_DIR/.venv/bin/pip" install --upgrade pip wheel \
        || die "pip_upgrade_failed"
    quiet "$REPO_DIR/.venv/bin/pip" install -e "$REPO_DIR" \
        || die "pip_install_failed"
    emit_step_ok "pip-install" "package installed"
}

# ──────────────────────────────────────────────────────────────────
# Step 8 — generate API token (per spec §2.1; §3.5 also generates here)
# ──────────────────────────────────────────────────────────────────
step_generate_api_token() {
    local existing
    existing=$(read_existing_token || true)
    if [ -n "$existing" ]; then
        BOOTSTRAP_TOKEN="$existing"
        emit_step_ok "generate-api-token" "preserved existing bootstrap-initial token"
        return 0
    fi
    BOOTSTRAP_TOKEN=$("$REPO_DIR/.venv/bin/python" -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)
    [ -n "$BOOTSTRAP_TOKEN" ] || die "token_generation_failed"
    emit_step_ok "generate-api-token"
}

# ──────────────────────────────────────────────────────────────────
# Step 9 — TLS cert with SAN (per spec §3.4 + amendment A2)
# ──────────────────────────────────────────────────────────────────
detect_public_ip() {
    local services=("ifconfig.me" "icanhazip.com" "ipify.org")
    local svc ip
    for svc in "${services[@]}"; do
        ip=$(curl -s --max-time 5 "https://$svc" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

step_generate_tls_cert() {
    mkdir -p "$TLS_DIR"
    chmod 700 "$TLS_DIR"

    if [ -r "$CERT_PATH" ] && [ -r "$KEY_PATH" ] \
       && openssl x509 -in "$CERT_PATH" -noout -checkend 0 >/dev/null 2>&1; then
        BOOTSTRAP_FINGERPRINT=$(openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha256 \
                                | cut -d= -f2)
        echo "$BOOTSTRAP_FINGERPRINT" > "$FINGERPRINT_PATH"
        chmod 600 "$FINGERPRINT_PATH"
        emit_step_ok "generate-tls-cert" "existing cert preserved (not expired)"
        return 0
    fi

    PUBLIC_IP=$(detect_public_ip || true)
    local san="DNS:localhost,IP:127.0.0.1"
    if [ -n "$PUBLIC_IP" ]; then
        san="$san,IP:$PUBLIC_IP"
    fi
    if [ -n "$NODEBLE_HOSTNAME_SAN" ]; then
        san="$san,DNS:$NODEBLE_HOSTNAME_SAN"
    fi

    quiet openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
        -keyout "$KEY_PATH" \
        -out "$CERT_PATH" \
        -subj "/CN=NODEBLE-API-SERVER" \
        -addext "subjectAltName=$san" \
        || die "cert_generation_failed"

    chmod 600 "$KEY_PATH" "$CERT_PATH"

    BOOTSTRAP_FINGERPRINT=$(openssl x509 -in "$CERT_PATH" -noout -fingerprint -sha256 \
                            | cut -d= -f2)
    echo "$BOOTSTRAP_FINGERPRINT" > "$FINGERPRINT_PATH"
    chmod 600 "$FINGERPRINT_PATH"

    emit_step_ok "generate-tls-cert" "SAN: $san"
}

# ──────────────────────────────────────────────────────────────────
# Step 10 — write api.yaml (per spec §3.5 + amendment A3)
# ──────────────────────────────────────────────────────────────────
step_write_api_yaml() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    if [ -r "$CONFIG_YAML" ]; then
        local existing
        existing=$(read_existing_token || true)
        if [ -n "$existing" ] && [ "$existing" = "$BOOTSTRAP_TOKEN" ]; then
            emit_step_ok "write-api-yaml" "$CONFIG_YAML already matches generated token"
            return 0
        fi
    fi

    cat > "$CONFIG_YAML" <<EOF
# Generated by bootstrap.sh v${BOOTSTRAP_VERSION} on $(date -Iseconds)
server:
  host: 0.0.0.0
  port: ${DEFAULT_PORT}
auth:
  valid_tokens:
    - token: ${BOOTSTRAP_TOKEN}
      label: bootstrap-initial
tls:
  cert_path: ${CERT_PATH}
  key_path: ${KEY_PATH}
  fingerprint: ${BOOTSTRAP_FINGERPRINT}
EOF
    chmod 600 "$CONFIG_YAML"
    emit_step_ok "write-api-yaml" "$CONFIG_YAML"
}

# ──────────────────────────────────────────────────────────────────
# Step 11 — systemd USER service install
# ──────────────────────────────────────────────────────────────────
step_systemd_install() {
    mkdir -p "$SYSTEMD_USER_DIR"
    cat > "$SYSTEMD_UNIT" <<'EOF'
[Unit]
Description=NODEBLE API Server (FastAPI sidecar for desktop app)
Documentation=https://github.com/Holycrabeth/nodeble-api-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/projects/nodeble-api-server
ExecStart=%h/projects/nodeble-api-server/.venv/bin/python -m nodeble_api_server
Restart=always
RestartSec=5
TimeoutStopSec=15
TimeoutStartSec=30
SuccessExitStatus=0 143
KillMode=control-group
KillSignal=SIGTERM

[Install]
WantedBy=default.target
EOF

    quiet systemctl --user daemon-reload || die "systemd_daemon_reload_failed"
    quiet systemctl --user enable "$SERVICE_NAME" || die "systemd_enable_failed"
    emit_step_ok "systemd-install" "$SERVICE_NAME enabled"
}

# ──────────────────────────────────────────────────────────────────
# Step 12 — systemd start + port-bind verification
# ──────────────────────────────────────────────────────────────────
step_systemd_start() {
    quiet systemctl --user restart "$SERVICE_NAME" || die "systemd_start_failed"

    local pid
    for _ in $(seq 1 "$STARTUP_WAIT_SECS"); do
        if ss -tlnp 2>/dev/null | grep -q ":${DEFAULT_PORT} "; then
            pid=$(systemctl --user show -p MainPID "$SERVICE_NAME" 2>/dev/null \
                  | cut -d= -f2)
            emit_step_ok "systemd-start" "PID ${pid:-?}, listening on 0.0.0.0:${DEFAULT_PORT}"
            return 0
        fi
        sleep 1
    done
    die "systemd_start_timeout"
}

# ──────────────────────────────────────────────────────────────────
# Main flow
# ──────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    # Set XDG_RUNTIME_DIR proactively so idempotency-probe (Step 0) can talk
    # to the user's systemd manager via `systemctl --user`. PAM normally sets
    # this in interactive logins; non-interactive SSH / docker exec do not.
    # Directory may not yet exist on a fresh box (linger not yet enabled);
    # systemctl --user fails gracefully → probe returns 1 → fresh-install path.
    local _uid
    _uid=$(id -u)
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$_uid}"

    run_step "idempotency-probe"  step_idempotency_probe
    run_step "sudo-probe"         step_sudo_probe
    run_step "os-check"           step_os_check
    run_step "disk-space-check"   step_disk_check

    if [ "$DRY_RUN" = "true" ]; then
        emit_status "dry_run_ok"
        exit 0
    fi

    run_step "python-install"     step_python_install
    run_step "enable-linger"      step_enable_linger
    run_step "clone-repo"         step_clone_repo
    # Security hygiene per Option 2 dispatch §1.2 — drop PAT from env before
    # any subprocess fan-out (pip, openssl, systemctl child processes).
    unset GITHUB_TOKEN
    run_step "venv-create"        step_venv_create
    run_step "pip-install"        step_pip_install
    run_step "generate-api-token" step_generate_api_token
    run_step "generate-tls-cert"  step_generate_tls_cert
    run_step "write-api-yaml"     step_write_api_yaml
    run_step "systemd-install"    step_systemd_install
    run_step "systemd-start"      step_systemd_start

    emit_result TOKEN       "$BOOTSTRAP_TOKEN"
    emit_result FINGERPRINT "$BOOTSTRAP_FINGERPRINT"
    emit_result PORT        "$DEFAULT_PORT"
    emit_status "success"
}

main "$@"
