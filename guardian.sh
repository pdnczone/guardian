#!/usr/bin/env bash
# ==============================================================================
# Guardian v1.0.2 - Traffic & Connection Flood Circuit Breaker
# Developed for PDNC ZONE (DNC DIRECT) - github.com/pdnczone/guardian
# ==============================================================================

set -e

VERSION="1.0.2"
CONF_DIR="/etc/guardian"
CONF_FILE="${CONF_DIR}/guardian.conf"
LOG_FILE="/var/log/guardian.log"
STREAK_FILE="/run/guardian.streak"
BIN_TARGET="/usr/local/bin/guardian"

# Defaults
DEFAULT_MAX_CONNS=4500
DEFAULT_MAX_MBPS=180
DEFAULT_MAX_STREAK=3
DEFAULT_PORTS="1020,1030,1040,1050,7443,9443"
DEFAULT_CONN_LIMIT=35
DEFAULT_SERVICES="frps frpc"
DEFAULT_WHITELIST=""

load_config() {
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONF_FILE"
    fi
    MAX_CONNS="${MAX_CONNS:-$DEFAULT_MAX_CONNS}"
    MAX_MBPS="${MAX_MBPS:-$DEFAULT_MAX_MBPS}"
    MAX_STREAK="${MAX_STREAK:-$DEFAULT_MAX_STREAK}"
    PROTECTED_PORTS="${PROTECTED_PORTS:-$DEFAULT_PORTS}"
    CONN_LIMIT_PER_IP="${CONN_LIMIT_PER_IP:-$DEFAULT_CONN_LIMIT}"
    RESTART_SERVICES="${RESTART_SERVICES:-$DEFAULT_SERVICES}"
    WHITELIST_IPS="${WHITELIST_IPS:-$DEFAULT_WHITELIST}"
    
    if [ -z "$IFACE" ] || [ "$IFACE" = "auto" ]; then
        IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
        IFACE="${IFACE:-eth0}"
    fi
}

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

apply_firewall() {
    load_config
    echo "🛡️  Applying Guardian firewall rules on interface ${IFACE}..."
    
    # 0. Always allow loopback & established traffic unconditionally at the very top
    iptables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -s 127.0.0.1 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    
    iptables -I INPUT 1 -i lo -j ACCEPT
    iptables -I INPUT 2 -s 127.0.0.1 -j ACCEPT
    iptables -I INPUT 3 -m state --state ESTABLISHED,RELATED -j ACCEPT

    # 1. Clean previous Guardian rules to prevent duplicates
    iptables -D INPUT -i "$IFACE" -p tcp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -p udp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j DROP 2>/dev/null || true
    iptables -D INPUT -p tcp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    iptables -D INPUT -p udp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j DROP 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -p tcp -m multiport --dports 1020,1030,1050 -j DROP 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -p udp --dport 1040 -j DROP 2>/dev/null || true

    # 2. Whitelist custom management or peer IPs if defined
    if [ -n "$WHITELIST_IPS" ]; then
        IFS=',' read -ra WIPS <<< "$WHITELIST_IPS"
        for wip in "${WIPS[@]}"; do
            wip=$(echo "$wip" | xargs)
            if [ -n "$wip" ]; then
                iptables -D INPUT -s "$wip" -j ACCEPT 2>/dev/null || true
                iptables -I INPUT 4 -s "$wip" -j ACCEPT
            fi
        done
    fi

    # 3. Block external direct internet access to tunnel-internal ports on primary public interface
    iptables -I INPUT 5 -i "$IFACE" -p tcp -m multiport --dports 1020,1030,1050 -j DROP
    iptables -I INPUT 6 -i "$IFACE" -p udp --dport 1040 -j DROP

    # 4. Per-IP Connection Limit on external interfaces ONLY (never loopback or tunnels)
    iptables -A INPUT -i "$IFACE" -p tcp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j REJECT --reject-with tcp-reset
    iptables -A INPUT -i "$IFACE" -p udp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j DROP

    # 5. IPv6 basic loopback allowance if ip6tables is available
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -D INPUT -i lo -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT 1 -i lo -j ACCEPT
    fi

    # 6. Save rules persistently
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4

    cat << 'UNIT' > /etc/systemd/system/iptables-restore.service
[Unit]
Description=Restore iptables firewall rules
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable iptables-restore.service >/dev/null 2>&1 || true
    echo "✅ Firewall rules applied and saved (Max ${CONN_LIMIT_PER_IP} conns/IP on ${IFACE} ports ${PROTECTED_PORTS})."
}

run_check() {
    load_config

    # 1. Connection Concurrency Check
    curr_conns=$(ss -tn state established 2>/dev/null | wc -l)
    
    if [ "$curr_conns" -ge "$MAX_CONNS" ]; then
        log "[CRITICAL] Connection flood: $curr_conns established (Threshold: $MAX_CONNS)"
        log "Top 5 destination ports:"
        ss -tn state established | awk '{print $3}' | awk -F: '{print $NF}' | sort | uniq -c | sort -nr | head -n 5 >> "$LOG_FILE"
        
        # Trigger cooldown
        for srv in $RESTART_SERVICES; do
            if systemctl is-active --quiet "$srv" 2>/dev/null; then
                log "Action: Restarting $srv to shed connection flood..."
                systemctl restart "$srv"
            fi
        done
        echo 0 > "$STREAK_FILE"
        return 0
    fi

    # 2. Real-Time Bandwidth Check (2-second sample on $IFACE)
    stat_path="/sys/class/net/${IFACE}/statistics"
    if [ ! -d "$stat_path" ]; then
        return 0
    fi

    rx1=$(cat "${stat_path}/rx_bytes")
    tx1=$(cat "${stat_path}/tx_bytes")
    sleep 2
    rx2=$(cat "${stat_path}/rx_bytes")
    tx2=$(cat "${stat_path}/tx_bytes")

    delta_rx=$((rx2 - rx1))
    delta_tx=$((tx2 - tx1))
    tot_bytes=$((delta_rx + delta_tx))
    speed_mbps=$(( tot_bytes * 8 / 2 / 1024 / 1024 ))

    streak=0
    if [ -f "$STREAK_FILE" ]; then
        streak=$(cat "$STREAK_FILE" 2>/dev/null || echo 0)
    fi

    if [ "$speed_mbps" -ge "$MAX_MBPS" ]; then
        streak=$((streak + 1))
        echo "$streak" > "$STREAK_FILE"
        log "[WARN] High bandwidth: ${speed_mbps} Mbps (Streak: $streak/$MAX_STREAK, Conns: $curr_conns)"
        
        if [ "$streak" -ge "$MAX_STREAK" ]; then
            log "[CIRCUIT-BREAKER] Bandwidth pinned above ${MAX_MBPS} Mbps for $MAX_STREAK checks! Triggering emergency cooldown."
            ss -tn state established | awk '{print $4}' | awk -F: '{print $NF}' | sort | uniq -c | sort -nr | head -n 5 >> "$LOG_FILE"
            for srv in $RESTART_SERVICES; do
                if systemctl is-active --quiet "$srv" 2>/dev/null; then
                    log "Action: Restarting $srv to stop continuous saturation..."
                    systemctl restart "$srv"
                fi
            done
            echo 0 > "$STREAK_FILE"
        fi
    else
        if [ "$streak" -gt 0 ]; then
            echo 0 > "$STREAK_FILE"
        fi
    fi
}

show_status() {
    load_config
    echo "=================================================="
    echo "🛡️  Guardian Status v${VERSION} (PDNC ZONE)"
    echo "=================================================="
    echo "Primary Interface : $IFACE"
    
    tot_conns=$(ss -tn state established 2>/dev/null | wc -l)
    loc_conns=$(ss -tn dst 127.0.0.1 2>/dev/null | wc -l)
    ext_conns=$((tot_conns - loc_conns))
    [ "$ext_conns" -lt 0 ] && ext_conns=0
    
    echo "Active Conns      : ${tot_conns} (Local Tunnel: ${loc_conns}, External: ${ext_conns}) / Max: ${MAX_CONNS}"
    
    stat_path="/sys/class/net/${IFACE}/statistics"
    if [ -d "$stat_path" ]; then
        rx1=$(cat "${stat_path}/rx_bytes")
        tx1=$(cat "${stat_path}/tx_bytes")
        sleep 1
        rx2=$(cat "${stat_path}/rx_bytes")
        tx2=$(cat "${stat_path}/tx_bytes")
        curr_mbps=$(( ( (rx2-rx1) + (tx2-tx1) ) * 8 / 1024 / 1024 ))
        echo "Current Bandwidth : ${curr_mbps} Mbps (Threshold: ${MAX_MBPS} Mbps)"
    fi
    
    echo "Timer Service     : $(systemctl is-active guardian.timer 2>/dev/null || echo 'inactive')"
    echo ""
    echo "--- Protected Ports (Firewall) ---"
    iptables -L INPUT -n -v | grep -E "connlimit|multiport|lo|127.0.0.1" | head -n 12
    echo ""
    echo "--- Last 5 Guardian Events ---"
    if [ -f "$LOG_FILE" ]; then
        tail -n 5 "$LOG_FILE"
    else
        echo "No events logged yet."
    fi
    echo "=================================================="
}

install_guardian() {
    echo "🚀 Installing Guardian v${VERSION}..."
    mkdir -p "$CONF_DIR"
    
    # Detect best default interface
    def_iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
    def_iface="${def_iface:-eth0}"

    if [ ! -f "$CONF_FILE" ]; then
        cat << CONF > "$CONF_FILE"
# ==============================================================================
# Guardian Configuration File (/etc/guardian/guardian.conf)
# ==============================================================================

# Network interface to monitor and protect (auto or specific interface like eth0)
IFACE="${def_iface}"

# Maximum concurrent connections before triggering circuit-breaker cooldown
MAX_CONNS=${DEFAULT_MAX_CONNS}

# Maximum bandwidth threshold in Mbps
MAX_MBPS=${DEFAULT_MAX_MBPS}

# Consecutive checks above MAX_MBPS needed to trigger cooldown (checks are every 60s)
MAX_STREAK=${DEFAULT_MAX_STREAK}

# Protected inbound proxy/tunnel ports on external interface
PROTECTED_PORTS="${DEFAULT_PORTS}"

# Maximum simultaneous connections allowed per client IP on external interface
CONN_LIMIT_PER_IP=${DEFAULT_CONN_LIMIT}

# Services to restart during emergency cooldown
RESTART_SERVICES="${DEFAULT_SERVICES}"

# Whitelisted IPs exempt from limits (comma-separated, e.g. "1.2.3.4, 5.6.7.8")
WHITELIST_IPS=""
CONF
        echo "Created config at $CONF_FILE"
    fi

    # Install binary
    if [ -f "$0" ] && [ "$(basename "$0")" != "bash" ] && [ "$(basename "$0")" != "sh" ]; then
        cp "$0" "$BIN_TARGET"
    else
        curl -fsSL https://raw.githubusercontent.com/pdnczone/guardian/main/guardian.sh -o "$BIN_TARGET"
    fi
    chmod +x "$BIN_TARGET"

    # Install systemd unit & timer
    cat << 'UNIT' > /etc/systemd/system/guardian.service
[Unit]
Description=Guardian Traffic & Connection Circuit Breaker
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/guardian run
UNIT

    cat << 'TIMER' > /etc/systemd/system/guardian.timer
[Unit]
Description=Run Guardian Watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload
    systemctl enable --now guardian.timer >/dev/null 2>&1
    
    apply_firewall
    echo ""
    echo "🎉 Guardian v${VERSION} installed successfully!"
    echo "Commands:"
    echo "  guardian status    - View live status, split connections & counters"
    echo "  guardian firewall  - Re-apply firewall protection"
    echo "  guardian run       - Run manual check"
    echo "  guardian uninstall - Remove Guardian"
}

uninstall_guardian() {
    echo "⚠️  Uninstalling Guardian..."
    systemctl disable --now guardian.timer 2>/dev/null || true
    rm -f /etc/systemd/system/guardian.service /etc/systemd/system/guardian.timer
    systemctl daemon-reload
    
    load_config
    iptables -D INPUT -i "$IFACE" -p tcp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j REJECT --reject-with tcp-reset 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -p udp -m multiport --dports "$PROTECTED_PORTS" -m connlimit --connlimit-above "$CONN_LIMIT_PER_IP" --connlimit-mask 32 -j DROP 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -p tcp -m multiport --dports 1020,1030,1050 -j DROP 2>/dev/null || true
    iptables -D INPUT -i "$IFACE" -p udp --dport 1040 -j DROP 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

    rm -f "$BIN_TARGET" "$STREAK_FILE"
    echo "✅ Guardian uninstalled."
}

# Entrypoint
case "$1" in
    install)
        install_guardian
        ;;
    firewall)
        apply_firewall
        ;;
    run)
        run_check
        ;;
    status)
        show_status
        ;;
    uninstall)
        uninstall_guardian
        ;;
    *)
        if [ "$0" = "/usr/local/bin/guardian" ]; then
            show_status
        else
            install_guardian
        fi
        ;;
esac
