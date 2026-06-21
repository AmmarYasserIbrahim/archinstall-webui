#!/bin/bash
clear

LOG_FILE="/tmp/archinstall-webui.log"
echo "--- NEW INSTALLATION SESSION: $(date) ---" > "$LOG_FILE"

cleanup() {
    pkill -9 -f "server.py" >> "$LOG_FILE" 2>&1
    pkill -9 -f "localhost.run" >> "$LOG_FILE" 2>&1
}
trap cleanup EXIT INT TERM

# Install system dependencies if missing
mkdir -p /var/cache/pacman/pkg
pacman -Sy --noconfirm qrencode archinstall >> "$LOG_FILE" 2>&1

# Move to a predictable working path and grab the runtime assets
RUN_DIR="/tmp/arch-webui"
mkdir -p "$RUN_DIR" && cd "$RUN_DIR"
REPO_RAW_URL="https://raw.githubusercontent.com/AmmarYasserIbrahim/archinstall-webui/refs/heads/main"

curl -sO "${REPO_RAW_URL}/server.py"
curl -sO "${REPO_RAW_URL}/index.html"

# Launch Python backend natively using absolute path
python3 "${RUN_DIR}/server.py" &
PYTHON_PID=$!

sleep 2
if ! kill -0 $PYTHON_PID 2>/dev/null; then
    echo "Failed to start server.py. Check $LOG_FILE"
    exit 1
fi

# Resolve local IP address immediately
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I | awk '{print $1}')

echo "Initializing secure remote tunnel mapping..."

# Set up tunnel and force SSH to flush its output instantly without buffering
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=5 \
    -R 80:localhost:5000 nokey@localhost.run >> "$LOG_FILE" 2>&1 &
SSH_PID=$!

# Dynamic Log Watcher: Actively monitors the file stream until the URL hits
PUBLIC_URL=""
TIMEOUT=25
START_TIME=$(date +%s)

while true; do
    # Scan the log for the target pattern
    PUBLIC_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.lhr\.life" "$LOG_FILE" | tail -n 1)
    
    # Break out early if we successfully caught the URL mapping
    [ ! -z "$PUBLIC_URL" ] && break
    
    # Enforce safe fallback if the connection takes too long
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))
    if [ $ELAPSED -ge $TIMEOUT ]; then
        break
    fi
    
    sleep 0.5
done

DISPLAY_URL=${PUBLIC_URL:-"http://${LOCAL_IP}:5000"}
CONNECTION_MODE=$( [ ! -z "$PUBLIC_URL" ] && echo "PUBLIC TUNNEL" || echo "LAN (Tunnel Timeout)" )

clear
qrencode -t utf8i "${DISPLAY_URL}"
echo -e "\n URL:  ${DISPLAY_URL}\n Mode: ${CONNECTION_MODE}\n"

while kill -0 $PYTHON_PID 2>/dev/null; do sleep 3; done