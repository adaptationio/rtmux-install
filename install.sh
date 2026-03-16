#!/usr/bin/env bash
# CSM Node Installer — Join the Claude Session Manager fleet
#
# Usage (run on the remote PC):
#   curl -sL https://raw.githubusercontent.com/adaptationio/rtmux-install/main/install.sh | sudo bash -s -- \
#     --name alien --hub-ip 100.121.158.10 --hub-token csm-dev-token
#
# Flags:
#   --name NAME        Hostname alias for this node (default: system hostname)
#   --hub-ip IP        Hub server IP (Tailscale IP of GODv2)
#   --hub-token TOKEN  Auth token for hub API
#   --hub-port PORT    Hub port (default: 7780)
#   --manager-key KEY  SSH public key of the manager (enables remote tmux attach)
#   --ssh-port PORT    Extra sshd port for remote access (default: 2222)
#   --key TSKEY        Tailscale auth key (optional, for headless join)
#   --skip-tailscale   Skip Tailscale install (if already on same network)
#   --user USER        Run agent as this user (default: SUDO_USER)
set -uo pipefail

# ─── Elevate to root ─────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "\033[0;31mThis installer needs root.\033[0m Run with sudo:"
    echo "  curl -sL https://raw.githubusercontent.com/adaptationio/rtmux-install/main/install.sh | sudo bash -s -- --name \$(hostname -s) --hub-ip HUB_IP --hub-token TOKEN"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(eval echo "~$REAL_USER")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Parse args ──────────────────────────────────────────────────────────────
ALIAS=""
HUB_IP=""
HUB_TOKEN=""
HUB_PORT="7780"
TS_KEY=""
SKIP_TS=false
AGENT_USER=""
MANAGER_KEY=""
SSH_PORT="2222"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)           ALIAS="$2"; shift 2 ;;
        --hub-ip)         HUB_IP="$2"; shift 2 ;;
        --hub-token)      HUB_TOKEN="$2"; shift 2 ;;
        --hub-port)       HUB_PORT="$2"; shift 2 ;;
        --key)            TS_KEY="$2"; shift 2 ;;
        --skip-tailscale) SKIP_TS=true; shift ;;
        --user)           AGENT_USER="$2"; shift 2 ;;
        --manager-key)    MANAGER_KEY="$2"; shift 2 ;;
        --ssh-port)       SSH_PORT="$2"; shift 2 ;;
        *)                shift ;;
    esac
done

[[ -n "$AGENT_USER" ]] && REAL_USER="$AGENT_USER" && REAL_HOME=$(eval echo "~$AGENT_USER")
ALIAS="${ALIAS:-$(hostname -s 2>/dev/null || hostname)}"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  CSM Node Installer                              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Node:  ${BOLD}${ALIAS}${NC}"
echo -e "  User:  ${BOLD}${REAL_USER}${NC}"
[[ -n "$HUB_IP" ]] && echo -e "  Hub:   ${BOLD}${HUB_IP}:${HUB_PORT}${NC}"
echo ""

ERRORS=()

# ─── Helper ──────────────────────────────────────────────────────────────────
install_pkg() {
    if command -v apt-get &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null && apt-get install -y -qq "$@" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q "$@" 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$@" 2>/dev/null
    fi
}

step() { echo -ne "${CYAN}[$1/$TOTAL]${NC} $2 "; }
ok() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }
fail() { echo -e "${RED}$1${NC}"; ERRORS+=("$2"); }

TOTAL=7

# ─── 1. Install system deps ─────────────────────────────────────────────────
step 1 "System dependencies..."
pkgs=""
command -v tmux &>/dev/null || pkgs+=" tmux"
command -v jq &>/dev/null || pkgs+=" jq"
command -v curl &>/dev/null || pkgs+=" curl"
if [[ -n "$pkgs" ]]; then
    install_pkg $pkgs 2>/dev/null
    ok "installed:${pkgs}"
else
    ok "all present"
fi

# ─── 2. Install Tailscale (optional) ────────────────────────────────────────
step 2 "Tailscale..."
if [[ "$SKIP_TS" == "true" ]]; then
    ok "skipped (--skip-tailscale)"
elif command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // false' 2>/dev/null || echo "false")
    if [[ "$TS_STATUS" == "true" ]]; then
        TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
        ok "connected (${TS_IP})"
    else
        if [[ -n "$TS_KEY" ]]; then
            tailscale up --ssh --authkey="$TS_KEY" 2>/dev/null || tailscale up --authkey="$TS_KEY" 2>/dev/null || true
            sleep 3
            ok "connected (auth key)"
        else
            echo ""
            echo -e "  ${YELLOW}Run: sudo tailscale up --ssh${NC}"
            echo -e "  ${YELLOW}Then re-run this installer.${NC}"
            warn "needs login"
        fi
    fi
else
    echo -ne "installing... "
    curl -fsSL https://tailscale.com/install.sh 2>/dev/null | sh 2>/dev/null
    if [[ -n "$TS_KEY" ]]; then
        tailscale up --ssh --authkey="$TS_KEY" 2>/dev/null || true
        sleep 3
        ok "installed + connected"
    else
        ok "installed (run: sudo tailscale up --ssh)"
    fi
fi

# ─── 3. Install Node.js (>= 18) ─────────────────────────────────────────────
step 3 "Node.js..."
NEED_NODE=false
if command -v node &>/dev/null; then
    NODE_VER=$(node --version 2>/dev/null || echo "v0")
    NODE_MAJOR=$(echo "$NODE_VER" | sed 's/v\([0-9]*\).*/\1/')
    if [[ "$NODE_MAJOR" -lt 18 ]]; then
        echo -ne "${YELLOW}${NODE_VER} too old${NC}, upgrading... "
        # Remove conflicting packages on Ubuntu/Debian
        apt-get remove -y -qq libnode-dev libnode72 2>/dev/null || true
        NEED_NODE=true
    else
        ok "${NODE_VER}"
    fi
else
    echo -ne "installing... "
    NEED_NODE=true
fi
if [[ "$NEED_NODE" == "true" ]]; then
    if command -v apt-get &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - &>/dev/null
        apt-get install -y -qq nodejs &>/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x 2>/dev/null | bash - &>/dev/null
        yum install -y -q nodejs &>/dev/null
    fi
    if command -v node &>/dev/null; then
        ok "$(node --version)"
    else
        fail "FAILED" "Node.js installation failed"
    fi
fi

# ─── 4. SSH server ───────────────────────────────────────────────────────────
step 4 "SSH server..."
if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    ok "running"
elif command -v sshd &>/dev/null; then
    systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
    ok "started"
else
    install_pkg openssh-server 2>/dev/null
    systemctl enable --now ssh 2>/dev/null || true
    ok "installed"
fi

# Generate SSH key for the user if missing
SSH_DIR="$REAL_HOME/.ssh"
su - "$REAL_USER" -c "mkdir -p '$SSH_DIR' && chmod 700 '$SSH_DIR'" 2>/dev/null
if [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
    su - "$REAL_USER" -c "ssh-keygen -t ed25519 -f '$SSH_DIR/id_ed25519' -N '' -q" 2>/dev/null
fi

# ─── 5. rtmux-agent (tmux session manager) ──────────────────────────────────
step 5 "rtmux-agent..."

mkdir -p /opt/rtmux /etc/rtmux

# Agent daemon — keeps tmux sessions alive
tee /opt/rtmux/agent.sh > /dev/null <<'AGENTEOF'
#!/usr/bin/env bash
CONFIG="/etc/rtmux/sessions.json"
mkdir -p /etc/rtmux
[[ -f "$CONFIG" ]] || echo '{"sessions":["main"],"auto_restart":true}' > "$CONFIG"

log() { echo "[$(date '+%H:%M:%S')] rtmux: $*"; }
ensure() {
    local s
    for s in $(jq -r '.sessions[]' "$CONFIG" 2>/dev/null); do
        [[ -z "$s" ]] && continue
        tmux has-session -t "$s" 2>/dev/null || { tmux new-session -d -s "$s"; log "Started: $s"; }
    done
}
trap 'log "Stopping"; exit 0' SIGTERM SIGINT
log "Started"; ensure
while true; do sleep 60; ensure; done
AGENTEOF
chmod +x /opt/rtmux/agent.sh

# Control script
tee /opt/rtmux/ctl.sh > /dev/null <<'CTLEOF'
#!/usr/bin/env bash
CONFIG="/etc/rtmux/sessions.json"
mkdir -p /etc/rtmux
[[ -f "$CONFIG" ]] || echo '{"sessions":["main"],"auto_restart":true}' > "$CONFIG"
case "${1:-}" in
    add)    [[ -z "${2:-}" ]] && { echo "Usage: rtmux-ctl add <name>"; exit 1; }
            T=$(mktemp); jq --arg s "$2" '.sessions += [$s] | .sessions |= unique' "$CONFIG" > "$T" && mv "$T" "$CONFIG"
            echo "Added '$2'"; ;;
    remove) [[ -z "${2:-}" ]] && { echo "Usage: rtmux-ctl remove <name>"; exit 1; }
            T=$(mktemp); jq --arg s "$2" '.sessions -= [$s]' "$CONFIG" > "$T" && mv "$T" "$CONFIG"
            echo "Removed '$2'"; ;;
    list)   jq -r '.sessions[]' "$CONFIG" 2>/dev/null; ;;
    status) echo "Sessions:"; jq -r '.sessions[]' "$CONFIG" 2>/dev/null | while read -r s; do
              tmux has-session -t "$s" 2>/dev/null && echo "  ● $s (running)" || echo "  ○ $s (will restart)"; done
            systemctl is-active rtmux-agent 2>/dev/null && echo "Agent: active" || echo "Agent: inactive"
            systemctl is-active csm-agent 2>/dev/null && echo "CSM:   active" || echo "CSM:   inactive"; ;;
    *)      echo "Usage: rtmux-ctl {add|remove|list|status} [name]"; ;;
esac
CTLEOF
chmod +x /opt/rtmux/ctl.sh
ln -sf /opt/rtmux/ctl.sh /usr/local/bin/rtmux-ctl 2>/dev/null || true

# Systemd service
tee /etc/systemd/system/rtmux-agent.service > /dev/null <<SVCEOF
[Unit]
Description=rtmux persistent session agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/rtmux/agent.sh
Restart=always
RestartSec=5
User=${REAL_USER}
Environment=HOME=${REAL_HOME}

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now rtmux-agent 2>/dev/null

# Create initial session
su - "$REAL_USER" -c "tmux has-session -t main 2>/dev/null || tmux new-session -d -s main" 2>/dev/null

ok "running"

# ─── 6. CSM Hub Agent ────────────────────────────────────────────────────────
step 6 "CSM hub agent..."

# Resolve hub IP: explicit > Tailscale lookup > skip
if [[ -z "$HUB_IP" ]]; then
    HUB_IP=$(tailscale status --json 2>/dev/null | jq -r '.Peer[] | select(.HostName=="godv2") | .TailscaleIPs[0]' 2>/dev/null || echo "")
fi

if [[ -z "$HUB_IP" ]]; then
    fail "skipped (no --hub-ip)" "CSM agent not installed — pass --hub-ip"
elif [[ -z "$HUB_TOKEN" ]]; then
    fail "skipped (no --hub-token)" "CSM agent not installed — pass --hub-token"
elif ! command -v node &>/dev/null; then
    fail "skipped (no Node.js)" "CSM agent needs Node.js >= 18"
else
    CSM_DIR="/opt/csm-agent"
    mkdir -p "$CSM_DIR"

    # Download agent
    curl -fsSL "https://raw.githubusercontent.com/adaptationio/rtmux-install/main/csm-agent.js" \
        -o "$CSM_DIR/agent.js" 2>/dev/null

    # Install ws dependency
    cd "$CSM_DIR"
    [[ -f package.json ]] || node -e "require('fs').writeFileSync('package.json','{\"name\":\"csm-agent\",\"private\":true}')"
    npm install --save ws 2>/dev/null

    # Write config (secrets in env file, chmod 600)
    tee /etc/csm-agent.env > /dev/null <<ENVEOF
CSM_HUB_URL=ws://${HUB_IP}:${HUB_PORT}/ws/node
CSM_AUTH_TOKEN=${HUB_TOKEN}
CSM_HOSTNAME=${ALIAS}
ENVEOF
    chmod 600 /etc/csm-agent.env
    chown root:root /etc/csm-agent.env

    # Systemd service
    tee /etc/systemd/system/csm-agent.service > /dev/null <<SVCEOF
[Unit]
Description=CSM Hub Node Agent
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/node /opt/csm-agent/agent.js
EnvironmentFile=/etc/csm-agent.env
Restart=always
RestartSec=10
User=${REAL_USER}
Environment=HOME=${REAL_HOME}

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable csm-agent 2>/dev/null
    systemctl restart csm-agent

    # Wait and verify
    sleep 3
    if systemctl is-active --quiet csm-agent 2>/dev/null; then
        ok "connected to hub"
    else
        warn "installed but not connecting (check: journalctl -u csm-agent -n 20)"
    fi
fi

# ─── 7. SSH remote access (for tmux attach from manager) ─────────────────────
step 7 "Remote SSH access..."

# Add an extra sshd port that bypasses Tailscale SSH interception
SSHD_CONF="/etc/ssh/sshd_config"
if grep -q "^Port ${SSH_PORT}" "$SSHD_CONF" 2>/dev/null; then
    echo -ne "port ${SSH_PORT} already configured, "
else
    echo -e "\n# CSM remote access port (bypasses Tailscale SSH)\nPort ${SSH_PORT}" >> "$SSHD_CONF"
    # Allow through firewall
    ufw allow "${SSH_PORT}/tcp" 2>/dev/null || true
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo -ne "port ${SSH_PORT} added, "
fi

# Add manager's SSH key if provided
if [[ -n "$MANAGER_KEY" ]]; then
    AUTH_KEYS="$REAL_HOME/.ssh/authorized_keys"
    mkdir -p "$REAL_HOME/.ssh" && chmod 700 "$REAL_HOME/.ssh"
    touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"
    chown -R "$REAL_USER:$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" "$REAL_HOME/.ssh"
    if grep -qF "$MANAGER_KEY" "$AUTH_KEYS" 2>/dev/null; then
        ok "key already present"
    else
        echo "$MANAGER_KEY" >> "$AUTH_KEYS"
        ok "manager key added"
    fi
else
    # Auto-fetch manager's key from hub if reachable
    if [[ -n "$HUB_IP" ]]; then
        FETCHED_KEY=$(curl -sf "http://${HUB_IP}:${HUB_PORT}/api/v1/manager-key" 2>/dev/null || echo "")
        if [[ -n "$FETCHED_KEY" && "$FETCHED_KEY" == ssh-* ]]; then
            AUTH_KEYS="$REAL_HOME/.ssh/authorized_keys"
            mkdir -p "$REAL_HOME/.ssh" && chmod 700 "$REAL_HOME/.ssh"
            touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS"
            chown -R "$REAL_USER:$(id -gn "$REAL_USER" 2>/dev/null || echo "$REAL_USER")" "$REAL_HOME/.ssh"
            grep -qF "$FETCHED_KEY" "$AUTH_KEYS" 2>/dev/null || echo "$FETCHED_KEY" >> "$AUTH_KEYS"
            ok "manager key fetched from hub"
        else
            warn "no --manager-key (pass manager's SSH public key for remote tmux attach)"
        fi
    else
        warn "skipped (no --manager-key or --hub-ip)"
    fi
fi

# Verify sshd on the extra port
if ss -tlnp 2>/dev/null | grep -q ":${SSH_PORT} " 2>/dev/null; then
    echo -e "  ${DIM}Remote tmux attach: ssh -p ${SSH_PORT} ${REAL_USER}@\$(tailscale ip -4 2>/dev/null || hostname -I | awk '{print \$1}') -t 'tmux attach'${NC}"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"

if [[ ${#ERRORS[@]} -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}  Setup complete!${NC}"
else
    echo -e "${YELLOW}${BOLD}  Setup complete with warnings:${NC}"
    for err in "${ERRORS[@]}"; do
        echo -e "  ${YELLOW}⚠${NC}  $err"
    done
fi

echo ""
echo -e "  ${BOLD}Node:${NC}       ${ALIAS}"
echo -e "  ${BOLD}User:${NC}       ${REAL_USER}"
TS_IP=$(tailscale ip -4 2>/dev/null || echo "n/a")
echo -e "  ${BOLD}Tailscale:${NC}  ${TS_IP}"

if [[ -n "$HUB_IP" ]]; then
    echo -e "  ${BOLD}Hub:${NC}        ws://${HUB_IP}:${HUB_PORT}"
    echo -e "  ${BOLD}Dashboard:${NC}  ${CYAN}http://${HUB_IP}:${HUB_PORT}/dashboard/${NC}"
fi

echo ""
echo -e "  ${BOLD}Services:${NC}"
systemctl is-active --quiet rtmux-agent 2>/dev/null && echo -e "    ${GREEN}●${NC} rtmux-agent  (tmux session keepalive)" || echo -e "    ${RED}○${NC} rtmux-agent"
systemctl is-active --quiet csm-agent 2>/dev/null && echo -e "    ${GREEN}●${NC} csm-agent    (hub connection + metrics)" || echo -e "    ${RED}○${NC} csm-agent"

echo -e "  ${BOLD}SSH Port:${NC}   ${SSH_PORT} (for remote tmux attach)"

echo ""
echo -e "  ${BOLD}Commands:${NC}"
echo -e "    ${CYAN}rtmux-ctl status${NC}              # check everything"
echo -e "    ${CYAN}rtmux-ctl add claude-work${NC}     # add a persistent session"
echo -e "    ${CYAN}journalctl -u csm-agent -f${NC}    # watch hub agent logs"
echo -e "    ${CYAN}sudo systemctl restart csm-agent${NC}  # restart hub agent"
echo ""
echo -e "  ${DIM}Everything auto-starts on reboot. No further config needed.${NC}"
echo ""
