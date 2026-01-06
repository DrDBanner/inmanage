#!/usr/bin/env bash

set -u
set -o pipefail

usage() {
    cat <<'EOF'
Selftest runner for inmanage (user POV).

Usage:
  scripts/selftest.sh [options]

Options:
  --log-file=PATH          Write log to PATH (default: ./_selftest/selftest-YYYYmmdd-HHMMSS.log)
  --log-dir=DIR            Directory for logs (default: ./_selftest)
  --bundle=PATH            Bundle file to test restore (dry-run by default)
  --db-file=PATH           SQL file to test db restore (dry-run by default)
  --db-client=mysql|mariadb  Force DB client selection for tests
  --install-dir=PATH       Invoice Ninja install directory (sets --ninja-location)
  --app-env=PATH            Invoice Ninja .env file (derives --ninja-location)
  --provision-file=PATH     Provision file to copy into base .inmanage/.env.provision (destructive mode)
  --destructive            Enable destructive actions (cleanup + reinstall)
  --force                  Skip destructive confirmation prompt
  --repeat=N               Repeat each test N times (default: 1)
  --debug                  Pass --debug to inmanage commands
  --shell-xtrace           Enable set -x for custom shell commands
  --run-user=USER          Run INmanage commands as USER (useful when script runs as root)
  --set-env=KEY=VALUE      Export env var for all tests (repeatable)
  --set-env-file=PATH      Source env file before running tests
  --run-inm=ARGS           Run custom inmanage command (repeatable)
  --run-cmd=CMD            Run custom shell command (repeatable)
  --run-file=PATH          File with custom commands (lines: "inm: ..." or "cmd: ...")
  --no-defaults            Skip built-in checks; run only custom commands
  --no-net                 Skip NET checks and core version
  --no-db                  Skip DB checks in preflight
  --no-web-php             Skip WEBPHP check
  --no-snappdf             Skip SNAPPDF check
  --override-enforced-user Pass --override-enforced-user to inmanage
  --quick                  Run only quick checks (health + version)
  --full                   Run full suite (default)
  --interactive            Allow interactive prompts (default: noninteractive)
  -h, --help               Show this help

Environment:
  INM_SELFTEST_LOG_DIR     Default log directory (overrides built-in auto-detect)
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INM_CLI="${INM_CLI:-$ROOT_DIR/inmanage.sh}"
LOG_DIR=""
LOG_FILE=""
BUNDLE_PATH=""
DB_FILE=""
DB_CLIENT="${DB_CLIENT:-}"
MODE="full"
REPEAT=1
INM_DEBUG=false
SHELL_XTRACE=false
RUN_USER=""
INSTALL_DIR=""
APP_ENV_PATH=""
PROVISION_FILE=""
DESTRUCTIVE=false
SELFTEST_FORCE=false
SKIP_NET=false
SKIP_DB=false
SKIP_WEBPHP=false
SKIP_SNAPPDF=false
OVERRIDE_ENFORCED_USER=false
NONINTERACTIVE=true
NO_DEFAULTS=false
TEST_DRY_RUN=true
CUSTOM_INM_CMDS=()
CUSTOM_SHELL_CMDS=()
RUN_FILE=""
SET_ENV_KV=()
SET_ENV_FILE=""
SELFTEST_RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log-file=*)
            LOG_FILE="${1#*=}"
            ;;
        --log-file)
            LOG_FILE="${2:-}"
            [[ -n "$LOG_FILE" ]] || { echo "Missing value for --log-file" >&2; exit 2; }
            shift
            ;;
        --log-dir=*)
            LOG_DIR="${1#*=}"
            ;;
        --log-dir)
            LOG_DIR="${2:-}"
            [[ -n "$LOG_DIR" ]] || { echo "Missing value for --log-dir" >&2; exit 2; }
            shift
            ;;
        --bundle=*)
            BUNDLE_PATH="${1#*=}"
            ;;
        --bundle)
            BUNDLE_PATH="${2:-}"
            [[ -n "$BUNDLE_PATH" ]] || { echo "Missing value for --bundle" >&2; exit 2; }
            shift
            ;;
        --db-file=*)
            DB_FILE="${1#*=}"
            ;;
        --db-file)
            DB_FILE="${2:-}"
            [[ -n "$DB_FILE" ]] || { echo "Missing value for --db-file" >&2; exit 2; }
            shift
            ;;
        --db-client=*)
            DB_CLIENT="${1#*=}"
            ;;
        --db-client)
            DB_CLIENT="${2:-}"
            [[ -n "$DB_CLIENT" ]] || { echo "Missing value for --db-client" >&2; exit 2; }
            shift
            ;;
        --install-dir=*)
            INSTALL_DIR="${1#*=}"
            ;;
        --install-dir)
            INSTALL_DIR="${2:-}"
            [[ -n "$INSTALL_DIR" ]] || { echo "Missing value for --install-dir" >&2; exit 2; }
            shift
            ;;
        --app-env=*)
            APP_ENV_PATH="${1#*=}"
            ;;
        --app-env)
            APP_ENV_PATH="${2:-}"
            [[ -n "$APP_ENV_PATH" ]] || { echo "Missing value for --app-env" >&2; exit 2; }
            shift
            ;;
        --provision-file=*)
            PROVISION_FILE="${1#*=}"
            ;;
        --provision-file)
            PROVISION_FILE="${2:-}"
            [[ -n "$PROVISION_FILE" ]] || { echo "Missing value for --provision-file" >&2; exit 2; }
            shift
            ;;
        --destructive)
            DESTRUCTIVE=true
            ;;
        --force)
            SELFTEST_FORCE=true
            ;;
        --repeat=*)
            REPEAT="${1#*=}"
            ;;
        --repeat)
            REPEAT="${2:-}"
            [[ -n "$REPEAT" ]] || { echo "Missing value for --repeat" >&2; exit 2; }
            shift
            ;;
        --debug)
            INM_DEBUG=true
            ;;
        --shell-xtrace)
            SHELL_XTRACE=true
            ;;
        --run-user=*)
            RUN_USER="${1#*=}"
            ;;
        --run-user)
            RUN_USER="${2:-}"
            [[ -n "$RUN_USER" ]] || { echo "Missing value for --run-user" >&2; exit 2; }
            shift
            ;;
        --set-env=*)
            SET_ENV_KV+=("${1#*=}")
            ;;
        --set-env)
            kv="${2:-}"
            [[ -n "$kv" ]] || { echo "Missing value for --set-env" >&2; exit 2; }
            SET_ENV_KV+=("$kv")
            shift
            ;;
        --set-env-file=*)
            SET_ENV_FILE="${1#*=}"
            ;;
        --set-env-file)
            SET_ENV_FILE="${2:-}"
            [[ -n "$SET_ENV_FILE" ]] || { echo "Missing value for --set-env-file" >&2; exit 2; }
            shift
            ;;
        --run-inm=*)
            CUSTOM_INM_CMDS+=("${1#*=}")
            ;;
        --run-inm)
            args="${2:-}"
            [[ -n "$args" ]] || { echo "Missing value for --run-inm" >&2; exit 2; }
            CUSTOM_INM_CMDS+=("$args")
            shift
            ;;
        --run-cmd=*)
            CUSTOM_SHELL_CMDS+=("${1#*=}")
            ;;
        --run-cmd)
            cmd="${2:-}"
            [[ -n "$cmd" ]] || { echo "Missing value for --run-cmd" >&2; exit 2; }
            CUSTOM_SHELL_CMDS+=("$cmd")
            shift
            ;;
        --run-file=*)
            RUN_FILE="${1#*=}"
            ;;
        --run-file)
            RUN_FILE="${2:-}"
            [[ -n "$RUN_FILE" ]] || { echo "Missing value for --run-file" >&2; exit 2; }
            shift
            ;;
        --no-defaults)
            NO_DEFAULTS=true
            ;;
        --no-net)
            SKIP_NET=true
            ;;
        --no-db)
            SKIP_DB=true
            ;;
        --no-web-php)
            SKIP_WEBPHP=true
            ;;
        --no-snappdf)
            SKIP_SNAPPDF=true
            ;;
        --override-enforced-user)
            OVERRIDE_ENFORCED_USER=true
            ;;
        --quick)
            MODE="quick"
            ;;
        --full)
            MODE="full"
            ;;
        --interactive)
            NONINTERACTIVE=false
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ ! -x "$INM_CLI" ]]; then
    if [[ -f "$INM_CLI" ]]; then
        INM_CLI="bash $INM_CLI"
    else
        echo "inmanage CLI not found at: $INM_CLI" >&2
        exit 1
    fi
fi

if [[ -z "$LOG_DIR" ]]; then
    if [[ -n "${INM_SELFTEST_LOG_DIR:-}" ]]; then
        LOG_DIR="$INM_SELFTEST_LOG_DIR"
    elif [[ -d "/home/ubuntu/inmanage_dev_source/testing_ground" ]]; then
        LOG_DIR="/home/ubuntu/inmanage_dev_source/testing_ground/_selftest"
    elif [[ -d "$ROOT_DIR/testing_ground" ]]; then
        LOG_DIR="$ROOT_DIR/testing_ground/_selftest"
    else
        LOG_DIR="$ROOT_DIR/_selftest"
    fi
fi
mkdir -p "$LOG_DIR"

ok=0
fail=0
skip=0
total=0
failures=()

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOG_FILE"
}

run_cmd() {
    local label="$1"
    shift
    total=$((total + 1))
    log "RUN" "$label: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    if [[ "$rc" -eq 0 ]]; then
        ok=$((ok + 1))
        log "OK" "$label"
    else
        fail=$((fail + 1))
        failures+=("$label")
        log "ERR" "$label (exit $rc)"
    fi
    return "$rc"
}

run_cmd_shell() {
    local label="$1"
    local cmd="$2"
    total=$((total + 1))
    log "RUN" "$label: $cmd"
    if [[ "$SHELL_XTRACE" == true ]]; then
        bash -lc "set -x; $cmd" 2>&1 | tee -a "$LOG_FILE"
    else
        bash -lc "$cmd" 2>&1 | tee -a "$LOG_FILE"
    fi
    local rc=${PIPESTATUS[0]}
    if [[ "$rc" -eq 0 ]]; then
        ok=$((ok + 1))
        log "OK" "$label"
    else
        fail=$((fail + 1))
        failures+=("$label")
        log "ERR" "$label (exit $rc)"
    fi
    return "$rc"
}

skip_test() {
    local label="$1"
    skip=$((skip + 1))
    log "SKIP" "$label"
}

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="$LOG_DIR/selftest-$(date +'%Y%m%d-%H%M%S').log"
fi
if [[ -z "$SELFTEST_RUN_ID" ]]; then
    SELFTEST_RUN_ID="selftest-$(date +'%Y%m%d-%H%M%S')"
fi
if ! [[ "$REPEAT" =~ ^[0-9]+$ ]] || [[ "$REPEAT" -lt 1 ]]; then
    echo "Invalid --repeat value (must be >= 1): $REPEAT" >&2
    exit 2
fi

if [[ -n "$SET_ENV_FILE" ]]; then
    if [[ ! -f "$SET_ENV_FILE" ]]; then
        echo "env file not found: $SET_ENV_FILE" >&2
        exit 1
    fi
    set -a
    # shellcheck disable=SC1090
    . "$SET_ENV_FILE"
    set +a
fi

if [[ -n "$APP_ENV_PATH" ]]; then
    if [[ ! -f "$APP_ENV_PATH" ]]; then
        echo "app env file not found: $APP_ENV_PATH" >&2
        exit 1
    fi
    export INM_ENV_FILE="$APP_ENV_PATH"
fi
if [[ -n "$INSTALL_DIR" ]]; then
    if [[ ! -d "$INSTALL_DIR" ]]; then
        if [[ "$DESTRUCTIVE" != true ]]; then
            echo "install dir not found: $INSTALL_DIR" >&2
            exit 1
        fi
    fi
fi
if [[ -n "$PROVISION_FILE" ]]; then
    if [[ ! -f "$PROVISION_FILE" ]]; then
        echo "provision file not found: $PROVISION_FILE" >&2
        exit 1
    fi
    export INM_PROVISION_ENV_FILE="$PROVISION_FILE"
fi

if [[ -z "${INM_SELF_ENV_FILE:-}" ]]; then
    base_guess=""
    if [[ -n "$APP_ENV_PATH" ]]; then
        install_guess="$(cd "$(dirname "$APP_ENV_PATH")" && pwd)"
        base_guess="$(cd "$(dirname "$install_guess")" && pwd)"
    elif [[ -n "$INSTALL_DIR" ]]; then
        if [[ -d "$INSTALL_DIR" ]]; then
            install_guess="$(cd "$INSTALL_DIR" && pwd)"
            base_guess="$(cd "$(dirname "$install_guess")" && pwd)"
        else
            base_guess="$(cd "$(dirname "$INSTALL_DIR")" && pwd)"
        fi
    fi
    if [[ -n "$base_guess" && -f "${base_guess}/.inmanage/.env.inmanage" ]]; then
        export INM_SELF_ENV_FILE="${base_guess}/.inmanage/.env.inmanage"
    elif [[ -f "./.inmanage/.env.inmanage" ]]; then
        export INM_SELF_ENV_FILE="$(cd "./.inmanage" && pwd)/.env.inmanage"
    fi
fi

if [[ ${#SET_ENV_KV[@]} -gt 0 ]]; then
    for kv in "${SET_ENV_KV[@]}"; do
        if [[ "$kv" != *"="* ]]; then
            echo "Invalid --set-env (expected KEY=VALUE): $kv" >&2
            exit 2
        fi
        key="${kv%%=*}"
        val="${kv#*=}"
        export "$key=$val"
    done
fi

export NO_COLOR=1
if [[ -n "$DB_CLIENT" ]]; then
    export INM_DB_CLIENT="$DB_CLIENT"
elif [[ "$NONINTERACTIVE" == true && -z "${INM_DB_CLIENT:-}" ]]; then
    export INM_DB_CLIENT="mysql"
fi
if [[ "$DESTRUCTIVE" == true ]]; then
    TEST_DRY_RUN=false
fi

log "INFO" "Selftest started"
log "INFO" "CLI: $INM_CLI"
log "INFO" "User: $(whoami)"
log "INFO" "PWD: $(pwd)"
log "INFO" "Log file: $LOG_FILE"
if [[ -n "${INM_DB_CLIENT:-}" ]]; then
    log "INFO" "INM_DB_CLIENT=${INM_DB_CLIENT}"
fi
log "INFO" "Repeat: $REPEAT"
log "INFO" "INM debug: $INM_DEBUG"
log "INFO" "Shell xtrace: $SHELL_XTRACE"
log "INFO" "Destructive: $DESTRUCTIVE"
if [[ "$DESTRUCTIVE" == true ]]; then
    TEST_DRY_RUN=false
fi
log "INFO" "Dry-run: $TEST_DRY_RUN"

detect_run_user() {
    local candidate=""
    if [[ -n "$RUN_USER" ]]; then
        printf "%s" "$RUN_USER"
        return 0
    fi
    if [[ -n "${INM_SELFTEST_RUN_USER:-}" ]]; then
        printf "%s" "$INM_SELFTEST_RUN_USER"
        return 0
    fi
    if [[ -f "./.inmanage/.env.inmanage" ]]; then
        candidate="$(grep -E '^INM_ENFORCED_USER=' "./.inmanage/.env.inmanage" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ')"
    elif [[ -n "${INM_SELF_ENV_FILE:-}" && -f "${INM_SELF_ENV_FILE:-}" ]]; then
        candidate="$(grep -E '^INM_ENFORCED_USER=' "$INM_SELF_ENV_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ')"
    fi
    printf "%s" "$candidate"
}

resolve_base_install() {
    local base=""
    local install=""
    if [[ -n "$APP_ENV_PATH" ]]; then
        install="$(cd "$(dirname "$APP_ENV_PATH")" && pwd)"
    elif [[ -n "$INSTALL_DIR" ]]; then
        if [[ -d "$INSTALL_DIR" ]]; then
            install="$(cd "$INSTALL_DIR" && pwd)"
        else
            local parent
            parent="$(cd "$(dirname "$INSTALL_DIR")" && pwd)" || return 1
            install="${parent}/$(basename "$INSTALL_DIR")"
        fi
    fi
    if [[ -n "$install" ]]; then
        base="$(cd "$(dirname "$install")" && pwd)"
        printf "%s|%s" "$base" "$install"
        return 0
    fi
    local env_file=""
    if [[ -f "./.inmanage/.env.inmanage" ]]; then
        env_file="./.inmanage/.env.inmanage"
    elif [[ -n "${INM_SELF_ENV_FILE:-}" && -f "${INM_SELF_ENV_FILE:-}" ]]; then
        env_file="$INM_SELF_ENV_FILE"
    fi
    if [[ -n "$env_file" ]]; then
        local base_dir install_dir
        base_dir="$(grep -E '^INM_BASE_DIRECTORY=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ')"
        install_dir="$(grep -E '^INM_INSTALLATION_DIRECTORY=' "$env_file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ')"
        if [[ -n "$base_dir" && -n "$install_dir" ]]; then
            base="$(cd "${base_dir%/}" && pwd)"
            install="$(cd "${base}/${install_dir#/}" && pwd)"
            printf "%s|%s" "$base" "$install"
            return 0
        fi
    fi
    return 1
}

confirm_destructive() {
    if [[ "$DESTRUCTIVE" != true ]]; then
        return 0
    fi
    if [[ "$SELFTEST_FORCE" == true ]]; then
        return 0
    fi
    if [[ "$NONINTERACTIVE" == true ]]; then
        log "ERR" "Destructive mode requires --force when noninteractive."
        return 1
    fi
    printf "Destructive mode will remove app/cache/backup data under the base directory. Type 'yes' to continue: " | tee -a "$LOG_FILE"
    local answer=""
    read -r answer
    if [[ "$answer" != "yes" ]]; then
        log "INFO" "Destructive mode cancelled."
        return 1
    fi
    return 0
}

destructive_cleanup() {
    local base_dir="$1"
    local install_dir="$2"
    local install_name=""
    install_name="$(basename "$install_dir")"
    if [[ -z "$base_dir" || -z "$install_dir" ]]; then
        log "ERR" "Destructive cleanup needs base/install dirs."
        return 1
    fi
    if [[ "$base_dir" == "/" || "$install_dir" == "/" ]]; then
        log "ERR" "Refusing to clean root directory."
        return 1
    fi
    if [[ ! -d "$base_dir" ]]; then
        log "ERR" "Base directory not found: $base_dir"
        return 1
    fi
    local targets=()
    targets+=("$install_dir")
    targets+=("$base_dir/.cache")
    targets+=("$base_dir/.backup")
    targets+=("$base_dir/.inmanage")
    targets+=("$base_dir/.inmanage/history.log")
    if [[ -n "$install_name" ]]; then
        local rb
        while IFS= read -r rb; do
            [[ -z "$rb" ]] && continue
            targets+=("$rb")
        done < <(find "$base_dir" -maxdepth 1 -type d -name "${install_name}_rollback_*" 2>/dev/null)
    fi

    local t
    for t in "${targets[@]}"; do
        if [[ -e "$t" ]]; then
            rm -rf "$t"
        fi
    done
    return 0
}

resolve_enforced_owner() {
    local base_dir="$1"
    local user=""
    if [[ -n "$RUN_USER" ]]; then
        user="$RUN_USER"
    elif [[ -n "$INM_RUN_USER" ]]; then
        user="$INM_RUN_USER"
    elif [[ -n "$base_dir" && -f "$base_dir/.inmanage/.env.inmanage" ]]; then
        user="$(grep -E '^INM_ENFORCED_USER=' "$base_dir/.inmanage/.env.inmanage" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' ')"
    fi
    if [[ -z "$user" ]]; then
        user="$(id -un 2>/dev/null || whoami 2>/dev/null || echo "root")"
    fi
    local group=""
    group="$(id -gn "$user" 2>/dev/null || echo "$user")"
    printf "%s:%s" "$user" "$group"
}

prepare_cli_config() {
    local base_dir="$1"
    local install_dir="$2"
    local owner="$3"
    local config_dir="${base_dir%/}/.inmanage"
    local config_file="${config_dir}/.env.inmanage"
    local owner_user="${owner%%:*}"
    local install_rel="$install_dir"

    if [[ -z "$base_dir" || -z "$install_dir" ]]; then
        return 1
    fi
    if [[ "$install_dir" == "$base_dir"* ]]; then
        install_rel="${install_dir#$base_dir}"
        install_rel="${install_rel#/}"
        install_rel="./${install_rel}"
    fi

    mkdir -p "$config_dir" || return 1
    cat >"$config_file" <<EOF
INM_BASE_DIRECTORY="${base_dir%/}/"
INM_INSTALLATION_DIRECTORY="${install_rel}"
INM_ENV_FILE="\${INM_BASE_DIRECTORY}\${INM_INSTALLATION_DIRECTORY}/.env"
INM_CACHE_LOCAL_DIRECTORY="./.cache"
INM_BACKUP_DIRECTORY="./.backup"
INM_FORCE_READ_DB_PW="Y"
INM_ENFORCED_USER="${owner_user}"
EOF
    if [[ -n "$owner" ]]; then
        chown "$owner" "$config_dir" "$config_file" 2>/dev/null || true
    fi
    chmod 750 "$config_dir" 2>/dev/null || true
    chmod 600 "$config_file" 2>/dev/null || true
    printf "%s" "$config_file"
}

read_env_key() {
    local file="$1"
    local key="$2"
    grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '"'\'' '
}

ensure_env_kv() {
    local file="$1"
    local key="$2"
    local value="$3"
    if ! grep -q -E "^[[:space:]]*${key}=" "$file"; then
        printf '%s="%s"\n' "$key" "$value" >>"$file"
    fi
}

prepare_cli_config_from_provision() {
    local base_dir="$1"
    local install_dir="$2"
    local owner="$3"
    local prov_file="$4"
    local config_dir="${base_dir%/}/.inmanage"
    local config_file="${config_dir}/.env.inmanage"
    local tmp_file=""
    local owner_user="${owner%%:*}"
    local install_rel="$install_dir"

    if [[ -z "$base_dir" || -z "$install_dir" || -z "$prov_file" ]]; then
        return 1
    fi
    if [[ "$install_dir" == "$base_dir"* ]]; then
        install_rel="${install_dir#$base_dir}"
        install_rel="${install_rel#/}"
        install_rel="./${install_rel}"
    fi

    mkdir -p "$config_dir" || return 1
    tmp_file="$(mktemp)"
    grep -E "^[[:space:]]*INM_[A-Za-z0-9_]+=" "$prov_file" 2>/dev/null | sed 's/^[[:space:]]*//' >"$tmp_file"

    ensure_env_kv "$tmp_file" "INM_BASE_DIRECTORY" "${base_dir%/}/"
    ensure_env_kv "$tmp_file" "INM_INSTALLATION_DIRECTORY" "$install_rel"
    ensure_env_kv "$tmp_file" "INM_ENV_FILE" '${INM_BASE_DIRECTORY}${INM_INSTALLATION_DIRECTORY}/.env'
    if [[ -n "$owner_user" ]]; then
        ensure_env_kv "$tmp_file" "INM_ENFORCED_USER" "$owner_user"
    fi
    ensure_env_kv "$tmp_file" "INM_CACHE_LOCAL_DIRECTORY" "./.cache"
    ensure_env_kv "$tmp_file" "INM_BACKUP_DIRECTORY" "./.backup"
    ensure_env_kv "$tmp_file" "INM_FORCE_READ_DB_PW" "Y"

    mv "$tmp_file" "$config_file"
    if [[ -n "$owner" ]]; then
        chown "$owner" "$config_dir" "$config_file" 2>/dev/null || true
    fi
    chmod 750 "$config_dir" 2>/dev/null || true
    chmod 600 "$config_file" 2>/dev/null || true
    printf "%s" "$config_file"
}

prepare_provision_file() {
    local base_dir="$1"
    local owner="$2"
    local src="$3"
    local dest_dir="${base_dir%/}/.inmanage"
    local dest_file="${dest_dir}/.env.provision"
    mkdir -p "$dest_dir" || return 1
    if [[ -n "$src" ]]; then
        cp -f "$src" "$dest_file" || return 1
    fi
    if [[ -n "$owner" ]]; then
        chown "$owner" "$dest_dir" "$dest_file" 2>/dev/null || true
    fi
    chmod 750 "$dest_dir" 2>/dev/null || true
    chmod 600 "$dest_file" 2>/dev/null || true
    printf "%s" "$dest_file"
}

if [[ ! -f "./.inmanage/.env.inmanage" && -z "${INM_SELF_ENV_FILE:-}" ]]; then
    prov_src=""
    if [[ -n "$PROVISION_FILE" ]]; then
        prov_src="$PROVISION_FILE"
    elif [[ -n "${INM_PROVISION_ENV_FILE:-}" && -f "${INM_PROVISION_ENV_FILE:-}" ]]; then
        prov_src="$INM_PROVISION_ENV_FILE"
    fi
    resolved="$(resolve_base_install || true)"
    if [[ -n "$resolved" ]]; then
        auto_base_dir="${resolved%%|*}"
        auto_install_dir="${resolved#*|}"
    fi
    if [[ -z "${auto_base_dir:-}" && -n "$prov_src" && -f "$prov_src" ]]; then
        auto_base_dir="$(read_env_key "$prov_src" INM_BASE_DIRECTORY)"
        auto_install_dir="$(read_env_key "$prov_src" INM_INSTALLATION_DIRECTORY)"
        if [[ -n "$auto_base_dir" && -n "$auto_install_dir" && "$auto_install_dir" != /* ]]; then
            auto_install_dir="${auto_base_dir%/}/${auto_install_dir#./}"
        fi
    fi
    if [[ -n "${auto_base_dir:-}" && -n "${auto_install_dir:-}" ]]; then
        if [[ ! -d "$auto_base_dir" && "$auto_base_dir" != "/" ]]; then
            mkdir -p "$auto_base_dir" 2>/dev/null || true
        fi
        if [[ -d "$auto_base_dir" ]]; then
            owner="$(resolve_enforced_owner "$auto_base_dir")"
            if [[ -n "$prov_src" && -f "$prov_src" ]]; then
                cli_env_file="$(prepare_cli_config_from_provision "$auto_base_dir" "$auto_install_dir" "$owner" "$prov_src")"
            else
                cli_env_file="$(prepare_cli_config "$auto_base_dir" "$auto_install_dir" "$owner")"
            fi
            if [[ -n "$cli_env_file" ]]; then
                export INM_SELF_ENV_FILE="$cli_env_file"
                log "INFO" "CLI config created for selftest: $cli_env_file"
            fi
        fi
    fi
fi

INM_RUN_USER=""
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    INM_RUN_USER="$(detect_run_user)"
    if [[ -z "$INM_RUN_USER" ]]; then
        log "WARN" "Running as root with no run-user set; INmanage will run as root. Use --run-user or set INM_ENFORCED_USER in .inmanage/.env.inmanage."
    else
        log "INFO" "Running INmanage commands as: $INM_RUN_USER"
    fi
fi

INM_RUN_PREFIX=()
INM_SHELL_PREFIX=""
if [[ "${EUID:-$(id -u)}" -eq 0 && -n "$INM_RUN_USER" && "$INM_RUN_USER" != "root" ]]; then
    if command -v sudo >/dev/null 2>&1; then
        INM_RUN_PREFIX=(sudo -u "$INM_RUN_USER" --)
        INM_SHELL_PREFIX="sudo -u $INM_RUN_USER -- "
    elif command -v runuser >/dev/null 2>&1; then
        INM_RUN_PREFIX=(runuser -u "$INM_RUN_USER" --)
        INM_SHELL_PREFIX="runuser -u $INM_RUN_USER -- "
    else
        log "ERR" "No sudo or runuser available to switch to $INM_RUN_USER."
        exit 1
    fi
fi

INM_RUN_ENV=()
INM_RUN_ENV_SHELL=""

build_inm_env() {
    local run_id="$1"
    INM_RUN_ENV=()
    INM_RUN_ENV_SHELL=""
    local key val
    for key in INM_SELF_ENV_FILE INM_PROVISION_ENV_FILE INM_DB_CLIENT NO_COLOR; do
        val="${!key:-}"
        [[ -n "$val" ]] || continue
        INM_RUN_ENV+=("${key}=${val}")
        INM_RUN_ENV_SHELL+="${key}=$(printf '%q' "$val") "
    done
    if [[ -n "$run_id" ]]; then
        INM_RUN_ENV+=("INM_OPS_LOG_RUN_ID=${run_id}")
        INM_RUN_ENV_SHELL+="INM_OPS_LOG_RUN_ID=$(printf '%q' "$run_id") "
    fi
}

INM_CMD=()
read -r -a INM_CMD <<< "$INM_CLI"

if [[ -n "$RUN_FILE" ]]; then
    if [[ ! -f "$RUN_FILE" ]]; then
        log "ERR" "run file not found: $RUN_FILE"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        if [[ "$line" == inm:* ]]; then
            CUSTOM_INM_CMDS+=("${line#inm:}")
        elif [[ "$line" == cmd:* ]]; then
            CUSTOM_SHELL_CMDS+=("${line#cmd:}")
        else
            CUSTOM_SHELL_CMDS+=("$line")
        fi
    done < "$RUN_FILE"
fi

append_config_arg() {
    local cfg="$1"
    [[ -n "$cfg" ]] || return 0
    local arg="--config=$cfg"
    local existing
    for existing in "${COMMON_ARGS[@]}"; do
        [[ "$existing" == --config=* ]] && return 0
    done
    COMMON_ARGS+=("$arg")
}

COMMON_ARGS=()
if [[ "$OVERRIDE_ENFORCED_USER" == true ]]; then
    COMMON_ARGS+=(--override-enforced-user)
fi
if [[ "$INM_DEBUG" == true ]]; then
    COMMON_ARGS+=(--debug)
fi
if [[ -n "$APP_ENV_PATH" ]]; then
    COMMON_ARGS+=(--ninja-location="$(dirname "$APP_ENV_PATH")")
elif [[ -n "$INSTALL_DIR" ]]; then
    if [[ -d "$INSTALL_DIR" || "$DESTRUCTIVE" == true ]]; then
        COMMON_ARGS+=(--ninja-location="$INSTALL_DIR")
    fi
fi
append_config_arg "${INM_SELF_ENV_FILE:-}"

filter_install_args() {
    local filtered=()
    local skip_next=false
    local arg
    for arg in "$@"; do
        if [[ "$skip_next" == true ]]; then
            skip_next=false
            continue
        fi
        case "$arg" in
            --ninja-location=*)
                continue
                ;;
            --ninja-location)
                skip_next=true
                continue
                ;;
            *)
                filtered+=("$arg")
                ;;
        esac
    done
    printf '%s\n' "${filtered[@]}"
}

run_cmd_repeat() {
    local label="$1"
    local count="$2"
    shift 2
    local i
    for ((i=1; i<=count; i++)); do
        if [[ "$count" -gt 1 ]]; then
            run_cmd "${label} (${i}/${count})" "$@"
        else
            run_cmd "$label" "$@"
        fi
    done
}

run_cmd_shell_repeat() {
    local label="$1"
    local count="$2"
    local cmd="$3"
    local i
    for ((i=1; i<=count; i++)); do
        if [[ "$count" -gt 1 ]]; then
            run_cmd_shell "${label} (${i}/${count})" "$cmd"
        else
            run_cmd_shell "$label" "$cmd"
        fi
    done
}

run_inm_repeat() {
    local label="$1"
    local count="$2"
    shift 2
    local i
    for ((i=1; i<=count; i++)); do
        local run_id=""
        if [[ -n "$SELFTEST_RUN_ID" ]]; then
            run_id="${SELFTEST_RUN_ID}-r${i}"
        fi
        build_inm_env "$run_id"
        local env_cmd=()
        if [[ ${#INM_RUN_ENV[@]} -gt 0 ]]; then
            env_cmd=(env "${INM_RUN_ENV[@]}")
        fi
        if [[ "$count" -gt 1 ]]; then
            run_cmd "${label} (${i}/${count})" "${INM_RUN_PREFIX[@]}" "${env_cmd[@]}" "${INM_CMD[@]}" "$@"
        else
            run_cmd "$label" "${INM_RUN_PREFIX[@]}" "${env_cmd[@]}" "${INM_CMD[@]}" "$@"
        fi
    done
}

run_inm_shell_repeat() {
    local label="$1"
    local count="$2"
    local cmd="$3"
    local i
    for ((i=1; i<=count; i++)); do
        local run_id=""
        if [[ -n "$SELFTEST_RUN_ID" ]]; then
            run_id="${SELFTEST_RUN_ID}-r${i}"
        fi
        build_inm_env "$run_id"
        local env_prefix=""
        if [[ -n "$INM_RUN_ENV_SHELL" ]]; then
            env_prefix="env ${INM_RUN_ENV_SHELL}"
        fi
        local full_cmd="${INM_SHELL_PREFIX}${env_prefix}${cmd}"
        if [[ "$count" -gt 1 ]]; then
            run_cmd_shell "${label} (${i}/${count})" "$full_cmd"
        else
            run_cmd_shell "$label" "$full_cmd"
        fi
    done
}

DRY_RUN_ARGS=()
DRY_RUN_LABEL=""
if [[ "$TEST_DRY_RUN" == true ]]; then
    DRY_RUN_ARGS=(--dry-run)
    DRY_RUN_LABEL=" (dry-run)"
fi

if [[ "$NO_DEFAULTS" != true ]]; then
    CHECKS=(CLI SYS FS ENVCLI ENVAPP CMD WEB PHP EXT WEBPHP NET DB APP CRON SNAPPDF)
    if [[ "$SKIP_NET" == true ]]; then
        CHECKS=("${CHECKS[@]/NET}")
    fi
    if [[ "$SKIP_DB" == true ]]; then
        CHECKS=("${CHECKS[@]/DB}")
    fi
    if [[ "$SKIP_WEBPHP" == true ]]; then
        CHECKS=("${CHECKS[@]/WEBPHP}")
    fi
    if [[ "$SKIP_SNAPPDF" == true ]]; then
        CHECKS=("${CHECKS[@]/SNAPPDF}")
    fi
    CHECKS=("${CHECKS[@]/}")
    CHECKS_CSV="$(IFS=,; echo "${CHECKS[*]}")"

    run_inm_repeat "core health" "$REPEAT" core health --checks="$CHECKS_CSV" "${COMMON_ARGS[@]}"

    if [[ "$SKIP_NET" == true ]]; then
        skip_test "core version (no-net)"
    else
        run_inm_repeat "core version" "$REPEAT" core version "${COMMON_ARGS[@]}"
    fi

    if [[ "$MODE" == "full" ]]; then
        run_inm_repeat "env show cli" "$REPEAT" env show cli "${COMMON_ARGS[@]}"
        run_inm_repeat "env show app" "$REPEAT" env show app "${COMMON_ARGS[@]}"
        run_inm_repeat "core prune${DRY_RUN_LABEL}" "$REPEAT" core prune "${DRY_RUN_ARGS[@]}" "${COMMON_ARGS[@]}"
        run_inm_repeat "core clear-cache${DRY_RUN_LABEL}" "$REPEAT" core clear-cache "${DRY_RUN_ARGS[@]}" "${COMMON_ARGS[@]}"
        run_inm_repeat "core backup${DRY_RUN_LABEL}" "$REPEAT" core backup "${DRY_RUN_ARGS[@]}" --compress=false --name=selftest "${COMMON_ARGS[@]}"
        run_inm_repeat "db backup${DRY_RUN_LABEL}" "$REPEAT" db backup "${DRY_RUN_ARGS[@]}" --compress=false --name=selftest "${COMMON_ARGS[@]}"
        run_inm_repeat "files backup${DRY_RUN_LABEL}" "$REPEAT" files backup "${DRY_RUN_ARGS[@]}" --compress=false --name=selftest "${COMMON_ARGS[@]}"

        if [[ -n "$BUNDLE_PATH" ]]; then
            run_inm_repeat "core restore${DRY_RUN_LABEL}" "$REPEAT" core restore "${DRY_RUN_ARGS[@]}" --file="$BUNDLE_PATH" "${COMMON_ARGS[@]}"
        else
            skip_test "core restore${DRY_RUN_LABEL} --bundle not provided"
        fi

        if [[ -n "$DB_FILE" ]]; then
            run_inm_repeat "db restore${DRY_RUN_LABEL}" "$REPEAT" db restore "${DRY_RUN_ARGS[@]}" --file="$DB_FILE" --force "${COMMON_ARGS[@]}"
        else
            skip_test "db restore${DRY_RUN_LABEL} --db-file not provided"
        fi
    fi
fi

if [[ "$DESTRUCTIVE" == true ]]; then
    if ! confirm_destructive; then
        exit 1
    fi
    resolved="$(resolve_base_install || true)"
    base_dir=""
    install_dir=""
    if [[ -n "$resolved" ]]; then
        base_dir="${resolved%%|*}"
        install_dir="${resolved#*|}"
    fi
    if [[ -z "$base_dir" || -z "$install_dir" ]]; then
        log "ERR" "Destructive mode needs --install-dir or --app-env (or a readable .inmanage/.env.inmanage)."
        exit 1
    fi

    run_cmd "destructive cleanup" destructive_cleanup "$base_dir" "$install_dir"

    owner="$(resolve_enforced_owner "$base_dir")"
    prov_src=""
    if [[ -n "$PROVISION_FILE" ]]; then
        prov_src="$PROVISION_FILE"
    elif [[ -n "${INM_PROVISION_ENV_FILE:-}" && -f "${INM_PROVISION_ENV_FILE:-}" ]]; then
        prov_src="$INM_PROVISION_ENV_FILE"
    elif [[ -f "$base_dir/.inmanage/.env.provision" ]]; then
        prov_src="$base_dir/.inmanage/.env.provision"
    fi
    if [[ -z "$prov_src" && "$NONINTERACTIVE" == true ]]; then
        log "ERR" "No provision file found for destructive install. Use --provision-file or ensure .inmanage/.env.provision exists."
        exit 1
    fi
    prov_file=""
    if [[ -n "$prov_src" ]]; then
        prov_file="$(prepare_provision_file "$base_dir" "$owner" "$prov_src")"
    fi
    if [[ -n "$prov_file" ]]; then
        cli_env_file="$(prepare_cli_config_from_provision "$base_dir" "$install_dir" "$owner" "$prov_file")"
    else
        cli_env_file="$(prepare_cli_config "$base_dir" "$install_dir" "$owner")"
    fi
    if [[ -z "$cli_env_file" ]]; then
        log "ERR" "Failed to create CLI config for destructive install."
        exit 1
    fi
    export INM_SELF_ENV_FILE="$cli_env_file"
    append_config_arg "$cli_env_file"

    if [[ -n "$prov_file" ]]; then
        export INM_PROVISION_ENV_FILE="$prov_file"
    fi

    mapfile -t INSTALL_ARGS < <(filter_install_args "${COMMON_ARGS[@]}")
    if [[ -n "$prov_file" ]]; then
        run_inm_repeat "core install (destructive)" "$REPEAT" core install --provision --force --provision-file="$prov_file" "${INSTALL_ARGS[@]}"
    else
        run_inm_repeat "core install (destructive)" "$REPEAT" core install --force "${INSTALL_ARGS[@]}"
    fi
fi

if [[ ${#CUSTOM_INM_CMDS[@]} -gt 0 ]]; then
    for args in "${CUSTOM_INM_CMDS[@]}"; do
        local_label="custom inmanage"
        run_inm_shell_repeat "$local_label" "$REPEAT" "$INM_CLI $args"
    done
fi

if [[ ${#CUSTOM_SHELL_CMDS[@]} -gt 0 ]]; then
    for cmd in "${CUSTOM_SHELL_CMDS[@]}"; do
        run_cmd_shell_repeat "custom shell" "$REPEAT" "$cmd"
    done
fi

log "INFO" "Selftest completed: total=$total ok=$ok fail=$fail skip=$skip"
if [[ "${#failures[@]}" -gt 0 ]]; then
    log "ERR" "Failed tests: ${failures[*]}"
fi

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
