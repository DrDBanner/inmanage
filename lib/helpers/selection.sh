#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SELECTION_HELPER_LOADED:-} ]] && return
__SELECTION_HELPER_LOADED=1

# ---------------------------------------------------------------------
# select_from_candidates()
#
# Prompts user to choose from a list of options; returns selected value.
# ---------------------------------------------------------------------
select_from_candidates() {
    local prompt="$1"
    shift
    local options=("$@")

    local count="${#options[@]}"
    if [ "$count" -eq 0 ]; then
        log err "[SEL] No selectable candidates available."
        return 1
    fi

    # Determine input source for interactive selection.
    local read_fd=0
    local using_tty_fd=false
    local timeout="${NAMED_ARGS[select_timeout]:-${NAMED_ARGS[select-timeout]:-60}}"
    if [[ ! -t 0 && -r /dev/tty ]]; then
        # fall back to controlling terminal if stdin is not a TTY (e.g., sudo)
        exec 3<>/dev/tty || true
        if [[ -t 3 ]]; then
            read_fd=3
            using_tty_fd=true
            log info "[SEL] Using /dev/tty for interactive selection."
        fi
    fi

    sel_print() {
        local fmt="$1"; shift
        # Send prompts to stderr and tty (if available), keep stdout clean for selection output
        printf "$fmt" "$@" 1>&2
        if [[ "$using_tty_fd" == true ]]; then
            printf "$fmt" "$@" 1>&3
        fi
    }

    # Non-interactive handling: only auto-select when explicitly allowed
    if [[ "$using_tty_fd" == false && ! -t 0 ]]; then
        if [[ "${NAMED_ARGS[auto_select]:-${NAMED_ARGS[auto-select]:-}}" == "true" ]]; then
            local selected="${options[0]}"
            log info "[SEL] No TTY available; auto-selecting first candidate: $selected"
            printf "%s\n" "$selected"
            return 0
        fi
        log err "[SEL] No TTY available for selection (stdin is not a TTY and /dev/tty unavailable). Pass --auto-select=true to pick the first candidate automatically or provide --file=..."
        return 1
    fi

    log info "[SEL] Awaiting interactive choice (${count} option(s))."
    sel_print "\n%s\n" "${prompt}"
    sel_print "  %-4s | %s\n" "No." "Backup"
    sel_print "  %s\n" "-------------------------------------------"
    for i in "${!options[@]}"; do
        sel_print "  %-4d | %s\n" "$((i + 1))" "${options[$i]}"
    done

    local choice
    while true; do
        sel_print "${YELLOW}Enter number [1-%s] or Ctrl+C to cancel: ${RESET}" "$count"
        if [[ "$using_tty_fd" == true ]]; then
            if ! read -u "$read_fd" -r -t "$timeout" choice; then
                log err "[SEL] Failed to read selection from /dev/tty (timeout ${timeout}s?)."
                [[ "$using_tty_fd" == true ]] && exec 3<&-
                return 1
            fi
        else
            if ! read -r -t "$timeout" choice; then
                log err "[SEL] Failed to read selection from stdin (timeout ${timeout}s?)."
                return 1
            fi
        fi
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            local selected="${options[$((choice - 1))]}"
            log ok "[SEL] Selected: $selected"
            printf "%s\n" "$selected"
            [[ "$using_tty_fd" == true ]] && exec 3<&-
            return 0
        else
            log warn "[SEL] Invalid choice: $choice"
        fi
    done
}
