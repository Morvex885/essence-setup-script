#!/bin/bash
# ─── iptables DNAT helpers for cascade ──────────────────────────────────────

# Apply DNAT rules
# Args: cname remote remote_port local_port
_apply_dnat_rules() {
    local cname="$1" remote="$2" remote_port="$3" local_port="$4"

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
        sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf 2>/dev/null \
            || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi

    # PREROUTING DNAT (tcp + udp)
    iptables -t nat -A PREROUTING -p tcp --dport "$local_port" \
        -j DNAT --to-destination "${remote}:${remote_port}" \
        -m comment --comment "cascade-dnat:${cname}"
    iptables -t nat -A PREROUTING -p udp --dport "$local_port" \
        -j DNAT --to-destination "${remote}:${remote_port}" \
        -m comment --comment "cascade-dnat:${cname}"

    # POSTROUTING MASQUERADE
    iptables -t nat -A POSTROUTING -p tcp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}"
    iptables -t nat -A POSTROUTING -p udp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}"
}

# Remove DNAT rules
# Args: cname remote remote_port local_port
_remove_dnat_rules() {
    local cname="$1" remote="$2" remote_port="$3" local_port="$4"

    iptables -t nat -D PREROUTING -p tcp --dport "$local_port" \
        -j DNAT --to-destination "${remote}:${remote_port}" \
        -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport "$local_port" \
        -j DNAT --to-destination "${remote}:${remote_port}" \
        -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p tcp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
    iptables -t nat -D POSTROUTING -p udp -d "$remote" --dport "$remote_port" \
        -j MASQUERADE -m comment --comment "cascade-dnat:${cname}" 2>/dev/null || true
}

# Persist iptables rules via iptables-persistent
_persist_dnat_rules() {
    if ! command -v netfilter-persistent &>/dev/null; then
        apt_wait 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q iptables-persistent > /dev/null 2>&1
    fi
    netfilter-persistent save > /dev/null 2>&1
}
