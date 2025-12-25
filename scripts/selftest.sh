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
  --bundle=PATH            Bundle file to test restore (dry-run)
  --db-file=PATH           SQL file to test db restore (dry-run)
  --db-client=mysql|mariadb  Force DB client selection for tests
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
SKIP_NET=false
SKIP_DB=false
SKIP_WEBPHP=false
SKIP_SNAPPDF=false
OVERRIDE_ENFORCED_USER=false
NONINTERACTIVE=true
NO_DEFAULTS=false
CUSTOM_INM_CMDS=()
CUSTOM_SHELL_CMDS=()
RUN_FILE=""
SET_ENV_KV=()
SET_ENV_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --log-file=*)
            LOG_FILE="${1#*=}"
            ;;
        --log-dir=*)
            LOG_DIR="${1#*=}"
            ;;
        --bundle=*)
            BUNDLE_PATH="${1#*=}"
            ;;
        --db-file=*)
            DB_FILE="${1#*=}"
            ;;
        --db-client=*)
            DB_CLIENT="${1#*=}"
            ;;
        --set-env=*)
            SET_ENV_KV+=("${1#*=}")
            ;;
        --set-env-file=*)
            SET_ENV_FILE="${1#*=}"
            ;;
        --run-inm=*)
            CUSTOM_INM_CMDS+=("${1#*=}")
            ;;
        --run-cmd=*)
            CUSTOM_SHELL_CMDS+=("${1#*=}")
            ;;
        --run-file=*)
            RUN_FILE="${1#*=}"
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
    bash -lc "$cmd" 2>&1 | tee -a "$LOG_FILE"
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

log "INFO" "Selftest started"
log "INFO" "CLI: $INM_CLI"
log "INFO" "User: $(whoami)"
log "INFO" "PWD: $(pwd)"
log "INFO" "Log file: $LOG_FILE"
if [[ -n "${INM_DB_CLIENT:-}" ]]; then
    log "INFO" "INM_DB_CLIENT=${INM_DB_CLIENT}"
fi

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

COMMON_ARGS=()
if [[ "$OVERRIDE_ENFORCED_USER" == true ]]; then
    COMMON_ARGS+=(--override-enforced-user)
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

    run_cmd "core health" $INM_CLI core health --checks="$CHECKS_CSV" "${COMMON_ARGS[@]}"

    if [[ "$SKIP_NET" == true ]]; then
        skip_test "core version (no-net)"
    else
        run_cmd "core version" $INM_CLI core version "${COMMON_ARGS[@]}"
    fi

    if [[ "$MODE" == "full" ]]; then
        run_cmd "env show cli" $INM_CLI env show cli "${COMMON_ARGS[@]}"
        run_cmd "env show app" $INM_CLI env show app "${COMMON_ARGS[@]}"
        run_cmd "core prune (dry-run)" $INM_CLI core prune --dry-run "${COMMON_ARGS[@]}"
        run_cmd "core clear-cache (dry-run)" $INM_CLI core clear-cache --dry-run "${COMMON_ARGS[@]}"
        run_cmd "core backup (dry-run)" $INM_CLI core backup --dry-run --compress=false --name=selftest "${COMMON_ARGS[@]}"
        run_cmd "db backup (dry-run)" $INM_CLI db backup --dry-run --compress=false --name=selftest "${COMMON_ARGS[@]}"
        run_cmd "files backup (dry-run)" $INM_CLI files backup --dry-run --compress=false --name=selftest "${COMMON_ARGS[@]}"

        if [[ -n "$BUNDLE_PATH" ]]; then
            run_cmd "core restore (dry-run)" $INM_CLI core restore --dry-run --file="$BUNDLE_PATH" "${COMMON_ARGS[@]}"
        else
            skip_test "core restore (dry-run) --bundle not provided"
        fi

        if [[ -n "$DB_FILE" ]]; then
            run_cmd "db restore (dry-run)" $INM_CLI db restore --dry-run --file="$DB_FILE" --force "${COMMON_ARGS[@]}"
        else
            skip_test "db restore (dry-run) --db-file not provided"
        fi
    fi
fi

if [[ ${#CUSTOM_INM_CMDS[@]} -gt 0 ]]; then
    for args in "${CUSTOM_INM_CMDS[@]}"; do
        local_label="custom inmanage"
        run_cmd_shell "$local_label" "$INM_CLI $args"
    done
fi

if [[ ${#CUSTOM_SHELL_CMDS[@]} -gt 0 ]]; then
    for cmd in "${CUSTOM_SHELL_CMDS[@]}"; do
        run_cmd_shell "custom shell" "$cmd"
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
