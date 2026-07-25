#!/bin/bash
set -u
clear

LOG_FILE="/tmp/archinstall-webui.log"
STATE_FILE="/tmp/archinstall-state.txt"
RUN_DIR="/tmp/arch-webui"
REPO_RAW_URL_DEFAULT="https://raw.githubusercontent.com/AmmarYasserIbrahim/archinstall-webui/main"
REPO_RAW_URL="${ARCHWEBUI_REPO_RAW_URL:-$REPO_RAW_URL_DEFAULT}"
TUNNEL_MODE="${ARCHWEBUI_TUNNEL_MODE:-auto}" # auto|localhostrun|none
PUBLIC_TUNNEL_HOST="${ARCHWEBUI_TUNNEL_HOST:-localhost.run}"
PORT="${ARCHWEBUI_PORT:-5000}"

: > "$LOG_FILE"
echo "--- NEW INSTALLATION SESSION: $(date) ---" >> "$LOG_FILE"
echo "0|Waiting for WebUI matrix payload...|idle" > "$STATE_FILE"

PYTHON_PID=""
SSH_PID=""

print_step() { echo -e "\e[1;34m[ \e[1;37m$1\e[1;34m ]\e[0m \e[1;36m$2...\e[0m"; }
print_success() { echo -e "\e[1;32m[ ✔ ]\e[0m \e[1;37m$1\e[0m\n"; }
print_error() { echo -e "\n\e[1;31m[ ✘ ] ERROR:\e[0m \e[1;37m$1\e[0m\n"; exit 1; }

cleanup() {
    [ -n "$PYTHON_PID" ] && kill -9 "$PYTHON_PID" >/dev/null 2>&1
    [ -n "$SSH_PID" ] && kill -9 "$SSH_PID" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

print_step "1/4" "Synchronizing package databases"
mkdir -p /var/cache/pacman/pkg
pacman -Sy --noconfirm qrencode python >> "$LOG_FILE" 2>&1 || print_error "Failed to install dependencies."
print_success "Dependencies installed"

print_step "2/4" "Pulling WebUI repository assets"
mkdir -p "$RUN_DIR"
cd "$RUN_DIR" || print_error "Failed to create runtime directory."
curl -fsS -o server.py "${REPO_RAW_URL}/server.py" >> "$LOG_FILE" 2>&1 || print_error "Failed to download server.py"
curl -fsS -o index.html "${REPO_RAW_URL}/index.html" >> "$LOG_FILE" 2>&1 || print_error "Failed to download index.html"
print_success "Application logic downloaded"

print_step "3/4" "Starting Python backend"
ARCHWEBUI_PORT="$PORT" python3 "${RUN_DIR}/server.py" >> "$LOG_FILE" 2>&1 &
PYTHON_PID=$!

sleep 2
if ! kill -0 "$PYTHON_PID" 2>/dev/null; then
    print_error "Backend failed to start. Check $LOG_FILE"
fi
print_success "Backend running on port ${PORT}"

print_step "4/4" "Preparing access URL"
LOCAL_IP=$(ip -o -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]\+\).*/\1/p')
[ -z "$LOCAL_IP" ] && LOCAL_IP=$(hostname -I | awk '{print $1}')

PUBLIC_URL=""
if [ "$TUNNEL_MODE" = "auto" ] || [ "$TUNNEL_MODE" = "localhostrun" ]; then
    ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=5 \
        -R "80:localhost:${PORT}" "nokey@${PUBLIC_TUNNEL_HOST}" >> "$LOG_FILE" 2>&1 &
    SSH_PID=$!

    for i in {1..20}; do
        PUBLIC_URL=$(grep -oE "https://[a-zA-Z0-9.-]+" "$LOG_FILE" | tail -n 1)
        [ -n "$PUBLIC_URL" ] && break
        sleep 1
    done
fi

if [ -n "$PUBLIC_URL" ]; then
    DISPLAY_URL="$PUBLIC_URL"
    CONNECTION_MODE="PUBLIC TUNNEL"
else
    DISPLAY_URL="http://${LOCAL_IP}:${PORT}"
    CONNECTION_MODE="LAN"
fi
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

done_flag=""
while kill -0 "$PYTHON_PID" 2>/dev/null; do
    if [ -f "$STATE_FILE" ]; then
        IFS='|' read -r pct msg status < "$STATE_FILE"
        if [ -n "$pct" ]; then
            filled=$(( pct * 20 / 100 ))
            empty=$(( 20 - filled ))

            bar=""; for ((i=0; i<filled; i++)); do bar="${bar}#"; done
            space=""; for ((i=0; i<empty; i++)); do space="${space}-"; done

            TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
            MAX_MSG=$(( TERM_WIDTH - 32 ))
            [ "$MAX_MSG" -lt 10 ] && MAX_MSG=10

            short_msg="${msg}"
            if [ ${#short_msg} -gt $MAX_MSG ]; then
                short_msg="${short_msg:0:$MAX_MSG}..."
            fi

            if [ "$status" = "error" ]; then
                printf "\r\e[K\e[1;31m[\e[1;31m%s\e[1;30m%s\e[1;31m]\e[0m \e[1;31m%3d%%\e[0m \e[1;31m%s\e[0m" "$bar" "$space" "$pct" "$short_msg"
                echo -e "\n"
                break
            else
                if [ "$status" != "completed" ] || [ -z "$done_flag" ]; then
                    printf "\r\e[K\e[1;34m[\e[1;32m%s\e[1;30m%s\e[1;34m]\e[0m \e[1;33m%3d%%\e[0m \e[1;37m%s\e[0m" "$bar" "$space" "$pct" "$short_msg"
                fi
            fi

            if [ "$status" = "completed" ] && [ -z "$done_flag" ]; then
                echo -e "\n\n\e[1;32m[ ✔ ] Installation Successful! Awaiting reboot command from WebUI...\e[0m"
                done_flag="1"
            fi
        fi
    fi
    sleep 1
done
