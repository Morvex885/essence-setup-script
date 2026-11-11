#!/bin/bash
# ─── iptables DNAT helpers for cascade ──────────────────────────────────────

# Apply DNAT rules. Args: cname remote remote_port local_port
_apply_dnat_rules() {
    local cname="$1" remote="$2" remote_port="$3" local_port="$4"
    local firewall=iptables forward=net.ipv4.ip_forward pattern='net[.]ipv4[.]ip_forward' destination
    [[ -n "$local_port" ]] || return 1
    remote="${remote#[}"; remote="${remote%]}"
    destination="${remote}:${remote_port}"
    if [[ "$remote" == *:* ]]; then
        firewall=ip6tables
        forward=net.ipv6.conf.all.forwarding
        pattern='net[.]ipv6[.]conf[.]all[.]forwarding'
        destination="[${remote}]:${remote_port}"
    fi
    sysctl -w "${forward}=1" > /dev/null || return 1
    if ! grep -qxF "${forward}=1" /etc/sysctl.conf 2>/dev/null; then
        if grep -q "^#*[[:space:]]*${pattern}=" /etc/sysctl.conf 2>/dev/null; then
            sed -i "s/^#*[[:space:]]*${pattern}=.*/${forward}=1/" /etc/sysctl.conf || return 1
        else
            printf '%s=1\n' "$forward" >> /etc/sysctl.conf || return 1
        fi
    fi
    "$firewall" -t nat -A PREROUTING -p tcp --dport "$local_port" \
        -j DNAT --to-destination "$destination" -m comment --comment "cascade-dnat:${cname}" || return 1
    "$firewall" -t nat -A PREROUTING -p udp --dport "$local_port" \
        -j DNAT --to-destination "$destination" -m comment --comment "cascade-dnat:${cname}" || return 1
    "$firewall" -t nat -A POSTROUTING -p tcp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}" || return 1
    "$firewall" -t nat -A POSTROUTING -p udp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}"
}

# Remove DNAT rules. Args: cname remote remote_port local_port
_remove_dnat_rules() {
    local cname="$1" remote="$2" remote_port="$3" local_port="$4"
    local firewall=iptables destination
    [[ -n "$local_port" ]] || return 1
    remote="${remote#[}"; remote="${remote%]}"
    destination="${remote}:${remote_port}"
    if [[ "$remote" == *:* ]]; then
        firewall=ip6tables
        destination="[${remote}]:${remote_port}"
    fi
    "$firewall" -t nat -D PREROUTING -p tcp --dport "$local_port" \
        -j DNAT --to-destination "$destination" -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
    "$firewall" -t nat -D PREROUTING -p udp --dport "$local_port" \
        -j DNAT --to-destination "$destination" -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
    "$firewall" -t nat -D POSTROUTING -p tcp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
    "$firewall" -t nat -D POSTROUTING -p udp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
}

# netfilter-persistent saves both IPv4 and IPv6 rules.
_persist_dnat_rules() {
    if ! command -v netfilter-persistent &>/dev/null; then
        apt_wait 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q iptables-persistent > /dev/null 2>&1
    fi
    netfilter-persistent save > /dev/null 2>&1
}
