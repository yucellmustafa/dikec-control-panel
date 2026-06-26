#!/system/bin/sh
# lib/core/adblock.sh — DNS sinkhole adblock via a SECOND dnsmasq instance
#
# Interfaces:
#   adblock_enable()       — write conf, start 2nd dnsmasq (127.0.0.1:5354),
#                            add iptables PREROUTING REDIRECT br0:53→5354 (udp+tcp)
#   adblock_disable()      — remove REDIRECT rules, stop OUR dnsmasq precisely
#   adblock_update()       — fetch/parse blocklists → AB_HOSTS, kill -HUP our dnsmasq
#   adblock_status_json()  — {enabled:bool, running:bool, domains:N}
#
# CRITICAL SAFETY: the STOCK dnsmasq (192.168.0.1:53) is NEVER touched.
# We identify our instance by its pid file (AB_PID) and conf-file path.
# A blanket pkill dnsmasq would break the hotspot — it is NEVER used here.
#
# Requires: env.sh sourced first (provides DCP_DATA, DCP_MOD, JQ, BU, dcp_log, cfg_get/cfg_set)

[ -n "${_ADBLOCK_SH_LOADED:-}" ] && return 0
_ADBLOCK_SH_LOADED=1

# Source env.sh if not already loaded (allows standalone sourcing during tests)
[ -n "${DCP_DATA:-}" ] || {
    _d="${DCP_MOD:-/data/adb/modules/dikec-control-panel}"
    . "$_d/lib/core/env.sh"
}

# ── Constants ─────────────────────────────────────────────────────────────────

AB_DIR="${DCP_DATA:-/data/dikec}/adblock"
AB_HOSTS="${DCP_DATA:-/data/dikec}/adblock/hosts"
AB_PID="${DCP_DATA:-/data/dikec}/adblock/dnsmasq.pid"
AB_CONF="${DCP_DATA:-/data/dikec}/adblock/dnsmasq.conf"
AB_LOG="${DCP_DATA:-/data/dikec}/logs/adblock.log"
AB_LISTS_CONF="${DCP_DATA:-/data/dikec}/conf/adblock.lists"
AB_WHITELIST="${DCP_DATA:-/data/dikec}/conf/adblock.whitelist"

# Template shipped with the module
AB_CONF_TPL="${DCP_MOD:-/data/adb/modules/dikec-control-panel}/xray/dnsmasq-adblock.conf"

AB_PORT=5354
AB_LISTEN=127.0.0.1
AB_UPSTREAM="127.0.0.1#53"
AB_BRIDGE=br0

IPT=/system/bin/iptables
DNSMASQ=/system/bin/dnsmasq

# Max bytes per blocklist download (5 MB keeps RAM/storage use modest)
AB_MAX_DL_BYTES=5242880

# ── URL registry (preset blocklist names → URLs) ──────────────────────────────

_ab_url_for() {
    case "$1" in
        stevenblack)  printf '%s' "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ;;
        adaway)       printf '%s' "https://adaway.org/hosts.txt" ;;
        hagezi)       printf '%s' "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/pro.txt" ;;
        hagezi_light) printf '%s' "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/hosts/light.txt" ;;
        *)            printf '' ;;
    esac
}

# ── Internal helpers ──────────────────────────────────────────────────────────

# Return the PID of OUR dnsmasq if running, empty otherwise.
_ab_our_pid() {
    local _pid=""
    [ -f "$AB_PID" ] || return 1
    _pid=$(cat "$AB_PID" 2>/dev/null)
    _pid=$(printf '%s' "$_pid" | tr -d ' \t\r\n')
    [ -n "$_pid" ] || return 1
    kill -0 "$_pid" 2>/dev/null || return 1
    printf '%s' "$_pid"
}

_ab_running() {
    _ab_our_pid >/dev/null 2>&1
}

# Write the runtime dnsmasq conf by substituting placeholders in the template.
_ab_write_conf() {
    mkdir -p "$AB_DIR"
    # sed: substitute all @@PLACEHOLDER@@ tokens
    sed \
        -e "s|@@AB_PORT@@|${AB_PORT}|g" \
        -e "s|@@AB_LISTEN@@|${AB_LISTEN}|g" \
        -e "s|@@AB_HOSTS@@|${AB_HOSTS}|g" \
        -e "s|@@AB_UPSTREAM@@|${AB_UPSTREAM}|g" \
        -e "s|@@AB_PID@@|${AB_PID}|g" \
        -e "s|@@AB_LOG@@|${AB_LOG}|g" \
        -e "s|@@AB_CONF@@|${AB_CONF}|g" \
        "$AB_CONF_TPL" > "$AB_CONF" 2>/dev/null
}

# ── adblock_enable ────────────────────────────────────────────────────────────

adblock_enable() {
    dcp_log "adblock_enable: start"

    mkdir -p "$AB_DIR"

    # Ensure a hosts file exists so dnsmasq can start even before first update
    [ -f "$AB_HOSTS" ] || touch "$AB_HOSTS"

    # ── 1) Start our dnsmasq if not already running ──────────────────────────
    if _ab_running; then
        dcp_log "adblock_enable: dnsmasq already running pid=$(_ab_our_pid 2>/dev/null), skip start"
    else
        rm -f "$AB_PID"
        _ab_write_conf
        # Launch daemonized (dnsmasq forks by default, writes pid file, exits parent)
        mkdir -p "${DCP_DATA:-/data/dikec}/logs"
        "$DNSMASQ" --conf-file="$AB_CONF" >>"$AB_LOG" 2>&1
        # Wait up to 5 s for pid file + process to appear
        local _w=0
        while ! _ab_running; do
            if [ "$_w" -ge 5 ]; then
                dcp_log "adblock_enable: dnsmasq failed to start within 5 s"
                return 1
            fi
            sleep 1; _w=$((_w + 1))
        done
        dcp_log "adblock_enable: dnsmasq started pid=$(_ab_our_pid 2>/dev/null)"
    fi

    # ── 2) Add iptables REDIRECT rules — idempotent (-C check before -I) ────
    if ! $IPT -t nat -C PREROUTING -i "$AB_BRIDGE" -p udp --dport 53 \
            -j REDIRECT --to-ports "$AB_PORT" 2>/dev/null; then
        $IPT -t nat -I PREROUTING -i "$AB_BRIDGE" -p udp --dport 53 \
            -j REDIRECT --to-ports "$AB_PORT"
        dcp_log "adblock_enable: UDP REDIRECT rule added"
    fi

    if ! $IPT -t nat -C PREROUTING -i "$AB_BRIDGE" -p tcp --dport 53 \
            -j REDIRECT --to-ports "$AB_PORT" 2>/dev/null; then
        $IPT -t nat -I PREROUTING -i "$AB_BRIDGE" -p tcp --dport 53 \
            -j REDIRECT --to-ports "$AB_PORT"
        dcp_log "adblock_enable: TCP REDIRECT rule added"
    fi

    cfg_set adblock_enabled 1
    dcp_log "adblock_enable: done"
}

# ── adblock_disable ───────────────────────────────────────────────────────────

adblock_disable() {
    dcp_log "adblock_disable: start"

    # ── 1) Remove REDIRECT rules — loop-delete all copies ───────────────────
    while $IPT -t nat -D PREROUTING -i "$AB_BRIDGE" -p udp --dport 53 \
            -j REDIRECT --to-ports "$AB_PORT" 2>/dev/null; do :; done
    while $IPT -t nat -D PREROUTING -i "$AB_BRIDGE" -p tcp --dport 53 \
            -j REDIRECT --to-ports "$AB_PORT" 2>/dev/null; do :; done
    dcp_log "adblock_disable: REDIRECT rules removed"

    # ── 2) Stop OUR dnsmasq precisely — pid file first, then targeted pkill ─
    # NEVER use blanket pkill dnsmasq — that would kill the STOCK resolver too.
    local _pid=""
    if [ -f "$AB_PID" ]; then
        _pid=$(cat "$AB_PID" 2>/dev/null | tr -d ' \t\r\n')
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            kill "$_pid" 2>/dev/null
            sleep 1
            kill -9 "$_pid" 2>/dev/null || true
            dcp_log "adblock_disable: killed our dnsmasq pid=$_pid"
        fi
        rm -f "$AB_PID"
    fi

    # Fallback: kill any process whose command line contains our unique conf-file
    # path.  This matches ONLY our instance — stock dnsmasq uses /system paths.
    local _BB="${BB:-${BU:-/data/adb/modules/bin-utils}/system/bin/busybox}"
    "$_BB" pkill -f "conf-file=${AB_CONF}" 2>/dev/null || true

    cfg_set adblock_enabled 0
    dcp_log "adblock_disable: done"
}

# ── adblock_update ────────────────────────────────────────────────────────────

adblock_update() {
    dcp_log "adblock_update: start"
    mkdir -p "$AB_DIR" "${DCP_DATA:-/data/dikec}/logs"

    local _TMP_RAW="$AB_DIR/.ab-raw.$$"
    local _TMP_DOM="$AB_DIR/.ab-dom.$$"

    # Trap for cleanup (POSIX: trap is global but we reset it at function end)
    trap 'rm -f "$_TMP_RAW" "$_TMP_DOM" "${_TMP_DOM}.wl" "${_TMP_DOM}.wl2"' EXIT INT TERM

    : > "$_TMP_RAW"

    # Default presets — user can override in adblock.lists:
    #   AB_LISTS="stevenblack hagezi_light"
    #   AB_CUSTOM="https://my.host/custom.txt"
    _AB_LISTS="stevenblack hagezi_light adaway"
    _AB_CUSTOM=""

    # Load user configuration if present (may set AB_LISTS, AB_CUSTOM)
    [ -f "$AB_LISTS_CONF" ] && . "$AB_LISTS_CONF" 2>/dev/null
    # Support both prefixed and bare variable names
    _AB_LISTS="${AB_LISTS:-$_AB_LISTS}"
    _AB_CUSTOM="${AB_CUSTOM:-$_AB_CUSTOM}"

    local _CURL="${CURL:-curl}"
    local _CURL_OPTS="-sL --max-time 60"
    # Suppress --max-filesize warnings on curl versions that don't support it;
    # use a subshell test to avoid killing the whole function.
    if "$_CURL" --max-filesize 1 https://127.0.0.1 >/dev/null 2>&1 || \
       "$_CURL" --max-filesize 1 /dev/null >/dev/null 2>&1; then
        _CURL_OPTS="$_CURL_OPTS --max-filesize ${AB_MAX_DL_BYTES}"
    fi

    # Fetch presets
    for _k in $_AB_LISTS; do
        _u=$(_ab_url_for "$_k")
        if [ -n "$_u" ]; then
            dcp_log "adblock_update: fetching preset=$_k"
            "$_CURL" $_CURL_OPTS "$_u" >> "$_TMP_RAW" 2>/dev/null || \
                dcp_log "adblock_update: warn — fetch failed: $_k"
        fi
    done

    # Fetch custom URLs (one per line)
    printf '%s\n' "$_AB_CUSTOM" | while IFS= read -r _u; do
        case "$_u" in
            http://*|https://*)
                dcp_log "adblock_update: fetching custom=$_u"
                "$_CURL" $_CURL_OPTS "$_u" >> "$_TMP_RAW" 2>/dev/null || \
                    dcp_log "adblock_update: warn — fetch failed: $_u"
                ;;
        esac
    done

    # Parse hosts/ABP/plain-domain formats → bare domain list
    # Handles: "0.0.0.0 domain", "127.0.0.1 domain", "||domain^", "domain"
    awk '
        { sub(/\r$/,""); sub(/#.*/,""); sub(/!.*/,"") }
        /^[[:space:]]*$/ { next }
        {
            n = split($0, a, /[[:space:]]+/)
            d = ""
            if (n >= 2 && (a[1] == "0.0.0.0" || a[1] == "127.0.0.1")) {
                d = a[2]
            } else if (n == 1) {
                d = a[1]
            }
            if (d == "") next
            gsub(/^\|\|/, "", d)
            gsub(/[\^\/].*$/, "", d)
            gsub(/^\*\./, "", d)
            if (d ~ /^[a-z0-9_-]+(\.[a-z0-9_-]+)+$/) print tolower(d)
        }
    ' "$_TMP_RAW" | sort -u > "$_TMP_DOM"

    rm -f "$_TMP_RAW"

    # Remove whitelisted domains
    if [ -s "$AB_WHITELIST" ]; then
        sed '/^[[:space:]]*$/d;/^#/d' "$AB_WHITELIST" | sort -u > "${_TMP_DOM}.wl"
        grep -vxF -f "${_TMP_DOM}.wl" "$_TMP_DOM" > "${_TMP_DOM}.wl2" 2>/dev/null && \
            mv "${_TMP_DOM}.wl2" "$_TMP_DOM"
        rm -f "${_TMP_DOM}.wl"
    fi

    local _count
    _count=$(wc -l < "$_TMP_DOM" 2>/dev/null | tr -d ' ')
    _count="${_count:-0}"

    # Write sinkhole hosts file: "0.0.0.0 domain" — dnsmasq addn-hosts format
    {
        printf '# Dikec Control Panel adblock — %s domains (updated %s)\n' \
            "$_count" "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo '')"
        awk '{ print "0.0.0.0 " $0 }' "$_TMP_DOM"
    } > "$AB_HOSTS"
    rm -f "$_TMP_DOM"

    dcp_log "adblock_update: $_count domains written to $AB_HOSTS"

    # Signal our dnsmasq to re-read the hosts file (SIGHUP)
    local _pid
    if _pid=$(_ab_our_pid 2>/dev/null); then
        kill -HUP "$_pid" 2>/dev/null && \
            dcp_log "adblock_update: HUP sent to dnsmasq pid=$_pid" || \
            dcp_log "adblock_update: warn — HUP failed (pid=$_pid)"
    else
        dcp_log "adblock_update: dnsmasq not running; hosts updated, reload skipped"
    fi

    trap - EXIT INT TERM
    printf '%s\n' "$_count"
}

# ── adblock_status_json ───────────────────────────────────────────────────────

adblock_status_json() {
    local _enabled=false _running=false _domains=0

    # Enabled = config flag set to "1"
    [ "$(cfg_get adblock_enabled 0)" = "1" ] && _enabled=true

    # Running = our dnsmasq pid file exists and process is alive
    _ab_running && _running=true

    # Domain count = lines of the form "0.0.0.0 ..." in the hosts file
    [ -f "$AB_HOSTS" ] && \
        _domains=$(grep -c '^0\.0\.0\.0 ' "$AB_HOSTS" 2>/dev/null || printf '0')

    "${JQ:-jq}" -nc \
        --argjson enabled  "$_enabled"       \
        --argjson running  "$_running"       \
        --argjson domains  "${_domains:-0}"  \
        '{enabled:$enabled, running:$running, domains:$domains}'
}
