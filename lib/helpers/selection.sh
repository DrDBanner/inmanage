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

    echo -e "\n${CYAN}${prompt}${RESET}"
    for i in "${!options[@]}"; do
        printf "  [%d] %s\n" "$((i + 1))" "${options[$i]}"
    done

    local choice
    while true; do
        echo -ne "${YELLOW}Enter number [1-$count] or Ctrl+C to cancel: ${RESET}"
        read -r choice
        if [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ]; then
            local selected="${options[$((choice - 1))]}"
            log ok "[SEL] Selected: $selected"
            printf "%s\n" "$selected"
            return 0
        else
            log warn "[SEL] Invalid choice: $choice"
        fi
    done
}
