#!/bin/bash
clear

LOG_FILE="/tmp/archinstall-webui.log"
STATE_FILE="/tmp/archinstall-state.txt"
echo "--- NEW INSTALLATION SESSION: $(date) ---" > "$LOG_FILE"
echo "0|Waiting for WebUI matrix payload...|idle" > "$STATE_FILE"

print_step() { echo -e "\e[1;34m[ \e[1;37m$1\e[1;34m ]\e[0m \e[1;36m$2...\e[0m"; }
print_success() { echo -e "\e[1;32m[ ✔ ]\e[0m \e[1;37m$1\e[0m\n"; }
print_error() { echo -e "\n\e[1;31m[ ✘ ] ERROR:\e[0m \e[1;37m$1\e[0m\n"; exit 1; }

cleanup() {
    pkill -9 -f "server.py" >> "$LOG_FILE" 2>&1
    pkill -9 -f "localhost.run" >> "$LOG_FILE" 2>&1
}
trap cleanup EXIT INT TERM

print_step "1/4" "Synchronizing system package databases"
mkdir -p /var/cache/pacman/pkg
pacman -Sy --noconfirm qrencode archinstall >> "$LOG_FILE" 2>&1 || print_error "Failed to install dependencies."
print_success "Dependencies installed successfully"

print_step "2/4" "Pulling WebUI repository assets"
RUN_DIR="/tmp/arch-webui"
mkdir -p "$RUN_DIR" && cd "$RUN_DIR"
REPO_RAW_URL="https://raw.githubusercontent.com/AmmarYasserIbrahim/archinstall-webui/refs/heads/main"

curl -sO "${REPO_RAW_URL}/server.py"
curl -sO "${REPO_RAW_URL}/index.html"
print_success "Application logic downloaded"

print_step "3/4" "Starting Python engine socket"
python3 "${RUN_DIR}/server.py" &
PYTHON_PID=$!

sleep 2
if ! kill -0 $PYTHON_PID 2>/dev/null; then
    print_error "Backend engine failed to start. Check $LOG_FILE"
fi
print_success "Engine running on port 5000"

print_step "4/4" "Establishing remote access tunnels"
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I | awk '{print $1}')

ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=5 \
    -R 80:localhost:5000 nokey@localhost.run >> "$LOG_FILE" 2>&1 &
SSH_PID=$!

PUBLIC_URL=""
for i in {1..20}; do
    PUBLIC_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.lhr\.life" "$LOG_FILE" | tail -n 1)
    [ ! -z "$PUBLIC_URL" ] && break
    sleep 1
done

DISPLAY_URL=${PUBLIC_URL:-"http://${LOCAL_IP}:5000"}
CONNECTION_MODE=$( [ ! -z "$PUBLIC_URL" ] && echo "PUBLIC TUNNEL" || echo "LAN (Tunnel Timeout)" )
print_success "Network routing configured"

clear
echo -e "\e[1;36m=========================================\e[0m"
echo -e "\e[1;37m        ARCH LINUX WEB INSTALLER         \e[0m"
echo -e "\e[1;36m=========================================\e[0m\n"
qrencode -t utf8i "${DISPLAY_URL}"
echo -e "\n \e[1;37mURL:\e[0m  \e[1;32m${DISPLAY_URL}\e[0m"
echo -e " \e[1;37mMode:\e[0m \e[1;33m${CONNECTION_MODE}\e[0m\n"

echo -e "\e[1;34m[ * ]\e[0m \e[1;37mAwaiting WebUI configuration payload...\e[0m"
echo -e "\e[1;30m      (Leave this terminal open. Live progress will render below)\e[0m\n"

# TUI Progress Bar Render Loop
while kill -0 $PYTHON_PID 2>/dev/null; do
    if [ -f "$STATE_FILE" ]; then
        IFS='|' read -r pct msg status < "$STATE_FILE"
        if [ -n "$pct" ]; then
            filled=$(( pct * 40 / 100 ))
            empty=$(( 40 - filled ))
            
            bar=""; for ((i=0; i<filled; i++)); do bar="${bar}#"; done
            space=""; for ((i=0; i<empty; i++)); do space="${space}-"; done
            
            printf "\r\e[K\e[1;34m[\e[1;32m%s\e[1;30m%s\e[1;34m]\e[0m \e[1;33m%3d%%\e[0m \e[1;37m%s\e[0m" "$bar" "$space" "$pct" "$msg"
            
            if [ "$status" = "completed" ] || [ "$status" = "error" ]; then
                echo -e "\n"
                break
            fi
        fi
    fi
    sleep 1
done