#!/usr/bin/env bash

# Prevent double sourcing
[[ -n ${__SYS_UTILS_LOADED:-} ]] && return
__SYS_UTILS_LOADED=1

# ---------------------------------------------------------------------
# sys_collect_info()
# Collect basic system and runtime information.
# Consumes: args: out_assoc_name; tools: hostname/uname/getconf/nproc/sysctl/systemd-detect-virt.
# Computes: host/os/kernel/arch/cpu/mem/ip4/ip6/virt.
# Returns: 0 after populating the assoc array.
# ---------------------------------------------------------------------
sys_collect_info() {
    local out_name="$1"
    if [[ -z "$out_name" ]]; then
        return 1
    fi
    # shellcheck disable=SC2034
    local -n out="$out_name"

    local host os kernel arch cpu memtotal=""
    host="$(hostname 2>/dev/null || true)"
    kernel="$(uname -r 2>/dev/null || true)"
    arch="$(uname -m 2>/dev/null || true)"
    cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)"
    if [ -f /proc/meminfo ]; then
        memtotal=$(awk '/MemTotal/ {printf "%.1fG", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    elif command -v sysctl >/dev/null 2>&1; then
        local mem_bytes=""
        mem_bytes="$(sysctl -n hw.physmem 2>/dev/null || true)"
        if ! [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
            mem_bytes="$(sysctl -n hw.physmem64 2>/dev/null || true)"
        fi
        if [[ "$mem_bytes" =~ ^[0-9]+$ ]]; then
            memtotal=$(awk -v b="$mem_bytes" 'BEGIN {printf "%.1fG", b/1024/1024/1024}')
        fi
    fi
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="${PRETTY_NAME:-$NAME $VERSION_ID}"
    elif command -v freebsd-version >/dev/null 2>&1; then
        os="FreeBSD $(freebsd-version 2>/dev/null | head -n1)"
    elif command -v uname >/dev/null 2>&1; then
        local os_name os_release
        os_name="$(uname -s 2>/dev/null || true)"
        os_release="$(uname -r 2>/dev/null || true)"
        if [ -n "$os_name" ] && [ -n "$os_release" ]; then
            os="${os_name} ${os_release}"
        else
            os="${os_name:-unknown}"
        fi
    fi

    local ip4 ip6
    ip4="$(resolve_primary_ip4)"
    ip6="$(resolve_primary_ip6)"

    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt --container 2>/dev/null)
        [[ "$virt" == "none" ]] && virt=""
    fi
    if [ -z "$virt" ] && [ -f /proc/1/cgroup ]; then
        grep -qiE 'docker|lxc|podman' /proc/1/cgroup && virt="container"
    fi

    out[host]="$host"
    out[os]="$os"
    out[kernel]="$kernel"
    out[arch]="$arch"
    out[cpu]="$cpu"
    out[memtotal]="$memtotal"
    out[ip4]="$ip4"
    out[ip6]="$ip6"
    out[virt]="$virt"

    : "${out[host]}" "${out[os]}" "${out[kernel]}" "${out[arch]}" \
      "${out[cpu]}" "${out[memtotal]}" "${out[ip4]}" "${out[ip6]}" \
      "${out[virt]}"
}

# ---------------------------------------------------------------------
# sys_emit_preflight()
# Emit preflight system info lines.
# Consumes: args: add_fn; deps: sys_collect_info.
# Computes: formatted SYS output.
# Returns: 0 after emitting.
# ---------------------------------------------------------------------
sys_emit_preflight() {
    local add_fn="$1"
    if [[ -z "$add_fn" ]]; then
        add_fn="log info"
    fi
    local -A info=()
    sys_collect_info info || return 1

    "$add_fn" INFO "SYS" "Host: ${info[host]:-unknown} | OS: ${info[os]:-unknown}"
    "$add_fn" INFO "SYS" "Kernel: ${info[kernel]:-?} | Arch: ${info[arch]:-?} | CPU cores: ${info[cpu]:-?} | RAM: ${info[memtotal]:-unknown}"
    if [ -n "${info[ip4]:-}" ]; then
        "$add_fn" INFO "SYS" "IPv4: ${info[ip4]}"
    else
        "$add_fn" INFO "SYS" "IPv4: not detected"
    fi
    if [ -n "${info[ip6]:-}" ]; then
        "$add_fn" INFO "SYS" "IPv6: ${info[ip6]}"
    else
        "$add_fn" INFO "SYS" "IPv6: not detected"
    fi
    if [ -n "${info[virt]:-}" ]; then
        "$add_fn" INFO "SYS" "Container detected: ${info[virt]}"
    else
        "$add_fn" INFO "SYS" "Container: not detected"
    fi
}
