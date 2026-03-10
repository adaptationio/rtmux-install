#!/usr/bin/env bash
# rtmux remote installer - Run on any PC to join your rtmux fleet
# Usage: curl -sL https://raw.githubusercontent.com/adaptationio/tmux/main/install-remote.sh | bash
# Auto:  curl -sL ... | bash -s -- --key tskey-auth-XXXXX --name laptop --manager adaptation
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Pre-configured defaults (edit these for your fleet) ────────────────────────
DEFAULT_TS_KEY="tskey-auth-kpW4hyeRSo11CNTRL-Wd61wKwypxHuAWRnhe2wxHNrHvHCjCpR"
DEFAULT_MANAGER_HOST="godv2"       # Tailscale hostname of manager
DEFAULT_MANAGER_USER="adaptation"  # SSH user on manager

# ─── Parse args ─────────────────────────────────────────────────────────────────
TS_KEY="${DEFAULT_TS_KEY}"
ALIAS=""
MANAGER_USER="${DEFAULT_MANAGER_USER}"
MANAGER_HOST="${DEFAULT_MANAGER_HOST}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --key)      TS_KEY="$2"; shift 2 ;;
        --name)     ALIAS="$2"; shift 2 ;;
        --manager)  MANAGER_USER="$2"; shift 2 ;;
        --host)     MANAGER_HOST="$2"; shift 2 ;;
        *)          shift ;;
    esac
done

echo -e "${BOLD}rtmux remote setup${NC}"
echo -e "${DIM}─────────────────────────────────────────────────${NC}"
echo -e "  No ports needed. No IP config. Tailscale handles everything."
echo ""

# ─── Gather info ────────────────────────────────────────────────────────────────

default_alias=$(hostname -s 2>/dev/null || hostname)
if [[ -z "$ALIAS" ]]; then
    read -rp "Name for this PC [$default_alias]: " ALIAS
fi
ALIAS="${ALIAS:-$default_alias}"

# ─── 1. Install dependencies ───────────────────────────────────────────────────

echo ""
echo -ne "${CYAN}[1/7]${NC} Installing dependencies... "
install_pkg() {
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y -qq "$@"
    elif command -v yum &>/dev/null; then
        sudo yum install -y "$@"
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm "$@"
    fi
}

pkgs=""
command -v tmux &>/dev/null || pkgs+=" tmux"
command -v jq &>/dev/null || pkgs+=" jq"
command -v ssh &>/dev/null || pkgs+=" openssh-client"
[[ -n "$pkgs" ]] && install_pkg $pkgs
echo -e "${GREEN}done${NC}"

# ─── 2. SSH server ─────────────────────────────────────────────────────────────

echo -ne "${CYAN}[2/7]${NC} SSH server... "
if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
    echo -e "${GREEN}running${NC}"
elif command -v sshd &>/dev/null; then
    sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || sudo service ssh start 2>/dev/null
    echo -e "${GREEN}started${NC}"
else
    install_pkg openssh-server
    sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start 2>/dev/null
    echo -e "${GREEN}installed and started${NC}"
fi

# ─── 3. SSH keys ───────────────────────────────────────────────────────────────

echo -ne "${CYAN}[3/7]${NC} SSH keys... "
SSH_KEY="$HOME/.ssh/id_ed25519"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
[[ -f "$SSH_KEY" ]] || ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
echo -e "${GREEN}ready${NC}"

# ─── 4. Install Tailscale ──────────────────────────────────────────────────────

echo -ne "${CYAN}[4/7]${NC} Tailscale... "
if command -v tailscale &>/dev/null; then
    echo -e "${GREEN}already installed${NC}"
else
    echo -ne "${YELLOW}installing... ${NC}"
    curl -fsSL https://tailscale.com/install.sh | sh 2>/dev/null
    echo -e "${GREEN}done${NC}"
fi

# ─── 5. Connect to Tailscale ───────────────────────────────────────────────────

echo -ne "${CYAN}[5/7]${NC} Connecting to Tailscale... "
TS_STATUS=$(tailscale status --json 2>/dev/null | jq -r '.Self.Online // false' 2>/dev/null || echo "false")

if [[ "$TS_STATUS" == "true" ]]; then
    echo -e "${GREEN}already connected${NC}"
else
    if [[ -n "$TS_KEY" ]]; then
        # Auto-authenticate with auth key — no browser needed
        sudo tailscale up --ssh --authkey="$TS_KEY" 2>/dev/null
        echo -e "${GREEN}connected (auth key)${NC}"
    else
        echo ""
        echo -e "  ${YELLOW}No auth key provided. Opening browser login...${NC}"
        sudo tailscale up --ssh
        echo -e "  ${GREEN}Connected${NC}"
    fi
fi

# Get Tailscale IP
TS_IP=$(tailscale ip -4 2>/dev/null)
echo -e "  Tailscale IP: ${BOLD}${TS_IP}${NC}"

# ─── 6. Find manager on Tailscale network ──────────────────────────────────────

echo -ne "${CYAN}[6/7]${NC} Connecting to manager... "

MANAGER="${MANAGER_USER}@${MANAGER_HOST}"
MANAGER_PORT=22

echo -e "${GREEN}${MANAGER}${NC}"

# ─── Exchange SSH keys via Tailscale ────────────────────────────────────────────

echo -e "  ${DIM}Setting up SSH key exchange (may ask for password once)...${NC}"

# Our key -> manager
ssh-copy-id -i "${SSH_KEY}.pub" -p "$MANAGER_PORT" -o ConnectTimeout=10 "$MANAGER" 2>/dev/null || {
    echo -e "  ${YELLOW}Auto key copy failed. You can add manually later.${NC}"
}

# Manager's key -> us
MANAGER_KEY=$(ssh -p "$MANAGER_PORT" -o ConnectTimeout=10 "$MANAGER" "cat ~/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_rsa.pub 2>/dev/null" 2>/dev/null || echo "")
if [[ -n "$MANAGER_KEY" ]]; then
    touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
    grep -qF "$MANAGER_KEY" "$HOME/.ssh/authorized_keys" 2>/dev/null || echo "$MANAGER_KEY" >> "$HOME/.ssh/authorized_keys"
    echo -e "  ${GREEN}Keys exchanged${NC}"
else
    echo -e "  ${YELLOW}Couldn't get manager key. Run from manager: ssh-copy-id $(whoami)@${TS_IP}${NC}"
fi

# ─── 7. Register + Install Agent ───────────────────────────────────────────────

echo -ne "${CYAN}[7/7]${NC} Registering with manager... "

THIS_USER=$(whoami)
THIS_PORT=22
REGISTER_IP="$TS_IP"

REGISTER_CMD="mkdir -p \$HOME/.config/rtmux; F=\$HOME/.config/rtmux/hosts.json; [ -f \"\$F\" ] || echo '{\"hosts\":{}}' > \"\$F\"; T=\$(mktemp); jq --arg a \"$ALIAS\" --arg h \"$REGISTER_IP\" --arg u \"$THIS_USER\" --arg p \"$THIS_PORT\" '.hosts[\$a]={host:\$h,user:\$u,port:(\$p|tonumber),identity:\"\"}' \"\$F\" > \"\$T\" && mv \"\$T\" \"\$F\" && echo ok"

result=$(ssh -p "$MANAGER_PORT" -o ConnectTimeout=10 "$MANAGER" "$REGISTER_CMD" 2>/dev/null) || true

if [[ "$result" == *"ok"* ]]; then
    echo -e "${GREEN}registered!${NC}"
else
    echo -e "${YELLOW}auto-register failed${NC}"
    echo -e "  Run on manager: ${CYAN}rtmux add-host ${ALIAS} ${REGISTER_IP} ${THIS_USER} ${THIS_PORT}${NC}"
fi

# ─── Install rtmux-agent service ────────────────────────────────────────────────

echo -ne "  Installing agent service... "

sudo mkdir -p /opt/rtmux /etc/rtmux

# Agent daemon
sudo tee /opt/rtmux/agent.sh > /dev/null <<'AGENTEOF'
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
sudo chmod +x /opt/rtmux/agent.sh

# Control script
sudo tee /opt/rtmux/ctl.sh > /dev/null <<'CTLEOF'
#!/usr/bin/env bash
CONFIG_DIR="/etc/rtmux"
SESSIONS_FILE="$CONFIG_DIR/sessions.json"
mkdir -p "$CONFIG_DIR"
[[ -f "$SESSIONS_FILE" ]] || echo '{"sessions":["main"],"auto_restart":true}' > "$SESSIONS_FILE"

case "${1:-}" in
    add)
        [[ -z "${2:-}" ]] && { echo "Usage: rtmux-ctl add <session>"; exit 1; }
        TMP=$(mktemp)
        jq --arg s "$2" '.sessions += [$s] | .sessions |= unique' "$SESSIONS_FILE" > "$TMP" && sudo mv "$TMP" "$SESSIONS_FILE"
        echo "Added '$2' - agent will create it within 60s"
        ;;
    remove)
        [[ -z "${2:-}" ]] && { echo "Usage: rtmux-ctl remove <session>"; exit 1; }
        TMP=$(mktemp)
        jq --arg s "$2" '.sessions -= [$s]' "$SESSIONS_FILE" > "$TMP" && sudo mv "$TMP" "$SESSIONS_FILE"
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
sudo chmod +x /opt/rtmux/ctl.sh
sudo ln -sf /opt/rtmux/ctl.sh /usr/local/bin/rtmux-ctl 2>/dev/null || true

# Systemd service
sudo tee /etc/systemd/system/rtmux-agent.service > /dev/null <<SVCEOF
[Unit]
Description=rtmux persistent session agent
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/rtmux/agent.sh
Restart=always
RestartSec=5
User=$(whoami)
Environment=HOME=$HOME
Environment=RTMUX_HEARTBEAT=60

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable rtmux-agent
sudo systemctl start rtmux-agent

echo -e "${GREEN}done${NC}"

# Create initial session
tmux has-session -t main 2>/dev/null || tmux new-session -d -s main

# ─── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  ${GREEN}Setup complete!${NC}${BOLD}                                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}This PC:${NC} ${ALIAS}"
echo -e "  ${BOLD}Tailscale IP:${NC} ${TS_IP}"
echo -e "  ${BOLD}Manager:${NC} ${MANAGER}"
echo ""
echo -e "  ${GREEN}●${NC} Tailscale connected (zero-config networking)"
echo -e "  ${GREEN}●${NC} rtmux-agent running (auto-start, auto-restart)"
echo -e "  ${GREEN}●${NC} tmux session 'main' active (recreates if killed)"
echo -e "  ${GREEN}●${NC} SSH keys exchanged"
echo ""
echo -e "  ${BOLD}On your manager PC, run:${NC}"
echo -e "    ${CYAN}rtmux ls ${ALIAS}${NC}"
echo -e "    ${CYAN}rtmux open ${ALIAS} main${NC}"
echo -e "    ${CYAN}rtmux new ${ALIAS} claude${NC}"
echo -e "    ${CYAN}rtmux dashboard${NC}"
echo ""
echo -e "  ${DIM}Manager has full control. No further setup needed on this PC.${NC}"
