#!/usr/bin/env bash

# ---------------------------------------------------------------------
# notify_send_email()
# Send an email via SMTP using app .env settings.
# Consumes: args: subject, body, body_html; env: INM_NOTIFY_* / INM_ENV_FILE; deps: read_env_value/expand_path_vars.
# Computes: SMTP session via inline PHP.
# Returns: 0 on success, 1 on failure.
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
    local env_file="${INM_ENV_FILE:-}"
    env_file="$(expand_path_vars "$env_file")"
    if [ -z "$env_file" ] || [ ! -f "$env_file" ]; then
        log warn "[NOTIFY] App .env missing; cannot read MAIL_* settings."
        return 1
    fi

    local mailer host port user pass enc from from_name
    mailer="$(read_env_value "$env_file" "MAIL_MAILER")"
    if [ -z "$mailer" ]; then
        mailer="$(read_env_value "$env_file" "MAIL_DRIVER")"
    fi
    host="$(read_env_value "$env_file" "MAIL_HOST")"
    port="$(read_env_value "$env_file" "MAIL_PORT")"
    user="$(read_env_value "$env_file" "MAIL_USERNAME")"
    pass="$(read_env_value "$env_file" "MAIL_PASSWORD")"
    enc="$(read_env_value "$env_file" "MAIL_ENCRYPTION")"
    from="$(read_env_value "$env_file" "MAIL_FROM_ADDRESS")"
    from_name="$(read_env_value "$env_file" "MAIL_FROM_NAME")"

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
