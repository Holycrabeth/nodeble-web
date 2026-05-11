#!/usr/bin/env bash
# NODEBLE bootstrap.sh — Path C Phase B installer for nodeble-api-server.
# https://nodeble.app/bootstrap.sh
# Spec: ~/projects/cto/reviews/2026-05-05-bootstrap-sh-design.md (Phase B.1 — CTO 2026-05-05).
# Spec: ~/projects/cto/reviews/2026-05-09-bootstrap-sh-phase-b2-chain-spec.md (Phase B.2 chain — CTO 2026-05-09).
#
# Usage (Phase B.2):
#   curl -sSL https://nodeble.app/bootstrap.sh | GITHUB_TOKEN=<pat> bash -s -- \
#       --mode <multi-module|single-bot> --config <bundle.json> [--skip-tiger-test]
#
# Modes (per L1 §4 dual-deployment-mode enforcement):
#   multi-module   chain api-server → orchestrator → allocator (Tower / 茗茗 pattern)
#   single-bot     api-server only (YB pattern; allocator skipped per multi-module-only design)
#
# Stdout:  STEP / STATUS / RESULT_* lines only (parsed by Mac install_runner)
# Stderr:  diagnostic output (verbose mode streams everything here)
# Exits:   0 success | 0 already_installed | 0 dry_run_ok | 1 generic | 2 args
#          3 bundle_invalid | 11-14 per-step (see §7 of B.2 spec)

set -euo pipefail

# ──────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────
readonly BOOTSTRAP_VERSION="0.2.0"
readonly REPO_PATH="Holycrabeth/nodeble-api-server"
readonly REPO_DIR="$HOME/projects/nodeble-api-server"
# Phase B.2 chain extension — orch + allocator paths per spec §4
readonly ORCH_REPO_PATH="Holycrabeth/nodeble-orchestrator"
readonly ORCH_DIR="/opt/nodeble/orchestrator"
readonly ALLOC_REPO_PATH="Holycrabeth/nodeble-allocator"
readonly ALLOC_DIR="/opt/nodeble/allocator"
readonly ORCH_DEPLOY_LOG="/tmp/orch-deploy.log"
readonly ALLOC_DEPLOY_LOG="/tmp/alloc-deploy.log"
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
# Phase B.2 chain state
MODE=""
BUNDLE_CONFIG=""
SKIP_TIGER_TEST=false
TIGER_PROPERTIES_PATH=""
API_SERVER_RESULT=""   # "fresh" or "already_installed"
ORCH_RESULT=""         # "fresh" / "already_installed" / "skipped" (single-bot)
ALLOC_RESULT=""        # ditto
SAVED_PORT=""          # port emitted in final RESULT_PORT (from yaml or DEFAULT)
ORCH_NLV=""
ORCH_FLOOR=""
ORCH_RESERVE=""
ORCH_FRED_KEY=""

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

# Same as die() but with explicit exit code (per B.2 spec §7 exit codes 3, 11-14).
die_with_code() {
    local reason="$1" code="$2"
    emit_step_fail "${CURRENT_STEP:-bootstrap}" "$reason"
    emit_status "failure: $reason"
    exit "$code"
}

# Diagnostic info (stderr only, never on stdout — protocol contract).
emit_info() { echo "INFO: $*" >&2; }
emit_warn() { echo "WARN: $*" >&2; }

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
Installs NODEBLE infrastructure on a fresh Ubuntu 22.04+ VPS.

Usage:
  GITHUB_TOKEN=<pat> bash bootstrap.sh \\
      --mode <multi-module|single-bot> --config <bundle.json> \\
      [--skip-tiger-test] [--tiger-properties <path>] \\
      [--verbose] [--dry-run]

Modes (per L1 §4 dual-deployment-mode enforcement):
  multi-module   Chain api-server → orchestrator → allocator (Tower / 茗茗 pattern)
  single-bot     api-server only (YB pattern; allocator multi-module-only by design)

Flags:
  --mode <m>             Required. multi-module or single-bot.
  --config <path>        Required (except --dry-run / --help). bundle.json
                         per Phase B.2 spec §3 (api_server / orchestrator /
                         allocator sub-sections).
  --skip-tiger-test      Pass through to allocator deploy.sh (skips broker test).
  --tiger-properties <p> Pass through to allocator deploy.sh.
  --verbose              Stream all command output to stdout.
  --dry-run              Run probes only; skip side-effecting operations.
  -h, --help             Show this message.

Environment:
  GITHUB_TOKEN       Required for fresh installs (PAT for private-repo clone).
                     Mac app injects via SSH env at install time.
  NODEBLE_HOSTNAME   Optional DNS hostname added to TLS SAN.
  NODEBLE_API_PORT   Override default port 8765.

Exits: 0 success | 0 already_installed | 0 dry_run_ok | 1 generic | 2 args
       3 bundle_invalid | 11 api_server | 12 orch | 13 allocator_clone | 14 allocator
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --mode)
                shift
                [ $# -gt 0 ] || { echo "--mode requires argument" >&2; usage >&2; exit 2; }
                MODE="$1"; shift
                ;;
            --config)
                shift
                [ $# -gt 0 ] || { echo "--config requires argument" >&2; usage >&2; exit 2; }
                BUNDLE_CONFIG="$1"; shift
                ;;
            --skip-tiger-test) SKIP_TIGER_TEST=true; shift ;;
            --tiger-properties)
                shift
                [ $# -gt 0 ] || { echo "--tiger-properties requires argument" >&2; usage >&2; exit 2; }
                TIGER_PROPERTIES_PATH="$1"; shift
                ;;
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
    # Validate --mode (required, even for --dry-run — it determines dry-run scope)
    case "$MODE" in
        multi-module|single-bot) ;;
        "")
            echo "ERROR: --mode is required (multi-module|single-bot)" >&2
            usage >&2
            exit 2
            ;;
        *)
            echo "ERROR: invalid --mode '$MODE' (must be multi-module|single-bot)" >&2
            usage >&2
            exit 2
            ;;
    esac
    # --config required unless --dry-run (probes don't read config)
    if [ "$DRY_RUN" != "true" ] && [ -z "$BUNDLE_CONFIG" ]; then
        echo "ERROR: --config <bundle.json> required (omit only with --dry-run)" >&2
        usage >&2
        exit 2
    fi
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
        # Cache for chain-level RESULT emission later
        BOOTSTRAP_TOKEN="$token"
        BOOTSTRAP_FINGERPRINT="$fingerprint"
        SAVED_PORT="$port"
        API_SERVER_RESULT="already_installed"
        emit_step_ok "idempotency-probe" "api-server already installed + running"
        # Single-bot mode: api-server is the only target → fast-path exit
        # (matches Phase B.1 behavior; preserves curl-bootstrap-as-status-probe pattern)
        if [ "$MODE" = "single-bot" ]; then
            if [ -n "$token" ]; then
                # Canonical key per CTO Q4 ack 2026-05-11 (Option A rename
                # `TOKEN` → `BEARER_TOKEN`). Mac wizard Journey 1 parser regex
                # `^RESULT_BEARER_TOKEN:\s*(.+)$` consumes this line.
                emit_result BEARER_TOKEN "$token"
            fi
            if [ -n "$fingerprint" ]; then
                emit_result FINGERPRINT "$fingerprint"
            fi
            emit_result PORT "$port"
            emit_result MODE "single-bot"
            emit_result MODULES_INSTALLED "api-server"
            emit_status "already_installed"
            exit 0
        fi
        # Multi-module mode: continue to chain (orch + allocator may need install)
        return 0
    fi
    API_SERVER_RESULT="fresh"
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
            # CEO 2026-05-06 ratified Option 1 — drop Debian 12 from supported OS.
            # bookworm + bookworm-backports lack python3.12 (only 3.11 + 3.13);
            # source-build / pyenv / deadsnakes-equivalent kill bootstrap UX.
            # Close-circle (Tower / 茗茗 / YB) all Ubuntu, zero Debian users.
            die "unsupported_os: debian (Ubuntu 22.04+ only; Debian lacks python3.12 in main+backports)"
            ;;
        *)
            die "unsupported_os: $OS_ID (need ubuntu)"
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
    quiet maybe_sudo apt-get update -y || die "apt_update_failed"

    if ! quiet maybe_sudo apt-get install -y python3.12 python3.12-venv python3.12-dev; then
        quiet maybe_sudo apt-get install -y software-properties-common \
            || die "software_properties_install_failed"
        quiet maybe_sudo add-apt-repository -y ppa:deadsnakes/ppa \
            || die "deadsnakes_ppa_failed"
        quiet maybe_sudo apt-get update -y || die "apt_update_failed"
        quiet maybe_sudo apt-get install -y python3.12 python3.12-venv python3.12-dev \
            || die "python_install_failed"
    fi

    if ! command -v python3.12 >/dev/null 2>&1; then
        die "python_install_failed"
    fi

    # Ubuntu 22.04 ships python3=python3.10 as system default. Allocator deploy.sh
    # (and likely other module deploy.sh) use bare `python3` not `python3.12` →
    # would see 3.10 + fail prereq-check. Symlink in /usr/local/bin (PATH-precedence
    # over /usr/bin) so PATH-based python3 lookups resolve to 3.12. /usr/bin/python3
    # left intact to avoid breaking system tools that hardcode that path.
    if [ "$OS_ID" = "ubuntu" ] && [ "${OS_VERSION_ID%%.*}" = "22" ]; then
        maybe_sudo ln -sf /usr/bin/python3.12 /usr/local/bin/python3 \
            || emit_warn "python3 → python3.12 symlink failed (allocator may fail prereq-check)"
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
# Phase B.2 — apt-level prereqs (git for clone, jq for bundle-validate,
# ca-certificates for HTTPS, curl for IP detection)
# ──────────────────────────────────────────────────────────────────
step_apt_prereqs() {
    quiet maybe_sudo apt-get update -y || die "apt_update_failed"
    # bc + cron: required by orch deploy.sh (line 191 bc for FLOOR_DEC math;
    # line 278+ crontab binary from cron pkg for cron job install).
    # orch's April 21 baseline doesn't apt-install these itself; we provide as prereq.
    # P3 backlog: orch Phase 2 upgrade could include both in its own deploy.sh.
    quiet maybe_sudo apt-get install -y -qq \
            git ca-certificates curl jq bc cron \
        || die "apt_prereqs_failed"
    emit_step_ok "apt-prereqs" "git + ca-certificates + curl + jq + bc + cron"
}

# ──────────────────────────────────────────────────────────────────
# Phase B.2 — bundle config validation + extraction (jq-driven)
# ──────────────────────────────────────────────────────────────────

step_bundle_validate() {
    [ -r "$BUNDLE_CONFIG" ] || die_with_code "bundle_unreadable: $BUNDLE_CONFIG" 3

    # Top-level shape
    if ! jq -e . "$BUNDLE_CONFIG" >/dev/null 2>&1; then
        die_with_code "bundle_invalid: not valid JSON" 3
    fi
    local b_module b_version b_mode
    b_module=$(jq -r '.module // ""' "$BUNDLE_CONFIG")
    b_version=$(jq -r '.config_version // ""' "$BUNDLE_CONFIG")
    b_mode=$(jq -r '.mode // ""' "$BUNDLE_CONFIG")

    [ "$b_module" = "bootstrap-bundle" ] \
        || die_with_code "bundle_invalid: module='$b_module' (need 'bootstrap-bundle')" 3
    [ "$b_version" = "1" ] \
        || die_with_code "bundle_invalid: config_version='$b_version' (need 1)" 3
    case "$b_mode" in
        multi-module|single-bot) ;;
        *) die_with_code "bundle_invalid: mode='$b_mode' (need multi-module|single-bot)" 3 ;;
    esac

    # CLI --mode wins; warn if bundle.mode disagrees
    if [ "$b_mode" != "$MODE" ]; then
        emit_warn "bundle.mode='$b_mode' but CLI --mode='$MODE' (using CLI)"
    fi

    # Multi-module requires orchestrator + allocator sub-sections
    if [ "$MODE" = "multi-module" ]; then
        local has_orch has_alloc
        has_orch=$(jq -r '.orchestrator // empty' "$BUNDLE_CONFIG")
        has_alloc=$(jq -r '.allocator // empty' "$BUNDLE_CONFIG")
        [ -n "$has_orch" ] \
            || die_with_code "bundle_invalid: orchestrator section required for mode=multi-module" 3
        [ -n "$has_alloc" ] \
            || die_with_code "bundle_invalid: allocator section required for mode=multi-module" 3

        # Extract orch CLI flags (orch existing contract; not Phase 2 JSON)
        ORCH_NLV=$(jq -r '.orchestrator.nlv // ""' "$BUNDLE_CONFIG")
        ORCH_FLOOR=$(jq -r '.orchestrator.floor // ""' "$BUNDLE_CONFIG")
        ORCH_RESERVE=$(jq -r '.orchestrator.reserve // ""' "$BUNDLE_CONFIG")
        ORCH_FRED_KEY=$(jq -r '.orchestrator.fred_key // ""' "$BUNDLE_CONFIG")
        # nlv/floor/reserve required by orch deploy.sh non-interactive mode
        [ -n "$ORCH_NLV" ] \
            || die_with_code "bundle_invalid: orchestrator.nlv required" 3
        [ -n "$ORCH_FLOOR" ] \
            || die_with_code "bundle_invalid: orchestrator.floor required" 3
        [ -n "$ORCH_RESERVE" ] \
            || die_with_code "bundle_invalid: orchestrator.reserve required" 3

        # Allocator sub-section → /tmp/allocator-config.json
        jq '.allocator' "$BUNDLE_CONFIG" > /tmp/allocator-config.json \
            || die_with_code "bundle_invalid: allocator extract failed" 3
    fi

    emit_step_ok "bundle-validate" "mode=$MODE module=bootstrap-bundle v=1"
}

# ──────────────────────────────────────────────────────────────────
# Phase B.2 — orch-install step (multi-module only; existing CLI-flag contract
# per orch deploy.sh April 21 baseline; Option A ratified — orch Phase 2 P3)
# ──────────────────────────────────────────────────────────────────
probe_orch_installed() {
    # Best-effort detection: deploy.sh exists at expected path + cron entries present.
    # Orch's existing deploy.sh doesn't have idempotency-probe protocol; rely on
    # path + cron presence heuristic. Sub-deploy will emit "already_installed"
    # in its own output if it has detection logic (April 21 baseline doesn't).
    [ -d "$ORCH_DIR/.git" ] || return 1
    crontab -l 2>/dev/null | grep -q "nodeble-orchestrator\|nodeble_orchestrator" || return 1
    return 0
}

step_orch_install() {
    if [ "$MODE" = "single-bot" ]; then
        ORCH_RESULT="skipped"
        emit_step_ok "orch-install" "skipped (mode=single-bot per L1 §4)"
        return 0
    fi

    if probe_orch_installed; then
        ORCH_RESULT="already_installed"
        emit_step_ok "orch-install" "already installed at $ORCH_DIR"
        return 0
    fi

    # /opt/nodeble/ ownership: ensure writable for current user (or via sudo)
    maybe_sudo mkdir -p "$(dirname "$ORCH_DIR")" || die_with_code "orch_install_failed: mkdir_opt_failed" 12
    maybe_sudo chown "$(id -u):$(id -g)" "$(dirname "$ORCH_DIR")" 2>/dev/null || true

    # Skip clone if dir already has .git (partial-recovery: previous run cloned
    # but deploy.sh failed; let orch's own deploy.sh handle re-run idempotency)
    if [ ! -d "$ORCH_DIR/.git" ]; then
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            die_with_code "orch_install_failed: missing_github_token" 12
        fi
        if ! clone_private_repo "$ORCH_REPO_PATH" "$ORCH_DIR"; then
            die_with_code "orch_clone_failed" 12
        fi
    fi

    # Invoke orch deploy.sh with extracted CLI flags (existing contract)
    local orch_flags=(--non-interactive
        "--nlv=$ORCH_NLV"
        "--floor=$ORCH_FLOOR"
        "--reserve=$ORCH_RESERVE")
    if [ -n "$ORCH_FRED_KEY" ]; then
        orch_flags+=("--fred-key=$ORCH_FRED_KEY")
    fi

    emit_info "orch-install: invoking $ORCH_DIR/deploy.sh ${orch_flags[*]} (log: $ORCH_DEPLOY_LOG)"
    # Capture exit code via && / || pattern (NOT `if ! cmd; rc=$?` — that
    # captures the `!` operator's exit (0 inside body), not cmd's actual rc).
    local rc
    ( cd "$ORCH_DIR" && bash deploy.sh "${orch_flags[@]}" ) > "$ORCH_DEPLOY_LOG" 2>&1 && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        emit_info "orch-install: last 20 lines of $ORCH_DEPLOY_LOG:"
        tail -20 "$ORCH_DEPLOY_LOG" >&2 2>/dev/null || true
        die_with_code "orch_install_failed: deploy.sh exit $rc" 12
    fi

    ORCH_RESULT="fresh"
    emit_step_ok "orch-install" "installed at $ORCH_DIR"
}

# ──────────────────────────────────────────────────────────────────
# Phase B.2 — allocator-install step (multi-module only; full Phase D Phase 2
# canonical contract per nodeble-allocator/deploy.sh)
# ──────────────────────────────────────────────────────────────────
probe_allocator_installed() {
    [ -d "$ALLOC_DIR/.git" ] || return 1
    [ -x "$ALLOC_DIR/.venv/bin/python" ] || return 1
    return 0
}

parse_alloc_status() {
    local log="$1"
    grep -E "^STATUS:" "$log" 2>/dev/null | tail -1 || echo "STATUS: unknown"
}

step_allocator_install() {
    if [ "$MODE" = "single-bot" ]; then
        ALLOC_RESULT="skipped"
        emit_step_ok "allocator-install" "skipped (mode=single-bot per L1 §4)"
        return 0
    fi

    maybe_sudo mkdir -p "$(dirname "$ALLOC_DIR")" || die_with_code "allocator_clone_failed: mkdir_opt_failed" 13
    maybe_sudo chown "$(id -u):$(id -g)" "$(dirname "$ALLOC_DIR")" 2>/dev/null || true

    # Skip clone if dir already has .git (partial-recovery: previous run cloned
    # but deploy.sh failed; let allocator's own deploy.sh idempotency handle re-run)
    if [ ! -d "$ALLOC_DIR/.git" ]; then
        if [ -z "${GITHUB_TOKEN:-}" ]; then
            die_with_code "allocator_install_failed: missing_github_token" 14
        fi
        if ! clone_private_repo "$ALLOC_REPO_PATH" "$ALLOC_DIR"; then
            die_with_code "allocator_clone_failed" 13
        fi
    fi

    local alloc_flags=(--non-interactive --config /tmp/allocator-config.json)
    if [ "$SKIP_TIGER_TEST" = "true" ]; then
        alloc_flags+=(--skip-tiger-test)
    fi
    if [ -n "$TIGER_PROPERTIES_PATH" ]; then
        alloc_flags+=(--tiger-properties "$TIGER_PROPERTIES_PATH")
    fi

    emit_info "allocator-install: invoking $ALLOC_DIR/deploy.sh ${alloc_flags[*]} (log: $ALLOC_DEPLOY_LOG)"
    # rc capture via && / || (see step_orch_install for rationale)
    local rc
    ( cd "$ALLOC_DIR" && bash deploy.sh "${alloc_flags[@]}" ) > "$ALLOC_DEPLOY_LOG" 2>&1 && rc=0 || rc=$?
    if [ "$rc" -ne 0 ]; then
        local alloc_status
        alloc_status=$(parse_alloc_status "$ALLOC_DEPLOY_LOG")
        emit_info "allocator-install: last 20 lines of $ALLOC_DEPLOY_LOG:"
        tail -20 "$ALLOC_DEPLOY_LOG" >&2 2>/dev/null || true
        die_with_code "allocator_install_failed: $alloc_status (exit $rc)" 14
    fi

    # Parse allocator's own STATUS line for chain-level result
    local alloc_status
    alloc_status=$(parse_alloc_status "$ALLOC_DEPLOY_LOG")
    case "$alloc_status" in
        *"already_installed"*) ALLOC_RESULT="already_installed" ;;
        *"success"*)           ALLOC_RESULT="fresh" ;;
        *)                     ALLOC_RESULT="fresh" ;;  # Default — exit 0 + unparseable = treat as fresh
    esac
    emit_step_ok "allocator-install" "$alloc_status"
}

# ──────────────────────────────────────────────────────────────────
# Phase B.2 — chain RESULT + STATUS aggregation
# ──────────────────────────────────────────────────────────────────
emit_chain_results() {
    if [ -n "$BOOTSTRAP_TOKEN" ]; then
        # Canonical key per CTO Q4 ack 2026-05-11 (Option A rename TOKEN → BEARER_TOKEN).
        # Mac wizard Journey 1 parser regex `^RESULT_BEARER_TOKEN:\s*(.+)$`.
        emit_result BEARER_TOKEN "$BOOTSTRAP_TOKEN"
    fi
    if [ -n "$BOOTSTRAP_FINGERPRINT" ]; then
        emit_result FINGERPRINT "$BOOTSTRAP_FINGERPRINT"
    fi
    emit_result PORT "${SAVED_PORT:-$DEFAULT_PORT}"
    emit_result MODE "$MODE"

    # MODULES_INSTALLED reflects mode (single-bot = api-server only)
    if [ "$MODE" = "single-bot" ]; then
        emit_result MODULES_INSTALLED "api-server"
    else
        emit_result MODULES_INSTALLED "api-server,orchestrator,allocator"
    fi

    # Aggregate STATUS — already_installed iff ALL sub-deploys are already_installed
    if [ "$MODE" = "single-bot" ]; then
        # Single-bot already_installed exits early at idempotency-probe; reaching
        # here implies fresh install path (or partial-recovery completion).
        emit_status "success"
    elif [ "$API_SERVER_RESULT" = "already_installed" ] \
         && [ "$ORCH_RESULT" = "already_installed" ] \
         && [ "$ALLOC_RESULT" = "already_installed" ]; then
        emit_status "already_installed"
    else
        emit_status "success"
    fi
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

    # Phase B.1 probes — run regardless of mode
    run_step "idempotency-probe"  step_idempotency_probe
    # NOTE: idempotency-probe exits 0 fast-path for single-bot+already_installed.
    # Multi-module continues here even on already_installed (orch + allocator
    # may still need install).
    run_step "sudo-probe"         step_sudo_probe
    run_step "os-check"           step_os_check
    run_step "disk-space-check"   step_disk_check

    if [ "$DRY_RUN" = "true" ]; then
        emit_status "dry_run_ok"
        exit 0
    fi

    # Phase B.2 — apt prereqs (git/jq/ca-certs/curl) before bundle-validate
    # (jq) and clone-repo (git). Robust against minimal VPS images.
    run_step "apt-prereqs"     step_apt_prereqs
    run_step "bundle-validate" step_bundle_validate

    # Phase B.1 api-server install — skip if already_installed (each sub-step
    # is individually idempotent, but skipping saves time + clarifies output).
    if [ "$API_SERVER_RESULT" != "already_installed" ]; then
        run_step "python-install"     step_python_install
        run_step "enable-linger"      step_enable_linger
        run_step "clone-repo"         step_clone_repo
        run_step "venv-create"        step_venv_create
        run_step "pip-install"        step_pip_install
        run_step "generate-api-token" step_generate_api_token
        run_step "generate-tls-cert"  step_generate_tls_cert
        run_step "write-api-yaml"     step_write_api_yaml
        run_step "systemd-install"    step_systemd_install
        run_step "systemd-start"      step_systemd_start
        SAVED_PORT="$DEFAULT_PORT"
    fi

    # Phase B.2 chain extension — orch + allocator (multi-module only)
    run_step "orch-install"        step_orch_install
    run_step "allocator-install"   step_allocator_install

    # Security hygiene per Option 2 dispatch §1.2 — drop PAT from env after
    # the LAST clone (multi-module: post-allocator-install; single-bot: post
    # api-server clone-repo, but step_clone_repo already gates on token presence
    # so unset here covers both modes).
    unset GITHUB_TOKEN

    emit_chain_results
}

main "$@"
