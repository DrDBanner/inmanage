#!/usr/bin/env bash

# ---------------------------------------------------------------------
# Email formatting helpers
# ---------------------------------------------------------------------

# ---------------------------------------------------------------------
# notify_email_html_escape()
# Escape a string for safe HTML output in emails.
# Consumes: args: value.
# Computes: HTML-escaped string.
# Returns: prints escaped string to stdout.
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

# ---------------------------------------------------------------------
# notify_email_status_color()
# Map status to a hex color.
# Consumes: args: status.
# Computes: color value for the status.
# Returns: prints hex color to stdout.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_email_status_badge_class()
# Map status to a CSS class name.
# Consumes: args: status.
# Computes: class name for status badge.
# Returns: prints class name to stdout.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_email_font_stack()
# Emit the default font stack for email templates.
# Consumes: none.
# Computes: CSS font-family string.
# Returns: prints font stack to stdout.
# ---------------------------------------------------------------------
notify_email_font_stack() {
    printf "%s" "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
}

# ---------------------------------------------------------------------
# notify_email_badge_style()
# Build inline badge styles for a status value.
# Consumes: args: status.
# Computes: inline CSS for a status badge.
# Returns: prints inline style to stdout.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_email_button_html()
# Render a button-style anchor tag for email.
# Consumes: args: url, label.
# Computes: HTML anchor snippet.
# Returns: prints HTML or empty string.
# ---------------------------------------------------------------------
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

# ---------------------------------------------------------------------
# notify_email_kv_row()
# Render a key-value row in the email table.
# Consumes: args: label, value_html.
# Computes: HTML table row.
# Returns: prints HTML row to stdout.
# ---------------------------------------------------------------------
notify_email_kv_row() {
    local label="$1"
    local value_html="$2"
    printf "<tr><td align=\"left\" valign=\"top\" style=\"padding:4px 12px 4px 0;color:#6b7280;font-size:12px;line-height:18px;font-weight:600;text-transform:uppercase;letter-spacing:0.02em;white-space:nowrap;min-width:108px;\">%s</td>" \
        "$(notify_email_html_escape "$label")"
    printf "<td align=\"left\" valign=\"top\" style=\"padding:4px 0;color:#111827;font-size:15px;line-height:22px;word-break:break-word;overflow-wrap:anywhere;\">%s</td></tr>" \
        "$value_html"
}

# ---------------------------------------------------------------------
# notify_email_format_html()
# Build the full HTML email body for a notification.
# Consumes: args: title, status, counts, details; env: APP_URL.
# Computes: full HTML document string.
# Returns: prints HTML to stdout.
# ---------------------------------------------------------------------
notify_email_format_html() {
    local title="$1"
    local status="${2:-}"
    local counts="${3:-}"
    local details="${4:-}"
    local host
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")"
    local run_user
    run_user="$(id -un 2>/dev/null || whoami 2>/dev/null || echo "unknown")"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
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
        printf "<tr><td align=\"left\" style=\"padding:0;\">"
        printf "<table role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\" style=\"background-color:#ffffff;border:1px solid #e5e7eb;border-radius:10px;\">"
        printf "<tr><td style=\"padding:16px;font-family:%s;\">" "$font_stack"
        printf "<div style=\"font-size:20px;line-height:28px;font-weight:700;color:#111827;padding:0 0 4px;\">%s</div>" \
            "$(notify_email_html_escape "$title")"
        printf "<div style=\"font-size:14px;line-height:20px;color:#6b7280;padding:0 0 12px;\">Host: %s &middot; User: %s &middot; %s</div>" \
            "$(notify_email_html_escape "$host")" "$(notify_email_html_escape "$run_user")" "$(notify_email_html_escape "$ts")"
        printf "<table role=\"presentation\" width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\" border=\"0\">"
        notify_email_kv_row "Event" "$(notify_email_html_escape "$title")"
        notify_email_kv_row "Status" "<span style=\"${status_badge_style}\">$(notify_email_html_escape "$status_display")</span>"
        if [ -n "$counts_html" ]; then
            notify_email_kv_row "Counts" "$counts_html"
        fi
        notify_email_kv_row "Host" "$(notify_email_html_escape "$host")"
        notify_email_kv_row "User" "$(notify_email_html_escape "$run_user")"
        if [ -n "$app_url" ]; then
            local app_link
            app_link="$(notify_email_html_escape "$app_url")"
            notify_email_kv_row "APP_URL" "<a href=\"${app_link}\">${app_link}</a>"
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
