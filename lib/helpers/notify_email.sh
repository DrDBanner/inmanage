#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__NOTIFY_EMAIL_HELPER_LOADED:-} ]] && return
__NOTIFY_EMAIL_HELPER_LOADED=1

notify_env_helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helpers/env_read.sh"
# shellcheck source=/dev/null
[ -f "$notify_env_helper_path" ] && {
    source "$notify_env_helper_path"
    __INM_LOADED_FILES="${__INM_LOADED_FILES:+$__INM_LOADED_FILES:}$notify_env_helper_path"
}

if ! declare -F read_env_value >/dev/null 2>&1; then
    read_env_value() {
        log err "[NOTIFY] Env read helper missing; cannot read MAIL_* settings."
        return 1
    }
fi

# ---------------------------------------------------------------------
# Email formatting helpers
# ---------------------------------------------------------------------
notify_email_html_escape() {
    local value="$1"
    value="${value//&gt;/>}"
    value="${value//&lt;/<}"
    value="${value//&amp;/&}"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    printf "%s" "$value"
}

notify_email_status_color() {
    local status="${1^^}"
    case "$status" in
        ERR) echo "#b91c1c" ;;
        WARN) echo "#b45309" ;;
        OK) echo "#15803d" ;;
        INFO) echo "#1d4ed8" ;;
        *) echo "#6b7280" ;;
    esac
}

notify_email_status_badge_class() {
    local status="${1^^}"
    case "$status" in
        ERR) echo "badge badge-danger" ;;
        WARN) echo "badge badge-warning" ;;
        OK) echo "badge badge-success" ;;
        INFO) echo "badge badge-info" ;;
        *) echo "badge badge-secondary" ;;
    esac
}

notify_email_format_html() {
    local title="$1"
    local status="${2:-}"
    local counts="${3:-}"
    local details="${4:-}"
    local host
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local status_color
    status_color="$(notify_email_status_color "$status")"
    local base_dir="${INM_BASE_DIRECTORY%/}"
    local app_url="${APP_URL:-}"
    app_url="${app_url%/}"

    {
        printf "<div style=\"max-width:680px; width:100%%;\">"
        printf "<table class=\"table table-sm\" style=\"width:100%%; border-collapse: collapse;\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" role=\"presentation\">"
        printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">Event</th>"
        printf "<td style=\"padding:2px 0; vertical-align:top; word-break: break-word; overflow-wrap:anywhere;\">%s</td></tr>" \
            "$(notify_email_html_escape "$title")"
        if [ -n "$status" ]; then
            local status_badge
            status_badge="$(notify_email_status_badge_class "$status")"
            printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">Status</th>"
            printf "<td style=\"padding:2px 0; vertical-align:top;\"><span class=\"%s\" style=\"color:%s;font-weight:600; white-space:nowrap;\">%s</span></td></tr>" \
                "$status_badge" "$status_color" "$(notify_email_html_escape "$status")"
        fi
        if [ -n "$counts" ]; then
            printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">Counts</th>"
            printf "<td style=\"padding:2px 0; vertical-align:top;\">%s</td></tr>" "$(notify_email_html_escape "$counts")"
        fi
        printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">Host</th>"
        printf "<td style=\"padding:2px 0; vertical-align:top;\">%s</td></tr>" "$(notify_email_html_escape "$host")"
        if [ -n "$base_dir" ]; then
            printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">Base</th>"
            printf "<td style=\"padding:2px 0; vertical-align:top; word-break: break-word; overflow-wrap:anywhere;\">%s</td></tr>" \
                "$(notify_email_html_escape "$base_dir")"
        fi
        if [ -n "$app_url" ]; then
            printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">APP_URL</th>"
            printf "<td style=\"padding:2px 0; vertical-align:top; word-break: break-word; overflow-wrap:anywhere;\"><a href=\"%s\" style=\"color:#1d4ed8;\">%s</a></td></tr>" \
                "$(notify_email_html_escape "$app_url")" "$(notify_email_html_escape "$app_url")"
        fi
        printf "<tr><th align=\"left\" style=\"padding:2px 12px 2px 0; white-space:nowrap; vertical-align:top;\">Timestamp</th>"
        printf "<td style=\"padding:2px 0; vertical-align:top;\">%s</td></tr>" "$(notify_email_html_escape "$ts")"
        printf "</table>"

        if [ -n "$details" ]; then
            printf "<div style=\"margin-top:12px;\"></div>"
            printf "<table class=\"table table-sm\" style=\"border-collapse: collapse; width:100%%; table-layout: fixed;\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" role=\"presentation\">"
            printf "<colgroup><col style=\"width:14%%;\"><col style=\"width:10%%;\"><col style=\"width:76%%;\"></colgroup>"
            printf "<tr><th align=\"left\" style=\"padding:4px 12px 4px 0; border-bottom:1px solid #e5e7eb;\">Check</th>"
            printf "<th align=\"left\" style=\"padding:4px 12px; border-bottom:1px solid #e5e7eb; white-space:nowrap;\">Status</th>"
            printf "<th align=\"left\" style=\"padding:4px 0; border-bottom:1px solid #e5e7eb;\">Detail</th></tr>"
            local line status_text status_cell detail check
            local current=-1
            local row_checks=()
            local row_status=()
            local row_details=()
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [[ "$line" == *"|"* ]]; then
                    check="${line%%|*}"
                    status_text="${line#*|}"
                    status_text="${status_text%%|*}"
                    detail="${line#*|}"
                    detail="${detail#*|}"
                    current=$((current + 1))
                    row_checks[current]="$(printf "%s" "$check" | sed 's/[[:space:]]*$//')"
                    row_status[current]="$(printf "%s" "$status_text" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                    row_details[current]="$(printf "%s" "$detail" | sed 's/^[[:space:]]*//')"
                else
                    if [ "$current" -ge 0 ]; then
                        row_details[current]+=$'\n'"$line"
                    else
                        current=$((current + 1))
                        row_checks[current]=""
                        row_status[current]=""
                        row_details[current]="$line"
                    fi
                fi
            done <<< "$details"
            local idx
            for idx in "${!row_details[@]}"; do
                check="$(notify_email_html_escape "${row_checks[$idx]}")"
                status_text="$(notify_email_html_escape "${row_status[$idx]}")"
                detail="$(notify_email_html_escape "${row_details[$idx]}")"
                detail="${detail//$'\n'/<br>}"
                status_cell="$status_text"
                if [ -n "$status_text" ]; then
                    status_color="$(notify_email_status_color "$status_text")"
                    status_cell="<span class=\"$(notify_email_status_badge_class "$status_text")\" style=\"color:${status_color};font-weight:600; white-space:nowrap;\">${status_text}</span>"
                fi
                printf "<tr><td style=\"padding:4px 12px 4px 0; border-bottom:1px solid #f3f4f6; vertical-align:top;\">%s</td>" "$check"
                printf "<td style=\"padding:4px 12px; border-bottom:1px solid #f3f4f6; vertical-align:top; white-space:nowrap;\">%s</td>" "$status_cell"
                printf "<td style=\"padding:4px 0; border-bottom:1px solid #f3f4f6; vertical-align:top; word-break: break-word; overflow-wrap:anywhere;\">%s</td></tr>" "$detail"
            done
            printf "</table>"
        fi
        printf "</div>"
    }
}

# ---------------------------------------------------------------------
# Email helpers
# ---------------------------------------------------------------------
notify_send_email() {
    local subject="$1"
    local body="$2"
    local body_html="${3:-}"
    local to="${INM_NOTIFY_EMAIL_TO:-}"
    if [ -z "$to" ]; then
        log warn "[NOTIFY] Email target missing (INM_NOTIFY_EMAIL_TO)."
        return 1
    fi
    if [ -z "${INM_ENV_FILE:-}" ] || [ ! -f "$INM_ENV_FILE" ]; then
        log warn "[NOTIFY] App .env missing; cannot read MAIL_* settings."
        return 1
    fi

    local mailer host port user pass enc from from_name
    mailer="$(read_env_value "$INM_ENV_FILE" "MAIL_MAILER")"
    if [ -z "$mailer" ]; then
        mailer="$(read_env_value "$INM_ENV_FILE" "MAIL_DRIVER")"
    fi
    host="$(read_env_value "$INM_ENV_FILE" "MAIL_HOST")"
    port="$(read_env_value "$INM_ENV_FILE" "MAIL_PORT")"
    user="$(read_env_value "$INM_ENV_FILE" "MAIL_USERNAME")"
    pass="$(read_env_value "$INM_ENV_FILE" "MAIL_PASSWORD")"
    enc="$(read_env_value "$INM_ENV_FILE" "MAIL_ENCRYPTION")"
    from="$(read_env_value "$INM_ENV_FILE" "MAIL_FROM_ADDRESS")"
    from_name="$(read_env_value "$INM_ENV_FILE" "MAIL_FROM_NAME")"

    if [ -n "${INM_NOTIFY_EMAIL_FROM:-}" ]; then
        from="${INM_NOTIFY_EMAIL_FROM}"
    fi
    if [ -n "${INM_NOTIFY_EMAIL_FROM_NAME:-}" ]; then
        from_name="${INM_NOTIFY_EMAIL_FROM_NAME}"
    fi
    if [ -z "$from" ] && [[ "$user" == *@* ]]; then
        from="$user"
    fi

    if [ -n "$mailer" ] && [ "${mailer,,}" != "smtp" ]; then
        log warn "[NOTIFY] MAIL_MAILER is '$mailer'; SMTP notifications are disabled."
        return 1
    fi
    if [ -z "$host" ]; then
        log warn "[NOTIFY] SMTP host missing (MAIL_HOST)."
        return 1
    fi
    port="${port:-587}"
    enc="${enc:-tls}"
    if [ -z "$from" ]; then
        log warn "[NOTIFY] Email sender missing (MAIL_FROM_ADDRESS or INM_NOTIFY_EMAIL_FROM)."
        return 1
    fi

    local php_exec="${INM_PHP_EXECUTABLE:-}"
    if [ -z "$php_exec" ]; then
        php_exec="$(command -v php 2>/dev/null || true)"
    fi
    if [ -z "$php_exec" ]; then
        log err "[NOTIFY] php not found; cannot send email."
        return 1
    fi

    local output=""
    # shellcheck disable=SC2016
    if ! output=$(printf '%s' "$body" | INM_SMTP_HOST="$host" INM_SMTP_PORT="$port" \
        INM_SMTP_USER="$user" INM_SMTP_PASS="$pass" INM_SMTP_ENCRYPTION="$enc" \
        INM_SMTP_FROM="$from" INM_SMTP_FROM_NAME="$from_name" INM_SMTP_TO="$to" \
        INM_SMTP_SUBJECT="$subject" INM_SMTP_TIMEOUT="${INM_NOTIFY_SMTP_TIMEOUT:-10}" \
        INM_SMTP_BODY_HTML="$body_html" \
        "$php_exec" -r '
$host = getenv("INM_SMTP_HOST");
$port = (int) (getenv("INM_SMTP_PORT") ?: 587);
$user = getenv("INM_SMTP_USER");
$pass = getenv("INM_SMTP_PASS");
$enc = strtolower(getenv("INM_SMTP_ENCRYPTION") ?: "");
$from = getenv("INM_SMTP_FROM");
$fromName = getenv("INM_SMTP_FROM_NAME");
$toRaw = getenv("INM_SMTP_TO");
$subject = getenv("INM_SMTP_SUBJECT");
$timeout = (int) (getenv("INM_SMTP_TIMEOUT") ?: 10);
$bodyHtml = getenv("INM_SMTP_BODY_HTML");
$body = stream_get_contents(STDIN);
if (!$host || !$toRaw || !$from) { fwrite(STDERR, "ERR: missing smtp params"); exit(1); }
$server = ($enc === "ssl") ? "ssl://{$host}:{$port}" : "{$host}:{$port}";
$fp = stream_socket_client($server, $errno, $errstr, $timeout);
if (!$fp) { fwrite(STDERR, "ERR: {$errstr}"); exit(1); }
stream_set_timeout($fp, $timeout);
$read = function() use ($fp) {
    $data = "";
    while (!feof($fp)) {
        $line = fgets($fp, 515);
        if ($line === false) { break; }
        $data .= $line;
        if (preg_match("/^\\d{3} /", $line)) { break; }
    }
    return $data;
};
$send = function($cmd) use ($fp, $read) {
    fwrite($fp, $cmd . "\r\n");
    return $read();
};
$expect = function($resp, $code) {
    if (!preg_match("/^" . $code . "[ -]/m", $resp)) {
        fwrite(STDERR, "ERR: " . trim($resp));
        exit(1);
    }
};
$resp = $read();
$expect($resp, "220");
$hostName = gethostname() ?: "localhost";
$resp = $send("EHLO " . $hostName);
if (!preg_match("/^250[ -]/m", $resp)) {
    $resp = $send("HELO " . $hostName);
    $expect($resp, "250");
}
if ($enc === "tls" || $enc === "starttls") {
    if (!preg_match("/STARTTLS/i", $resp)) { fwrite(STDERR, "ERR: STARTTLS not supported"); exit(1); }
    $resp = $send("STARTTLS");
    $expect($resp, "220");
    if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) {
        fwrite(STDERR, "ERR: TLS failed");
        exit(1);
    }
    $resp = $send("EHLO " . $hostName);
    $expect($resp, "250");
}
if ($user !== "" && $user !== false) {
    $resp = $send("AUTH LOGIN");
    $expect($resp, "334");
    $resp = $send(base64_encode($user));
    $expect($resp, "334");
    $resp = $send(base64_encode($pass));
    $expect($resp, "235");
}
$toList = array_filter(array_map("trim", explode(",", $toRaw)));
if (function_exists("mb_encode_mimeheader") && $fromName) {
    $fromName = mb_encode_mimeheader($fromName, "UTF-8");
}
$fromHeader = $from;
if ($fromName) {
    $fromHeader = "\"" . str_replace("\"", "\\\"", $fromName) . "\" <" . $from . ">";
}
$headers = "From: " . $fromHeader . "\r\n";
$headers .= "To: " . implode(", ", $toList) . "\r\n";
$headers .= "Subject: " . $subject . "\r\n";
$headers .= "Date: " . date("r") . "\r\n";
$headers .= "MIME-Version: 1.0\r\n";
if ($bodyHtml !== false && $bodyHtml !== "") {
    $boundary = "INM-";
    if (function_exists("random_bytes")) {
        $boundary .= bin2hex(random_bytes(6));
    } else {
        $boundary .= uniqid();
    }
    $headers .= "Content-Type: multipart/alternative; boundary=\"" . $boundary . "\"\r\n";
    $msg = $headers . "\r\n";
    $msg .= "--" . $boundary . "\r\n";
    $msg .= "Content-Type: text/plain; charset=UTF-8\r\n\r\n";
    $msg .= $body . "\r\n";
    $msg .= "--" . $boundary . "\r\n";
    $msg .= "Content-Type: text/html; charset=UTF-8\r\n\r\n";
    $msg .= $bodyHtml . "\r\n";
    $msg .= "--" . $boundary . "--\r\n";
} else {
    $headers .= "Content-Type: text/plain; charset=UTF-8\r\n";
    $msg = $headers . "\r\n" . $body;
}
$resp = $send("MAIL FROM:<" . $from . ">");
$expect($resp, "250");
foreach ($toList as $rcpt) {
    $resp = $send("RCPT TO:<" . $rcpt . ">");
    if (!preg_match("/^25[0-9][ -]/m", $resp)) { fwrite(STDERR, "ERR: " . trim($resp)); exit(1); }
}
$resp = $send("DATA");
$expect($resp, "354");
fwrite($fp, $msg . "\r\n.\r\n");
$resp = $read();
$expect($resp, "250");
$send("QUIT");
exit(0);
' 2>&1); then
        if [ "${DEBUG:-false}" = true ] && [ -n "$output" ]; then
            log warn "[NOTIFY] Email send failed: $output"
        else
            log warn "[NOTIFY] Email send failed."
        fi
        return 1
    fi
    log ok "[NOTIFY] Email sent to ${to}"
    return 0
}
