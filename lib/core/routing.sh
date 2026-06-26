#!/system/bin/sh
# lib/core/routing.sh — tun0/tproxy routing, per-client bypass
#
# Interfaces:
#   route_apply(mode)   — apply routing for "tun0" or "tproxy" (mode defaults to cfg_get route_mode tun0)
#   route_clear([mode]) — fully undo what route_apply did
#   bypass_add(ip)      — exempt an IP from tunnelling (iptables RETURN + ip rule direct)
#   bypass_del(ip)      — remove bypass for an IP
#
# tun0 mode cooperation with vpn-gateway:
#   We write "TUN_TABLE tun0" into /data/misc/net/rt_tables so vpn-gateway's
#   inotifyd loop picks it up and installs the RFC1918→table ip rules and
#   FORWARD iptables rules automatically.  We then just add a default route
#   inside table TUN_TABLE so there's somewhere for that traffic to go.
#   If vpn-gateway is absent we add the RFC1918 ip rules + FORWARD rules
#   ourselves.
#
# tproxy mode:
#   Full iptables/mangle TPROXY setup ported from zte tproxy.sh.
#   Only applied when DRYRUN=0 (default); set DRYRUN=1 to print-only.
#
# Requires: env.sh sourced first (provides DCP_DATA, DCP_MOD, JQ, dcp_log, cfg_get)

[ -n "${_ROUTING_SH_LOADED:-}" ] && return 0
_ROUTING_SH_LOADED=1

# ── constants ─────────────────────────────────────────────────────────────────

TUN_TABLE=200        # routing table index we reserve for tun0
TUN_NAME=tun0
RT_TABLES=/data/misc/net/rt_tables
IP=/system/bin/ip
IPT=/system/bin/iptables
IP6T=/system/bin/ip6tables
BYPASS_LIST="${DCP_DATA:-/data/dikec}/conf/bypass.list"

# tproxy constants (match zte reference; overridable by caller env)
TPROXY_MARK="${TPROXY_MARK:-0x100/0x100}"
TPROXY_RULE_MARK="${TPROXY_RULE_MARK:-0x100}"
PROXY_PORT="${PROXY_PORT:-10808}"
LAN_IF="${LAN_IF:-br0}"
WAN_IF_PATTERN="${WAN_IF_PATTERN:-rmnet_data+}"
LEAK_CHAIN="XRAY_LEAK_GUARD"

# ── internal helpers ──────────────────────────────────────────────────────────

_vpn_gateway_installed() {
    # Module directory present and not marked for disable/removal
    [ -d /data/adb/modules/vpn-gateway ] &&
    [ ! -f /data/adb/modules/vpn-gateway/disable ] &&
    [ ! -f /data/adb/modules/vpn-gateway/remove ]
}

_tun0_in_rt() {
    # True if tun0 already has an entry in rt_tables
    awk '$2 == "tun0" {found=1} END{exit !found}' "$RT_TABLES" 2>/dev/null
}

_add_tun0_to_rt() {
    _tun0_in_rt && return 0
    # Append: busybox inotifyd watches the directory for writes
    printf '%d %s\n' "$TUN_TABLE" "$TUN_NAME" >> "$RT_TABLES" 2>/dev/null
    dcp_log "routing: added $TUN_TABLE $TUN_NAME to rt_tables"
}

_del_tun0_from_rt() {
    _tun0_in_rt || return 0
    # Overwrite in-place (triggers inotifyd IN_CLOSE_WRITE → vpn-gateway cleanup)
    local filtered
    filtered=$(awk '$2 != "tun0"' "$RT_TABLES" 2>/dev/null)
    # Guard: write only if we got output (prevents empty-file catastrophe)
    [ -n "$filtered" ] && printf '%s\n' "$filtered" > "$RT_TABLES" 2>/dev/null
    dcp_log "routing: removed tun0 from rt_tables"
}

_wait_for_tun0() {
    local secs="${1:-10}"
    local waited=0
    while ! $IP link show "$TUN_NAME" >/dev/null 2>&1; do
        [ "$waited" -ge "$secs" ] && return 1
        sleep 1; waited=$((waited + 1))
    done
    return 0
}

# RFC1918 ip rules at the same prefs vpn-gateway uses (5030/5040/5050)
# so that our own rules and vpn-gateway rules are interchangeable.
_RFC1918="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
_PREFS="5030 5040 5050"

_add_own_ip_rules() {
    local net pref
    set -- $_RFC1918
    for pref in $_PREFS; do
        net="$1"; shift
        $IP rule add from "$net" lookup "$TUN_TABLE" pref "$pref" 2>/dev/null || true
    done
    dcp_log "routing: own RFC1918 ip rules added (table $TUN_TABLE)"
}

_del_own_ip_rules() {
    local net pref
    set -- $_RFC1918
    for pref in $_PREFS; do
        net="$1"; shift
        $IP rule del from "$net" lookup "$TUN_TABLE" pref "$pref" 2>/dev/null || true
    done
    dcp_log "routing: own RFC1918 ip rules removed"
}

_add_forward_rules() {
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        $IPT -C FORWARD -s "$net" -o "$TUN_NAME" -j ACCEPT 2>/dev/null ||
            $IPT -I FORWARD -s "$net" -o "$TUN_NAME" -j ACCEPT
    done
    $IPT -C FORWARD -i "$TUN_NAME" -j ACCEPT 2>/dev/null ||
        $IPT -I FORWARD -i "$TUN_NAME" -j ACCEPT
}

_del_forward_rules() {
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        while $IPT -D FORWARD -s "$net" -o "$TUN_NAME" -j ACCEPT 2>/dev/null; do :; done
    done
    while $IPT -D FORWARD -i "$TUN_NAME" -j ACCEPT 2>/dev/null; do :; done
}

# ── route_apply ───────────────────────────────────────────────────────────────

route_apply() {
    local mode="${1:-$(cfg_get route_mode tun0)}"
    dcp_log "route_apply: mode=$mode"

    case "$mode" in

        tun0)
            # 1) Register tun0 in rt_tables — vpn-gateway inotifyd will pick this up
            #    and install RFC1918 ip rules + FORWARD accepts for us.
            _add_tun0_to_rt

            # 2) Wait for tun0 interface (hev-socks5-tunnel creates it)
            if ! _wait_for_tun0 10; then
                dcp_log "route_apply: TIMEOUT waiting for tun0"
                return 1
            fi
            dcp_log "route_apply: tun0 is present"

            # 3) Ensure tun0 link is up
            $IP link set "$TUN_NAME" up 2>/dev/null || true

            # 4) Ensure IPv4 address is assigned (hev 2.15 handles this, safety net)
            if ! $IP addr show "$TUN_NAME" 2>/dev/null | grep -q '198\.18\.'; then
                $IP addr add 198.18.0.1/30 dev "$TUN_NAME" 2>/dev/null || true
            fi

            # 5) Default route via tun0 in our reserved table (required for
            #    vpn-gateway's RFC1918 ip rules to have somewhere to route to).
            #    RACE: Android netd rebuilds routing tables a moment after tun0
            #    appears (interface-up event) and WIPES this route, so a single
            #    add silently vanishes and LAN clients fall through to the WAN
            #    table (exit direct, not via VPN). Add then re-assert for a short
            #    window to win the race. `ip route replace` is idempotent.
            $IP route replace default dev "$TUN_NAME" table "$TUN_TABLE" 2>/dev/null
            # short-lived re-assert (≈16s, NOT a persistent daemon): re-add if
            # netd flushed it. Covers the post-up churn window.
            (
                _n=0
                while [ "$_n" -lt 8 ]; do
                    sleep 2
                    $IP route show table "$TUN_TABLE" 2>/dev/null | grep -q "default dev $TUN_NAME" \
                        || $IP route replace default dev "$TUN_NAME" table "$TUN_TABLE" 2>/dev/null
                    _n=$((_n + 1))
                done
            ) >/dev/null 2>&1 &
            dcp_log "route_apply: default via tun0 in table $TUN_TABLE (+re-assert vs netd)"

            # 6) If vpn-gateway is absent: install our own RFC1918 rules + FORWARD
            if _vpn_gateway_installed; then
                dcp_log "route_apply: vpn-gateway present — delegating ip rules to it"
            else
                dcp_log "route_apply: vpn-gateway absent — installing own ip rules"
                _add_own_ip_rules
                _add_forward_rules
            fi

            # 7) Replay persisted per-client bypass entries (survives reboot)
            bypass_replay
            ;;

        tproxy)
            if [ "${DRYRUN:-0}" = "1" ]; then
                _tproxy_dryrun
            else
                _tproxy_start
                bypass_replay
            fi
            ;;

        *)
            dcp_log "route_apply: unknown mode '$mode'"
            return 1
            ;;
    esac
}

# ── route_clear ───────────────────────────────────────────────────────────────

route_clear() {
    local mode="${1:-$(cfg_get route_mode tun0)}"
    dcp_log "route_clear: mode=$mode"

    case "$mode" in

        tun0)
            # Remove default route from our table
            $IP route del default dev "$TUN_NAME" table "$TUN_TABLE" 2>/dev/null || true
            $IP route flush table "$TUN_TABLE" 2>/dev/null || true

            # Remove RFC1918 ip rules whether we or vpn-gateway added them
            # (same pref numbers, same specs — removal is idempotent)
            _del_own_ip_rules

            # Removing tun0 from rt_tables triggers vpn-gateway's inotifyd to call
            # cleanup(tun0, 200) which removes its own ip rules and FORWARD rules.
            _del_tun0_from_rt

            # Sleep briefly to let vpn-gateway's inotifyd cleanup fire before we
            # report complete (harmless if inotifyd is slow — rules are already gone)
            sleep 1

            # Remove FORWARD rules we might have installed (if vpn-gateway absent)
            _del_forward_rules 2>/dev/null || true

            dcp_log "route_clear: tun0 routing removed"
            ;;

        tproxy)
            _tproxy_stop
            ;;

        *)
            dcp_log "route_clear: unknown mode '$mode'"
            ;;
    esac
}

# ── bypass_add / bypass_del ───────────────────────────────────────────────────

# _bypass_apply_one IP — install the live rules for one bypassed IP (no list write).
# Idempotent: delete-then-add so re-application never duplicates rules.
_bypass_apply_one() {
    local bip="${1:-}"
    [ -n "$bip" ] || return 1

    # iptables: RETURN so NAT/REDIRECT rules don't intercept this destination
    while $IPT -t nat -D PREROUTING -d "$bip" -j RETURN 2>/dev/null; do :; done
    $IPT -t nat -I PREROUTING 1 -d "$bip" -j RETURN

    # ip rule: force traffic TO this IP through main table (pref lower than
    # our RFC1918 lookup rules so it takes precedence; matches traffic FROM
    # RFC1918 LAN clients destined TO the bypassed IP)
    while $IP rule del to "$bip" lookup main pref 5025 2>/dev/null; do :; done
    $IP rule add to "$bip" lookup main pref 5025 2>/dev/null || true
}

# bypass_replay — re-apply every IP in bypass.list. Called from route_apply so
# per-client bypass survives reboot (iptables/ip rules don't persist; the file does).
bypass_replay() {
    [ -f "$BYPASS_LIST" ] || return 0
    local bip
    while IFS= read -r bip; do
        bip=$(printf '%s' "$bip" | tr -d ' \t\r')
        [ -n "$bip" ] || continue
        case "$bip" in \#*) continue;; esac
        _bypass_apply_one "$bip"
    done < "$BYPASS_LIST"
    dcp_log "bypass_replay: applied $(grep -cvE '^[[:space:]]*(#|$)' "$BYPASS_LIST" 2>/dev/null || echo 0) entries"
}

bypass_add() {
    local bip="${1:-}"
    [ -n "$bip" ] || { dcp_log "bypass_add: no ip"; return 1; }

    mkdir -p "$(dirname "$BYPASS_LIST")"
    # Persist to list
    grep -qxF "$bip" "$BYPASS_LIST" 2>/dev/null ||
        printf '%s\n' "$bip" >> "$BYPASS_LIST"

    _bypass_apply_one "$bip"

    dcp_log "bypass_add: $bip"
}

bypass_del() {
    local bip="${1:-}"
    [ -n "$bip" ] || { dcp_log "bypass_del: no ip"; return 1; }

    # Remove from persistent list
    if [ -f "$BYPASS_LIST" ]; then
        local tmp="${BYPASS_LIST}.dcp_tmp$$"
        grep -vxF "$bip" "$BYPASS_LIST" > "$tmp" 2>/dev/null &&
            mv "$tmp" "$BYPASS_LIST" || rm -f "$tmp"
    fi

    # Remove iptables rule
    while $IPT -t nat -D PREROUTING -d "$bip" -j RETURN 2>/dev/null; do :; done

    # Remove ip rule
    while $IP rule del to "$bip" lookup main pref 5025 2>/dev/null; do :; done

    dcp_log "bypass_del: $bip"
}

# ── tproxy helpers (ported from zte tproxy.sh) ───────────────────────────────

_private_cidrs() {
    printf '%s\n' \
        0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
        169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
        224.0.0.0/4 240.0.0.0/4 255.255.255.255/32
}

_tproxy_start() {
    _tproxy_stop >/dev/null 2>&1

    $IP rule add fwmark "$TPROXY_RULE_MARK" table 100 prio 100 2>/dev/null || true
    $IP route add local default dev lo table 100 2>/dev/null || true

    # mangle XRAY_UDP — TPROXY for UDP
    $IPT -t mangle -N XRAY_UDP 2>/dev/null || $IPT -t mangle -F XRAY_UDP
    _private_cidrs | while read -r cidr; do
        $IPT -t mangle -A XRAY_UDP -d "$cidr" -j RETURN
    done
    $IPT -t mangle -A XRAY_UDP -p udp \
        -j TPROXY --on-port "$PROXY_PORT" --tproxy-mark "$TPROXY_MARK"
    $IPT -t mangle -C PREROUTING -i "$LAN_IF" -p udp -j XRAY_UDP 2>/dev/null ||
        $IPT -t mangle -I PREROUTING 1 -i "$LAN_IF" -p udp -j XRAY_UDP

    # nat XRAY — REDIRECT for TCP
    $IPT -t nat -N XRAY 2>/dev/null || $IPT -t nat -F XRAY
    _private_cidrs | while read -r cidr; do
        $IPT -t nat -A XRAY -d "$cidr" -j RETURN
    done
    $IPT -t nat -A XRAY -p tcp -j REDIRECT --to-ports "$PROXY_PORT"
    $IPT -t nat -C PREROUTING -i "$LAN_IF" -p tcp -j XRAY 2>/dev/null ||
        $IPT -t nat -I PREROUTING 1 -i "$LAN_IF" -p tcp -j XRAY

    # ICMP leak prevention — drop forwarded ICMP straight to WAN (zte parity)
    while $IPT -D FORWARD -p icmp -o "$WAN_IF_PATTERN" -j DROP 2>/dev/null; do :; done
    $IPT -I FORWARD 1 -p icmp -o "$WAN_IF_PATTERN" -j DROP

    # Leak guard — block UDP that somehow slips through
    $IPT -F "$LEAK_CHAIN" 2>/dev/null; $IPT -X "$LEAK_CHAIN" 2>/dev/null
    $IPT -N "$LEAK_CHAIN"
    $IPT -A "$LEAK_CHAIN" -p tcp -j RETURN
    $IPT -A "$LEAK_CHAIN" -p udp -j RETURN
    $IPT -A "$LEAK_CHAIN" -j DROP
    $IPT -I FORWARD 1 -i "$LAN_IF" -o "$WAN_IF_PATTERN" -j "$LEAK_CHAIN"

    # Block IPv6 forwarding from LAN (no IPv6 proxy path)
    $IP6T -C FORWARD -i "$LAN_IF" -o "$WAN_IF_PATTERN" -j DROP 2>/dev/null ||
        $IP6T -I FORWARD 1 -i "$LAN_IF" -o "$WAN_IF_PATTERN" -j DROP 2>/dev/null || true

    dcp_log "tproxy: rules applied"
}

_tproxy_stop() {
    while $IPT -t mangle -D PREROUTING -i "$LAN_IF" -p udp -j XRAY_UDP 2>/dev/null; do :; done
    $IPT -t mangle -F XRAY_UDP 2>/dev/null; $IPT -t mangle -X XRAY_UDP 2>/dev/null

    while $IPT -t nat -D PREROUTING -i "$LAN_IF" -p tcp -j XRAY 2>/dev/null; do :; done
    $IPT -t nat -F XRAY 2>/dev/null; $IPT -t nat -X XRAY 2>/dev/null

    while $IPT -D FORWARD -i "$LAN_IF" -o "$WAN_IF_PATTERN" -j "$LEAK_CHAIN" 2>/dev/null; do :; done
    $IPT -F "$LEAK_CHAIN" 2>/dev/null; $IPT -X "$LEAK_CHAIN" 2>/dev/null

    while $IPT -D FORWARD -p icmp -o "$WAN_IF_PATTERN" -j DROP 2>/dev/null; do :; done

    while $IP6T -D FORWARD -i "$LAN_IF" -o "$WAN_IF_PATTERN" -j DROP 2>/dev/null; do :; done

    $IP rule del fwmark "$TPROXY_RULE_MARK" table 100 2>/dev/null || true
    $IP route del local default dev lo table 100 2>/dev/null || true

    dcp_log "tproxy: rules removed"
}

_tproxy_dryrun() {
    printf '# TPROXY DRY-RUN (set DRYRUN=0 to actually apply)\n'
    printf 'ip rule add fwmark %s table 100 prio 100\n' "$TPROXY_RULE_MARK"
    printf 'ip route add local default dev lo table 100\n'
    printf 'iptables -t mangle -N XRAY_UDP\n'
    _private_cidrs | while read -r cidr; do
        printf 'iptables -t mangle -A XRAY_UDP -d %s -j RETURN\n' "$cidr"
    done
    printf 'iptables -t mangle -A XRAY_UDP -p udp -j TPROXY --on-port %s --tproxy-mark %s\n' \
        "$PROXY_PORT" "$TPROXY_MARK"
    printf 'iptables -t mangle -I PREROUTING 1 -i %s -p udp -j XRAY_UDP\n' "$LAN_IF"
    printf 'iptables -t nat -N XRAY\n'
    _private_cidrs | while read -r cidr; do
        printf 'iptables -t nat -A XRAY -d %s -j RETURN\n' "$cidr"
    done
    printf 'iptables -t nat -A XRAY -p tcp -j REDIRECT --to-ports %s\n' "$PROXY_PORT"
    printf 'iptables -t nat -I PREROUTING 1 -i %s -p tcp -j XRAY\n' "$LAN_IF"
    printf 'iptables -I FORWARD 1 -p icmp -o %s -j DROP\n' "$WAN_IF_PATTERN"
    printf 'iptables -N %s\n' "$LEAK_CHAIN"
    printf 'iptables -A %s -p tcp -j RETURN\n' "$LEAK_CHAIN"
    printf 'iptables -A %s -p udp -j RETURN\n' "$LEAK_CHAIN"
    printf 'iptables -A %s -j DROP\n' "$LEAK_CHAIN"
    printf 'iptables -I FORWARD 1 -i %s -o %s -j %s\n' \
        "$LAN_IF" "$WAN_IF_PATTERN" "$LEAK_CHAIN"
    printf 'ip6tables -I FORWARD 1 -i %s -o %s -j DROP\n' "$LAN_IF" "$WAN_IF_PATTERN"
    printf '# --- stop ---\n'
    printf 'iptables -t mangle -D PREROUTING -i %s -p udp -j XRAY_UDP\n' "$LAN_IF"
    printf 'iptables -t mangle -F XRAY_UDP; iptables -t mangle -X XRAY_UDP\n'
    printf 'iptables -t nat -D PREROUTING -i %s -p tcp -j XRAY\n' "$LAN_IF"
    printf 'iptables -t nat -F XRAY; iptables -t nat -X XRAY\n'
    printf 'iptables -D FORWARD -i %s -o %s -j %s\n' \
        "$LAN_IF" "$WAN_IF_PATTERN" "$LEAK_CHAIN"
    printf 'iptables -F %s; iptables -X %s\n' "$LEAK_CHAIN" "$LEAK_CHAIN"
    printf 'iptables -D FORWARD -p icmp -o %s -j DROP\n' "$WAN_IF_PATTERN"
    printf 'ip6tables -D FORWARD -i %s -o %s -j DROP\n' "$LAN_IF" "$WAN_IF_PATTERN"
    printf 'ip rule del fwmark %s table 100\n' "$TPROXY_RULE_MARK"
    printf 'ip route del local default dev lo table 100\n'
}
