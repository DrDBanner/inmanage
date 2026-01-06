#!/usr/bin/env bash

# ---------------------------------------------------------------------
# compute_installation_path()
# Normalize installation path for absolute/relative dirs.
# Consumes: args: base, dir.
# Computes: normalized path.
# Returns: path on stdout.
# ---------------------------------------------------------------------
compute_installation_path() {
    local base="$1"
    local dir="$2"

    if [[ "$dir" == /* ]]; then
        printf "%s\n" "${dir%/}"
    else
        printf "%s/%s\n" "${base%/}" "${dir#/}"
    fi
}

# ---------------------------------------------------------------------
# resolve_primary_ip4()
# Resolve primary IPv4 address (best effort).
# Consumes: tools: ip/hostname/route/ifconfig.
# Computes: IPv4 string.
# Returns: IP on stdout (empty if not found).
# ---------------------------------------------------------------------
resolve_primary_ip4() {
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\\./) {print $i; exit}}')
    fi
    if [ -z "$ip" ] && command -v route >/dev/null 2>&1; then
        local iface=""
        iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
        if [ -z "$iface" ]; then
            iface=$(route -n get -inet default 2>/dev/null | awk '/interface:/{print $2; exit}')
        fi
        if [ -z "$iface" ]; then
            iface=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2; exit}')
        fi
        if [ -n "$iface" ] && command -v ifconfig >/dev/null 2>&1; then
            ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2; exit}')
        fi
        if [ -z "$ip" ]; then
            ip=$(route -n get default 2>/dev/null | awk '/if address:/{print $3; exit}')
        fi
    fi
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | awk '/inet / {for(i=1;i<=NF;i++){if($i=="inet"){print $(i+1); exit} if($i ~ /^addr:/){sub(/^addr:/,"",$i); print $i; exit}}}')
    fi
    if [[ "$ip" == 127.* || "$ip" == 0.0.0.0 ]]; then
        ip=""
    fi
    printf "%s" "$ip"
}

# ---------------------------------------------------------------------
# resolve_primary_ip6()
# Resolve primary IPv6 address (best effort).
# Consumes: tools: ip/hostname/ifconfig.
# Computes: IPv6 string.
# Returns: IP on stdout (empty if not found).
# ---------------------------------------------------------------------
resolve_primary_ip6() {
    local ip6=""
    if command -v ip >/dev/null 2>&1; then
        ip6=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '/src/ {for (i=1; i<=NF; i++) if ($i=="src") {print $(i+1); exit}}')
    fi
    if [ -z "$ip6" ] && command -v hostname >/dev/null 2>&1; then
        ip6=$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i ~ /:/ && $i !~ /^fe80:/) {print $i; exit}}')
    fi
    if [ -z "$ip6" ] && command -v ifconfig >/dev/null 2>&1; then
        ip6=$(ifconfig 2>/dev/null | awk '/inet6 / {for(i=1;i<=NF;i++){if($i=="inet6"){print $(i+1); exit} if($i ~ /^addr:/){sub(/^addr:/,"",$i); print $i; exit}}}' | awk '$1 !~ /^fe80:/ {print $1; exit}')
    fi
    printf "%s" "$ip6"
}

# ---------------------------------------------------------------------
# version_compare()
# Compare dot-separated version numbers.
# Consumes: args: v1, op(gt|lt|eq), v2.
# Computes: numeric comparison across segments.
# Returns: 0 if comparison matches, 1 otherwise.
# ---------------------------------------------------------------------
version_compare() {
    local v1="$1" op="$2" v2="$3"
    local IFS=.
    local a=() b=() i comp="eq"
    read -r -a a <<<"$v1"
    read -r -a b <<<"$v2"
    local len=${#a[@]}
    (( ${#b[@]} > len )) && len=${#b[@]}
    for ((i=${#a[@]}; i<len; i++)); do a[i]=0; done
    for ((i=${#b[@]}; i<len; i++)); do b[i]=0; done
    for ((i=0; i<len; i++)); do
        if ((10#${a[i]} > 10#${b[i]})); then comp="gt"; break
        elif ((10#${a[i]} < 10#${b[i]})); then comp="lt"; break
        fi
    done
    [[ "$comp" == "$op" ]]
}
