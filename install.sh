#!/usr/bin/env bash
# rtmux remote installer - Run on any PC to join your rtmux fleet
# Usage: curl -sL https://raw.githubusercontent.com/adaptationio/rtmux-install/main/install.sh | sudo bash -s -- --name mypc
# Flags: --key TAILSCALE_KEY  --name HOSTNAME  --hub-token CSM_TOKEN  --hub-port 7780
set -uo pipefail

# ─── Elevate to root if not already ────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo -e "\033[0;31mThis installer needs root.\033[0m Run with:"
    echo -e "  curl -sL https://raw.githubusercontent.com/adaptationio/rtmux-install/main/install.sh | sudo bash -s -- --key YOUR_KEY --name \$(hostname -s)"
    exit 1
fi

# Capture the real user (not root) for SSH keys and tmux sessions
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(eval echo "~$REAL_USER")

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Pre-configured defaults ─────────────────────────────────────────────────
DEFAULT_TS_KEY=""  # Pass via --key flag (never commit keys to public repos)
DEFAULT_MANAGER_HOST="godv2"       # Tailscale hostname of manager
DEFAULT_MANAGER_USER="adaptation"  # SSH user on manager

# ─── Parse args ─────────────────────────────────────────────────────────────────
TS_KEY="${DEFAULT_TS_KEY}"
ALIAS=""
MANAGER_USER="${DEFAULT_MANAGER_USER}"
MANAGER_HOST="${DEFAULT_MANAGER_HOST}"
HUB_TOKEN=""
HUB_PORT="7780"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)        TS_KEY="$2"; shift 2 ;;
        --name)       ALIAS="$2"; shift 2 ;;
        --manager)    MANAGER_USER="$2"; shift 2 ;;
        --host)       MANAGER_HOST="$2"; shift 2 ;;
        --hub-token)  HUB_TOKEN="$2"; shift 2 ;;
        --hub-port)   HUB_PORT="$2"; shift 2 ;;
        *)            shift ;;
    esac
done

echo -e "${BOLD}rtmux remote setup${NC}"
echo -e "${DIM}─────────────────────────────────────────────────${NC}"
echo -e "  No ports needed. No IP config. Tailscale handles everything."
echo -e "  Running as root. Real user: ${BOLD}${REAL_USER}${NC}"
echo ""

# ─── Gather info ────────────────────────────────────────────────────────────────

default_alias=$(hostname -s 2>/dev/null || hostname)
if [[ -z "$ALIAS" ]]; then
    read -rp "Name for this PC [$default_alias]: " ALIAS
fi
ALIAS="${ALIAS:-$default_alias}"

# ─── 1. Install dependencies ───────────────────────────────────────────────────

echo ""
echo -ne "${CYAN}[1/9]${NC} Installing dependencies... "
install_pkg() {
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v yum &>/dev/null; then
        yum install -y "$@"
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$@"
    fi
}

pkgs=""
command -v tmux &>/dev/null || pkgs+=" tmux"
command -v jq &>/dev/null || pkgs+=" jq"
command -v ssh &>/dev/null || pkgs+=" openssh-client"
[[ -n "$pkgs" ]] && install_pkg $pkgs
echo -e "${GREEN}done${NC}"

# ─── 2. SSH server ─────────────────────────────────────────────────────────────

echo -ne "${CYAN}[2/9]${NC} SSH server... "
if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    echo -e "${GREEN}running${NC}"
elif command -v sshd &>/dev/null; then
    systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || service ssh start 2>/dev/null
    echo -e "${GREEN}started${NC}"
else
    install_pkg openssh-server
    systemctl enable --now ssh 2>/dev/null || service ssh start 2>/dev/null
    echo -e "${GREEN}installed and started${NC}"
fi

# ─── 3. SSH keys (as real user) ───────────────────────────────────────────────

echo -ne "${CYAN}[3/9]${NC} SSH keys... "
SSH_DIR="$REAL_HOME/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
su - "$REAL_USER" -c "mkdir -p '$SSH_DIR' && chmod 700 '$SSH_DIR'"
if [[ ! -f "$SSH_KEY" ]]; then
    su - "$REAL_USER" -c "ssh-keygen -t ed25519 -f '$SSH_KEY' -N '' -q"
fi
echo -e "${GREEN}ready${NC}"

# ─── 4. Install Tailscale ──────────────────────────────────────────────────────

echo -ne "${CYAN}[4/9]${NC} Tailscale... "
if command -v tailscale &>/dev/null; then
    echo -e "${GREEN}already installed${NC}"
else
    echo -ne "${YELLOW}installing... ${NC}"
    curl -fsSL https://tailscale.com/install.sh | sh 2>/dev/null
    echo -e "${GREEN}done${NC}"
fi

# ─── 5. Connect to Tailscale ───────────────────────────────────────────────────

echo -ne "${CYAN}[5/9]${NC} Connecting to Tailscale... "
TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // false' 2>/dev/null || echo "false")

if [[ "$TS_STATUS" == "true" ]]; then
    echo -e "${GREEN}already connected${NC}"
else
    if [[ -n "$TS_KEY" ]]; then
        tailscale up --ssh --authkey="$TS_KEY" 2>/dev/null || tailscale up --authkey="$TS_KEY" 2>/dev/null || true
        sleep 3
        echo -e "${GREEN}connected (auth key)${NC}"
    else
        echo ""
        echo -e "  ${YELLOW}No auth key provided. Opening browser login...${NC}"
        tailscale up --ssh 2>/dev/null || tailscale up 2>/dev/null || true
        echo -e "  ${GREEN}Connected${NC}"
    fi
fi

# Get Tailscale IP (retry a few times)
TS_IP=""
for i in 1 2 3 4 5; do
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    [[ -n "$TS_IP" ]] && break
    sleep 2
done

if [[ -z "$TS_IP" ]]; then
    echo -e "  ${RED}Could not get Tailscale IP. Check 'tailscale status'${NC}"
    echo -e "  ${YELLOW}Continuing with remaining setup...${NC}"
else
    echo -e "  Tailscale IP: ${BOLD}${TS_IP}${NC}"
fi

# ─── 6. Connect to manager (non-interactive via Tailscale SSH) ────────────────

echo -ne "${CYAN}[6/9]${NC} Connecting to manager... "

MANAGER="${MANAGER_USER}@${MANAGER_HOST}"
MANAGER_PORT=22
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o PasswordAuthentication=no -o BatchMode=yes"

echo -e "${GREEN}${MANAGER}${NC}"

# Tailscale SSH gives us passwordless access. Use it to:
# 1. Push our public key to the manager's authorized_keys
# 2. Pull the manager's public key to our authorized_keys
# 3. Register ourselves in the manager's rtmux hosts.json

echo -e "  ${DIM}Exchanging SSH keys (via Tailscale SSH)...${NC}"

OUR_PUBKEY=$(cat "${SSH_KEY}.pub" 2>/dev/null)
THIS_USER="$REAL_USER"
THIS_PORT=22
REGISTER_IP="${TS_IP:-unknown}"

# Try to connect to manager - Tailscale SSH should work without password
MANAGER_KEY=$(su - "$REAL_USER" -c "ssh $SSH_OPTS -p $MANAGER_PORT '$MANAGER' 'cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null'" 2>/dev/null || echo "")

if [[ -n "$MANAGER_KEY" ]]; then
    # Add manager's key to our authorized_keys
    AUTH_KEYS="$SSH_DIR/authorized_keys"
    touch "$AUTH_KEYS" && chmod 600 "$AUTH_KEYS" && chown "$REAL_USER:$REAL_USER" "$AUTH_KEYS"
    grep -qF "$MANAGER_KEY" "$AUTH_KEYS" 2>/dev/null || echo "$MANAGER_KEY" >> "$AUTH_KEYS"

    # Push our key to manager's authorized_keys
    su - "$REAL_USER" -c "ssh $SSH_OPTS -p $MANAGER_PORT '$MANAGER' 'grep -qF \"$OUR_PUBKEY\" ~/.ssh/authorized_keys 2>/dev/null || echo \"$OUR_PUBKEY\" >> ~/.ssh/authorized_keys'" 2>/dev/null || true

    echo -e "  ${GREEN}Keys exchanged${NC}"
else
    echo -e "  ${YELLOW}Couldn't reach manager via Tailscale SSH.${NC}"
    echo -e "  ${DIM}Run on manager: ssh-copy-id ${THIS_USER}@${TS_IP}${NC}"
    echo -e "  ${DIM}Then: rtmux add-host ${ALIAS} ${REGISTER_IP} ${THIS_USER} ${THIS_PORT}${NC}"
fi

# ─── 7. Register + Install Agent ───────────────────────────────────────────────

echo -ne "${CYAN}[7/9]${NC} Registering with manager... "

# Register this PC in the manager's rtmux hosts.json with CORRECT username and IP
REGISTER_CMD="mkdir -p \$HOME/.config/rtmux; F=\$HOME/.config/rtmux/hosts.json; [ -f \"\$F\" ] || echo '{\"hosts\":{}}' > \"\$F\"; T=\$(mktemp); jq --arg a \"$ALIAS\" --arg h \"$REGISTER_IP\" --arg u \"$THIS_USER\" --arg p \"$THIS_PORT\" '.hosts[\$a]={host:\$h,user:\$u,port:(\$p|tonumber),identity:\"\"}' \"\$F\" > \"\$T\" && mv \"\$T\" \"\$F\" && echo ok"

result=$(su - "$REAL_USER" -c "ssh $SSH_OPTS -p $MANAGER_PORT '$MANAGER' \"$REGISTER_CMD\"" 2>/dev/null) || true

if [[ "$result" == *"ok"* ]]; then
    echo -e "${GREEN}registered as '${ALIAS}' (user: ${THIS_USER}, ip: ${REGISTER_IP})${NC}"
else
    echo -e "${YELLOW}auto-register failed${NC}"
    echo -e "  ${DIM}Run on manager:${NC} ${CYAN}rtmux add-host ${ALIAS} ${REGISTER_IP} ${THIS_USER} ${THIS_PORT}${NC}"
fi

# ─── Install rtmux-agent service ────────────────────────────────────────────────

echo -ne "  Installing agent service... "

mkdir -p /opt/rtmux /etc/rtmux

# Agent daemon
tee /opt/rtmux/agent.sh > /dev/null <<'AGENTEOF'
#!/usr/bin/env bash
CONFIG_DIR="/etc/rtmux"
SESSIONS_FILE="$CONFIG_DIR/sessions.json"
HEARTBEAT_INTERVAL="${RTMUX_HEARTBEAT:-60}"

mkdir -p "$CONFIG_DIR"
[[ -f "$SESSIONS_FILE" ]] || echo '{"sessions":["main"],"auto_restart":true}' > "$SESSIONS_FILE"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] rtmux-agent: $*"; }

ensure_sessions() {
    local sessions
    sessions=$(jq -r '.sessions[]' "$SESSIONS_FILE" 2>/dev/null)
    [[ -z "$sessions" ]] && return
    while read -r session; do
        [[ -z "$session" ]] && continue
        if ! tmux has-session -t "$session" 2>/dev/null; then
            tmux new-session -d -s "$session"
            log "Started session: $session"
        fi
    done <<< "$sessions"
}

trap 'log "Agent stopping"; exit 0' SIGTERM SIGINT

log "Agent started"
ensure_sessions
while true; do
    sleep "$HEARTBEAT_INTERVAL"
    ensure_sessions
done
AGENTEOF
chmod +x /opt/rtmux/agent.sh

# Control script
tee /opt/rtmux/ctl.sh > /dev/null <<'CTLEOF'
#!/usr/bin/env bash
CONFIG_DIR="/etc/rtmux"
SESSIONS_FILE="$CONFIG_DIR/sessions.json"
mkdir -p "$CONFIG_DIR"
[[ -f "$SESSIONS_FILE" ]] || echo '{"sessions":["main"],"auto_restart":true}' > "$SESSIONS_FILE"

case "${1:-}" in
    add)
        [[ -z "${2:-}" ]] && { echo "Usage: rtmux-ctl add <session>"; exit 1; }
        TMP=$(mktemp)
        jq --arg s "$2" '.sessions += [$s] | .sessions |= unique' "$SESSIONS_FILE" > "$TMP" && mv "$TMP" "$SESSIONS_FILE"
        echo "Added '$2' - agent will create it within 60s"
        ;;
    remove)
        [[ -z "${2:-}" ]] && { echo "Usage: rtmux-ctl remove <session>"; exit 1; }
        TMP=$(mktemp)
        jq --arg s "$2" '.sessions -= [$s]' "$SESSIONS_FILE" > "$TMP" && mv "$TMP" "$SESSIONS_FILE"
        echo "Removed '$2'"
        ;;
    list)
        jq -r '.sessions[]' "$SESSIONS_FILE" 2>/dev/null
        ;;
    status)
        echo "Managed sessions:"
        jq -r '.sessions[]' "$SESSIONS_FILE" 2>/dev/null | while read -r s; do
            if tmux has-session -t "$s" 2>/dev/null; then
                echo "  ● $s (running)"
            else
                echo "  ○ $s (will restart)"
            fi
        done
        echo ""
        systemctl is-active rtmux-agent 2>/dev/null && echo "Agent: active" || echo "Agent: inactive"
        ;;
    *)
        echo "Usage: rtmux-ctl {add|remove|list|status} [session]"
        ;;
esac
CTLEOF
chmod +x /opt/rtmux/ctl.sh
ln -sf /opt/rtmux/ctl.sh /usr/local/bin/rtmux-ctl 2>/dev/null || true

# Systemd service (runs as real user, not root)
tee /etc/systemd/system/rtmux-agent.service > /dev/null <<SVCEOF
[Unit]
Description=rtmux persistent session agent
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/rtmux/agent.sh
Restart=always
RestartSec=5
User=${REAL_USER}
Environment=HOME=${REAL_HOME}
Environment=RTMUX_HEARTBEAT=60

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable rtmux-agent
systemctl start rtmux-agent

echo -e "${GREEN}done${NC}"

# Create initial session as real user
su - "$REAL_USER" -c "tmux has-session -t main 2>/dev/null || tmux new-session -d -s main"

# ─── 8. Install Node.js (for CSM agent) ──────────────────────────────────────

echo -ne "${CYAN}[8/9]${NC} Node.js... "
NEED_NODE=false
if command -v node &>/dev/null; then
    NODE_MAJOR=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
    if [[ "$NODE_MAJOR" -lt 18 ]]; then
        echo -ne "${YELLOW}v${NODE_MAJOR} too old, upgrading to v20... ${NC}"
        NEED_NODE=true
    else
        echo -e "${GREEN}$(node --version) ok${NC}"
    fi
else
    echo -ne "${YELLOW}installing v20... ${NC}"
    NEED_NODE=true
fi
if [[ "$NEED_NODE" == "true" ]]; then
    if command -v apt-get &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x 2>/dev/null | bash - &>/dev/null
        apt-get install -y -qq nodejs &>/dev/null
    elif command -v yum &>/dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_20.x 2>/dev/null | bash - &>/dev/null
        yum install -y nodejs &>/dev/null
    fi
    echo -e "${GREEN}$(node --version 2>/dev/null || echo 'installed')${NC}"
fi

# ─── 9. Install CSM Hub Agent ────────────────────────────────────────────────

echo -ne "${CYAN}[9/9]${NC} CSM hub agent... "

MANAGER_TS_IP=$(tailscale status --json 2>/dev/null | jq -r ".Peer[] | select(.HostName==\"${MANAGER_HOST}\") | .TailscaleIPs[0]" 2>/dev/null || echo "")
[[ -z "$MANAGER_TS_IP" ]] && MANAGER_TS_IP=$(getent hosts "$MANAGER_HOST" 2>/dev/null | awk '{print $1}' || echo "")

if [[ -z "$MANAGER_TS_IP" ]]; then
    echo -e "${YELLOW}skipped (cannot resolve manager IP — pass --host MANAGER_HOSTNAME)${NC}"
else
    if [[ -z "$HUB_TOKEN" ]]; then
        HUB_TOKEN=$(su - "$REAL_USER" -c "ssh $SSH_OPTS -p $MANAGER_PORT '$MANAGER' 'echo \$CSM_AUTH_TOKEN'" 2>/dev/null || echo "")
    fi

    if [[ -z "$HUB_TOKEN" ]]; then
        echo -e "${YELLOW}skipped (no hub token — pass --hub-token TOKEN)${NC}"
    else
        CSM_AGENT_DIR="/opt/csm-agent"
        mkdir -p "$CSM_AGENT_DIR"

        curl -fsSL "https://raw.githubusercontent.com/adaptationio/rtmux-install/main/csm-agent.js" \
            -o "$CSM_AGENT_DIR/agent.js" 2>/dev/null

        cd "$CSM_AGENT_DIR"
        [[ -f package.json ]] || node -e "require('fs').writeFileSync('package.json','{\"name\":\"csm-agent\",\"private\":true}')"
        npm install --save ws &>/dev/null 2>&1

        # Secrets go in env file with strict permissions — NOT in the service file
        tee /etc/csm-agent.env > /dev/null <<ENVEOF
CSM_HUB_URL=ws://${MANAGER_TS_IP}:${HUB_PORT}/ws/node
CSM_AUTH_TOKEN=${HUB_TOKEN}
CSM_HOSTNAME=${ALIAS}
ENVEOF
        chmod 600 /etc/csm-agent.env
        chown root:root /etc/csm-agent.env

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

[Install]
WantedBy=multi-user.target
SVCEOF

        systemctl daemon-reload
        systemctl enable csm-agent
        systemctl start csm-agent

        echo -e "${GREEN}installed and running${NC}"
        echo -e "  ${DIM}Hub: ws://${MANAGER_TS_IP}:${HUB_PORT}${NC}"
        echo -e "  ${DIM}Config: /etc/csm-agent.env (root-only, chmod 600)${NC}"
    fi
fi

# ─── Disable Tailscale key expiry via API if possible ─────────────────────────

# Try to have the manager disable key expiry for this device
su - "$REAL_USER" -c "ssh $SSH_OPTS -p $MANAGER_PORT '$MANAGER' 'bash ~/.config/rtmux/ts-renew.sh 2>/dev/null || true'" 2>/dev/null &

# ─── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ${GREEN}Setup complete!${NC}${BOLD}                                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}This PC:${NC} ${ALIAS}"
echo -e "  ${BOLD}User:${NC} ${REAL_USER}"
echo -e "  ${BOLD}Tailscale IP:${NC} ${TS_IP:-pending}"
echo -e "  ${BOLD}Manager:${NC} ${MANAGER}"
echo ""
echo -e "  ${GREEN}●${NC} Tailscale connected (zero-config networking)"
echo -e "  ${GREEN}●${NC} rtmux-agent running (auto-start, auto-restart)"
echo -e "  ${GREEN}●${NC} tmux session 'main' active (recreates if killed)"
echo -e "  ${GREEN}●${NC} SSH keys exchanged"
echo -e "  ${GREEN}●${NC} Registered as: ${CYAN}${ALIAS}${NC} (user: ${THIS_USER}, ip: ${REGISTER_IP})"
if systemctl is-active --quiet csm-agent 2>/dev/null; then
echo -e "  ${GREEN}●${NC} CSM hub agent connected (real-time metrics + commands)"
fi
echo ""
echo -e "  ${BOLD}On your manager PC:${NC}"
echo -e "    ${CYAN}rtmux ls ${ALIAS}${NC}                  # list sessions"
echo -e "    ${CYAN}rtmux open ${ALIAS} main${NC}            # open tmux session"
echo -e "    ${CYAN}rtmux new ${ALIAS} claude${NC}           # new Claude session"
echo -e "    ${CYAN}rtmux dashboard${NC}                   # fleet dashboard"
if [[ -n "$MANAGER_TS_IP" ]]; then
echo ""
echo -e "  ${BOLD}Dashboard:${NC} ${CYAN}http://${MANAGER_TS_IP}:${HUB_PORT}/dashboard/${NC}"
fi
echo ""
echo -e "  ${DIM}No further setup needed on this PC. Everything auto-starts on reboot.${NC}"
