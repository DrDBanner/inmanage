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
    value="${value//&/\&amp;}"
    value="${value//</\&lt;}"
    value="${value//>/\&gt;}"
    value="${value//\"/\&quot;}"
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

notify_email_font_stack() {
    printf "%s" "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
}

notify_email_badge_style() {
    local status="${1^^}"
    local bg fg border
    case "$status" in
        ERR) bg="#fee2e2"; fg="#991b1b"; border="#fca5a5" ;;
        WARN) bg="#ffedd5"; fg="#9a3412"; border="#fdba74" ;;
        OK) bg="#dcfce7"; fg="#166534"; border="#86efac" ;;
        INFO) bg="#dbeafe"; fg="#1e40af"; border="#93c5fd" ;;
        *) bg="#e5e7eb"; fg="#374151"; border="#d1d5db" ;;
    esac
    printf "background-color:%s;color:%s;border:1px solid %s;border-radius:999px;padding:2px 8px;font-size:12px;line-height:16px;font-weight:600;display:inline-block;" \
        "$bg" "$fg" "$border"
}

notify_email_button_html() {
    local url="$1"
    local label="$2"
    if [ -z "$url" ]; then
        printf ""
        return 0
    fi
    printf "<a href=\"%s\" style=\"background-color:#1d4ed8;color:#ffffff;text-decoration:none;padding:10px 14px;border-radius:8px;display:inline-block;font-weight:600;font-size:14px;line-height:20px;\">%s</a>" \
        "$(notify_email_html_escape "$url")" "$(notify_email_html_escape "$label")"
}

notify_email_kv_row() {
    local label="$1"
    local value_html="$2"
    printf "<tr><td align=\"left\" valign=\"top\" style=\"padding:4px 12px 4px 0;color:#6b7280;font-size:12px;line-height:18px;font-weight:600;text-transform:uppercase;letter-spacing:0.02em;white-space:nowrap;min-width:108px;\">%s</td>" \
        "$(notify_email_html_escape "$label")"
    printf "<td align=\"left\" valign=\"top\" style=\"padding:4px 0;color:#111827;font-size:15px;line-height:22px;word-break:break-word;overflow-wrap:anywhere;\">%s</td></tr>" \
        "$value_html"
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
    local base_dir="${INM_BASE_DIRECTORY%/}"
    local app_url="${APP_URL:-}"
    local font_stack
    font_stack="$(notify_email_font_stack)"
    app_url="${app_url%/}"
    if [ -n "$details" ]; then
        details="${details//$'\r'/}"
        details="${details//\\n/$'\n'}"
    fi

    local status_display="${status:-INFO}"
    local status_badge_style
    status_badge_style="$(notify_email_badge_style "$status_display")"
    local preheader
    preheader="$title - ${status_display}"
    if [ -n "$counts" ]; then
        preheader="$preheader ($counts)"
    fi
    local counts_html=""
    if [ -n "$counts" ]; then
        counts_html="$(notify_email_html_escape "$counts")"
        counts_html="<span style=\"font-family:ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, 'Liberation Mono', 'Courier New', monospace;font-size:12px;line-height:18px;background-color:#f3f4f6;border:1px solid #e5e7eb;border-radius:6px;padding:2px 6px;display:inline-block;\">${counts_html}</span>"
    fi

    {
        printf "<!doctype html>"
        printf "<html lang=\"en\" xmlns=\"http://www.w3.org/1999/xhtml\">"
        printf "<head>"
        printf "<meta charset=\"utf-8\">"
        printf "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        printf "<title>Inmanage Notification</title>"
        printf "<style type=\"text/css\">"
        printf "body,.body{margin:0;padding:0;width:100%%;min-width:100%%;height:100%%;-webkit-text-size-adjust:100%%;-ms-text-size-adjust:100%%;box-sizing:border-box;font-family:%s;font-size:16px;line-height:24px;background-color:#f8fafc;color:#111827;}" "$font_stack"
        printf "table{border-collapse:collapse;mso-table-lspace:0pt;mso-table-rspace:0pt;}"
        printf "img{border:0;height:auto;line-height:100%%;outline:none;text-decoration:none;display:block;}"
        printf "th,td,p{margin:0;text-align:left;line-height:24px;font-size:16px;}"
        printf "a{color:#1d4ed8;text-decoration:underline;}"
        printf "table[align=center]{margin:0 auto;}"
        printf "</style>"
        printf "</head>"
        printf "<body style=\"margin:0;padding:0;background-color:#f8fafc;width:100%%;min-width:100%%;height:100%%;-webkit-text-size-adjust:100%%;-ms-text-size-adjust:100%%;\">"
        printf "<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;\">%s</div>" \
            "$(notify_email_html_escape "$preheader")"
        printf "<div style=\"display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;\">&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;</div>"
        printf "<table class=\"body\" role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"width:100%%;min-width:100%%;background-color:#f8fafc;\">"
        printf "<tr><td align=\"center\" style=\"padding:16px 8px;\">"
        printf "<table role=\"presentation\" width=\"100%%\" align=\"center\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"max-width:680px;width:100%%;margin:0 auto;\">"
        printf "<tr><td align=\"left\" style=\"padding:0 0 12px;\">"
        printf "<table role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\">"
        printf "<tr><td align=\"left\" style=\"font-family:%s;font-size:18px;line-height:24px;font-weight:700;color:#111827;\">inmanage</td>" "$font_stack"
        printf "<td align=\"right\" style=\"font-family:%s;\">%s</td></tr>" "$font_stack" \
            "<span style=\"${status_badge_style}\">$(notify_email_html_escape "$status_display")</span>"
        printf "</table>"
        printf "</td></tr>"
        printf "<tr><td align=\"left\" style=\"padding:0;\">"
        printf "<table role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"background-color:#ffffff;border:1px solid #e5e7eb;border-radius:10px;\">"
        printf "<tr><td style=\"padding:16px;font-family:%s;\">" "$font_stack"
        printf "<div style=\"font-size:20px;line-height:28px;font-weight:700;color:#111827;padding:0 0 4px;\">%s</div>" \
            "$(notify_email_html_escape "$title")"
        printf "<div style=\"font-size:14px;line-height:20px;color:#6b7280;padding:0 0 12px;\">Host: %s &middot; %s</div>" \
            "$(notify_email_html_escape "$host")" "$(notify_email_html_escape "$ts")"
        printf "<table role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\">"
        notify_email_kv_row "Event" "$(notify_email_html_escape "$title")"
        notify_email_kv_row "Status" "<span style=\"${status_badge_style}\">$(notify_email_html_escape "$status_display")</span>"
        if [ -n "$counts_html" ]; then
            notify_email_kv_row "Counts" "$counts_html"
        fi
        notify_email_kv_row "Host" "$(notify_email_html_escape "$host")"
        if [ -n "$base_dir" ]; then
            notify_email_kv_row "Base dir" "$(notify_email_html_escape "$base_dir")"
        fi
        if [ -n "$app_url" ]; then
            local app_button
            app_button="$(notify_email_button_html "$app_url" "Open App")"
            notify_email_kv_row "APP_URL" "${app_button}<div style=\"padding-top:6px;font-size:13px;line-height:18px;\">$(notify_email_html_escape "$app_url")</div>"
        fi
        notify_email_kv_row "Timestamp" "$(notify_email_html_escape "$ts")"
        printf "</table>"

        if [ -n "$details" ]; then
            printf "<div style=\"height:12px;line-height:12px;\">&nbsp;</div>"
            printf "<div style=\"font-size:16px;line-height:24px;font-weight:700;color:#111827;padding:0 0 6px;\">Checks</div>"
            printf "<table role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"border-collapse:collapse;\">"
            printf "<thead><tr><th align=\"left\" style=\"padding:6px 12px 6px 6px;border-bottom:1px solid #e5e7eb;white-space:nowrap;width:108px;min-width:108px;\">Status</th>"
            printf "<th align=\"left\" style=\"padding:6px 0 6px 8px;border-bottom:1px solid #e5e7eb;\">Detail</th></tr></thead>"
            printf "<tbody>"
            local line status_text status_cell detail check
            local current=-1
            local row_checks=()
            local row_status=()
            local row_details=()
            while IFS= read -r line; do
                if [ -z "$line" ]; then
                    current=$((current + 1))
                    row_checks[current]="__SPACER__"
                    row_status[current]=""
                    row_details[current]=""
                    continue
                fi
                if [[ "$line" =~ ^==[[:space:]]*(.+)[[:space:]]*==[[:space:]]*$ ]]; then
                    current=$((current + 1))
                    row_checks[current]="__SECTION__"
                    row_status[current]=""
                    row_details[current]="${BASH_REMATCH[1]}"
                    continue
                fi
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
            local zebra=0
            local current_section=""
            for idx in "${!row_details[@]}"; do
                check="${row_checks[$idx]}"
                status_text="${row_status[$idx]}"
                detail="${row_details[$idx]}"
                if [ "$check" = "__SPACER__" ]; then
                    printf "<tr><td colspan=\"2\" style=\"padding:6px 0;\"></td></tr>"
                    continue
                fi
                if [ "$check" = "__SECTION__" ]; then
                    current_section="$detail"
                    printf "<tr><td colspan=\"2\" align=\"left\" style=\"padding:8px 0 4px 6px;font-weight:600;font-size:14px;color:#111827;border-top:1px solid #e5e7eb;background-color:#f3f4f6;\">%s</td></tr>" \
                        "$(notify_email_html_escape "$detail")"
                    continue
                fi
                if [ -z "$current_section" ] && [ -n "$check" ]; then
                    detail="$check: $detail"
                fi
                detail="$(notify_email_html_escape "$detail")"
                detail="${detail//$'\n'/<br>}"
                status_cell="&nbsp;"
                if [ -n "$status_text" ]; then
                    status_cell="<span style=\"$(notify_email_badge_style "$status_text")\">$(notify_email_html_escape "$status_text")</span>"
                fi
                local row_bg
                if [ $((zebra % 2)) -eq 0 ]; then
                    row_bg="#ffffff"
                else
                    row_bg="#f9fafb"
                fi
                zebra=$((zebra + 1))
                printf "<tr><td bgcolor=\"%s\" style=\"background-color:%s;padding:6px 12px 6px 6px;border-bottom:1px solid #f3f4f6;vertical-align:top;white-space:nowrap;width:108px;min-width:108px;\">%s</td>" \
                    "$row_bg" "$row_bg" "$status_cell"
                printf "<td bgcolor=\"%s\" style=\"background-color:%s;padding:6px 0 6px 8px;border-bottom:1px solid #f3f4f6;vertical-align:top;white-space:normal;word-break:break-word;overflow-wrap:anywhere;font-size:14px;line-height:20px;\">%s</td></tr>" \
                    "$row_bg" "$row_bg" "$detail"
            done
            printf "</tbody></table>"
        fi
        printf "</td></tr></table>"
        printf "</td></tr>"
        printf "<tr><td align=\"center\" style=\"padding:12px 0 0;font-family:%s;font-size:12px;line-height:18px;color:#6b7280;\">Generated by inmanage on %s</td></tr>" \
            "$font_stack" "$(notify_email_html_escape "$host")"
        printf "</table>"
        printf "</td></tr></table>"
        printf "</body></html>"
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
    $msg .= "Content-Type: text/html; charset=UTF-8\r\n";
    $msg .= "Content-Transfer-Encoding: base64\r\n\r\n";
    $msg .= chunk_split(base64_encode($bodyHtml)) . "\r\n";
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
