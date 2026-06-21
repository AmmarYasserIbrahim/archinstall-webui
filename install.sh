#!/bin/bash
clear

LOG_FILE="/tmp/archinstall-webui.log"
echo "--- NEW INSTALLATION SESSION: $(date) ---" > "$LOG_FILE"

cleanup() {
    pkill -9 -f "server.py" >> "$LOG_FILE" 2>&1
    pkill -9 -f "localhost.run" >> "$LOG_FILE" 2>&1
}
trap cleanup EXIT INT TERM

# Install dependencies if missing
mkdir -p /var/cache/pacman/pkg
pacman -Sy --noconfirm qrencode archinstall >> "$LOG_FILE" 2>&1

# Launch Python backend natively
python3 server.py &
PYTHON_PID=$!

sleep 1
if ! kill -0 $PYTHON_PID 2>/dev/null; then
    echo "Failed to start server.py. Check $LOG_FILE"
    exit 1
fi

# Set up tunnel
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=5 \
    -R 80:localhost:5000 nokey@localhost.run >> "$LOG_FILE" 2>&1 &
SSH_PID=$!

# Resolve URLs
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I | awk '{print $1}')

for i in {1..20}; do
    PUBLIC_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.lhr\.life" "$LOG_FILE" | tail -n 1)
    [ ! -z "$PUBLIC_URL" ] && break
    sleep 1
done

DISPLAY_URL=${PUBLIC_URL:-"http://${LOCAL_IP}:5000"}
CONNECTION_MODE=$( [ ! -z "$PUBLIC_URL" ] && echo "PUBLIC TUNNEL" || echo "LAN" )

clear
qrencode -t utf8i "${DISPLAY_URL}"
echo -e "\n URL:  ${DISPLAY_URL}\n Mode: ${CONNECTION_MODE}\n"

while kill -0 $PYTHON_PID 2>/dev/null; do sleep 3; done