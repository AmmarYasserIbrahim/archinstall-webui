#!/bin/bash
clear
echo "===================================================================="
echo "    Æ   NATIVE ARCHINSTALL DECENTRALIZED ENGINE INITIALIZING        "
echo "===================================================================="
echo " [+] Validating local Arch Linux packages..."

# 1. Update live ISO repos and install required tunnel/QR tools
pacman -Sy --noconfirm qrencode archinstall >/dev/null 2>&1

mkdir -p /tmp/engine && cd /tmp/engine

echo " [+] Generating local server infrastructure natively..."

# ====================================================================
# 2. DYNAMIC PYTHON GATEWAY (server.py)
# ====================================================================
cat << 'EOF' > server.py
import http.server
import socketserver
import json
import subprocess
import os
import threading
import time
from urllib.parse import urlparse

PORT = 5000
CONFIG_PATH = '/tmp/config.json'
CREDS_PATH = '/tmp/creds.json'
LOG_PATH = '/var/log/archinstall-web.log'

install_state = {"percentage": 0, "message": "Awaiting mobile configuration matrix...", "status": "idle"}

def get_system_telemetry():
    telemetry = {"cpu": "Unknown", "boot_mode": "BIOS", "hardware": {}}
    try:
        cpu_out = subprocess.check_output('lscpu | grep "Model name:" | sed "s/Model name: *//"', shell=True)
        telemetry['cpu'] = cpu_out.decode('utf-8').strip()
    except: pass
    
    telemetry['boot_mode'] = "UEFI" if os.path.exists('/sys/firmware/efi/efivars') else "BIOS"
    
    try:
        lsblk_out = subprocess.check_output('lsblk -Jno NAME,SIZE,TYPE', shell=True)
        telemetry['hardware'] = json.loads(lsblk_out.decode('utf-8'))
    except: pass
    return telemetry

def run_archinstall():
    global install_state
    install_state = {"percentage": 5, "message": "Synchronizing pacman mirror repositories...", "status": "running"}
    os.system('pacman -Sy --noconfirm > /dev/null 2>&1')

    install_state = {"percentage": 10, "message": "Initializing official Archinstall engine...", "status": "running"}
    
    # Run the official package silently using our generated JSON
    cmd = ["archinstall", "--config", CONFIG_PATH, "--creds", CREDS_PATH, "--silent"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    
    with open(LOG_PATH, 'w') as log_file:
        for line in process.stdout:
            log_file.write(line)
            log_file.flush()
            lower_line = line.lower()
            
            if "formatting" in lower_line or "creating file system" in lower_line:
                install_state = {"percentage": 15, "message": "Formatting storage block devices...", "status": "running"}
            elif "waiting for time sync" in lower_line:
                install_state = {"percentage": 20, "message": "Synchronizing system hardware clocks...", "status": "running"}
            elif "pacstrap" in lower_line or "installing packages" in lower_line:
                install_state = {"percentage": 45, "message": "Extracting base system packages (Pacstrap)...", "status": "running"}
            elif "bootloader" in lower_line or "systemd-boot" in lower_line or "grub" in lower_line:
                install_state = {"percentage": 75, "message": "Injecting bootloader configurations...", "status": "running"}
            elif "profile" in lower_line or "desktop" in lower_line:
                install_state = {"percentage": 85, "message": "Compiling targeted desktop environments...", "status": "running"}
            elif "services" in lower_line or "networkmanager" in lower_line:
                install_state = {"percentage": 92, "message": "Enabling core systemd runtime services...", "status": "running"}
            elif "installation completed" in lower_line:
                install_state = {"percentage": 100, "message": "Build Successful! System ready for reboot.", "status": "completed"}
                
    process.wait()
    if process.returncode == 0:
        install_state = {"percentage": 100, "message": "Build Successful! System ready for reboot.", "status": "completed"}
    else:
        install_state = {"percentage": 99, "message": f"Archinstall halted with exit code {process.returncode}. Check logs.", "status": "error"}

class APIHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200, "ok")
        self.end_headers()

    def do_GET(self):
        parsed_path = urlparse(self.path).path
        if parsed_path == '/':
            self.path = '/index.html'
            return http.server.SimpleHTTPRequestHandler.do_GET(self)
        
        elif parsed_path == '/api/status':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(get_system_telemetry()).encode('utf-8'))

        elif parsed_path == '/api/progress':
            self.send_response(200)
            self.send_header('Content-type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache')
            self.end_headers()
            
            try:
                while True:
                    self.wfile.write(f"data: {json.dumps(install_state)}\n\n".encode('utf-8'))
                    self.wfile.flush()
                    if install_state["status"] in ["completed", "error"]:
                        break
                    time.sleep(1)
            except: pass
        else:
            return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        parsed_path = urlparse(self.path).path
        if parsed_path == '/api/submit':
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))
            
            with open(CONFIG_PATH, 'w') as f:
                json.dump(post_data.get('config', {}), f, indent=4)
            with open(CREDS_PATH, 'w') as f:
                json.dump(post_data.get('creds', {}), f, indent=4)

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            
            threading.Thread(target=run_archinstall).start()
            
        elif parsed_path == '/api/reboot':
            self.send_response(200)
            self.end_headers()
            os.system('umount -R /mnt && reboot')

with socketserver.ThreadingTCPServer(("", PORT), APIHandler) as httpd:
    httpd.serve_forever()
EOF

# ====================================================================
# 3. DYNAMICALLY GENERATE THE WEB UI FRONTEND (index.html)
# ====================================================================
cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Archinstall Core UI</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&family=JetBrains+Mono:wght@400;700&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', sans-serif; background: #020617; color: #f8fafc; }
    </style>
</head>
<body class="min-h-screen flex items-center justify-center p-4">

    <div class="w-full max-w-2xl bg-slate-900 border border-slate-800 rounded-2xl shadow-2xl overflow-hidden flex flex-col">
        
        <div class="bg-slate-950 px-6 py-4 border-b border-slate-800 flex justify-between items-center">
            <div class="flex items-center gap-3">
                <div class="bg-sky-500 text-white font-black h-8 w-8 rounded-lg flex items-center justify-center">Æ</div>
                <div>
                    <span class="font-bold tracking-wide uppercase text-sm text-slate-200 block">Archinstall Engine</span>
                    <span class="text-[10px] text-slate-500 font-mono block -mt-0.5" id="target-cpu">Connecting to hardware...</span>
                </div>
            </div>
            <span id="step-indicator" class="text-xs font-bold bg-slate-800 px-3 py-1 rounded-full text-slate-300">Step 1 of 4</span>
        </div>

        <div class="p-6">
            <form id="wizard-form" class="space-y-6">
                
                <div id="step-1" class="wizard-step block space-y-5">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-sky-400">1. Storage Architecture</h2>
                        <p class="text-xs text-slate-500">Select the target block device and formatting parameters.</p>
                    </div>
                    <div>
                        <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Target Drive Block</label>
                        <select id="disk" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-sky-500"></select>
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Filesystem Structure</label>
                            <select id="fs" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                                <option value="ext4">Ext4 (Journaled Standard)</option>
                                <option value="btrfs">Btrfs (Modern CoW Pool)</option>
                                <option value="xfs">XFS (High Performance)</option>
                            </select>
                        </div>
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Bootloader Hook</label>
                            <select id="bootloader" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                                <option value="systemd-boot">Systemd-boot (UEFI Only)</option>
                                <option value="grub-install">GRUB 2 (Universal)</option>
                            </select>
                        </div>
                    </div>
                    <div class="flex items-center gap-3 p-3.5 bg-slate-950 border border-slate-800 rounded-lg">
                        <input type="checkbox" id="swap" checked class="w-4 h-4 accent-sky-500">
                        <div>
                            <span class="text-sm font-semibold text-slate-200 block">Allocate zRAM Swap Module</span>
                        </div>
                    </div>
                </div>

                <div id="step-2" class="wizard-step hidden space-y-5">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-sky-400">2. Software & Ecosystem</h2>
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Desktop Environment</label>
                            <select id="desktop" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                                <option value="awesome">Awesome WM</option>
                                <option value="kde">KDE Plasma</option>
                                <option value="gnome">GNOME</option>
                                <option value="none">No GUI (Headless Server)</option>
                            </select>
                        </div>
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Linux Kernel Payload</label>
                            <select id="kernel" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                                <option value="linux">Standard Upstream (linux)</option>
                                <option value="linux-lts">Long Term Support (linux-lts)</option>
                            </select>
                        </div>
                    </div>
                    <div>
                        <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Audio Server</label>
                        <select id="audio" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                            <option value="pipewire">Pipewire (Modern Default)</option>
                            <option value="pulseaudio">PulseAudio (Legacy)</option>
                        </select>
                    </div>
                </div>

                <div id="step-3" class="wizard-step hidden space-y-5">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-sky-400">3. Identity & Credentials</h2>
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Hostname</label>
                            <input type="text" id="hostname" value="arch-workstation" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                        </div>
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Timezone</label>
                            <input type="text" id="timezone" value="Africa/Cairo" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none">
                        </div>
                    </div>
                    <div class="p-4 bg-slate-950 border border-slate-800 rounded-xl space-y-4">
                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <label class="block text-[10px] font-bold text-slate-500 uppercase mb-1">Username</label>
                                <input type="text" id="username" placeholder="e.g. admin" class="w-full bg-slate-900 border border-slate-800 rounded-lg p-3 text-sm outline-none text-slate-200">
                            </div>
                            <div>
                                <label class="block text-[10px] font-bold text-slate-500 uppercase mb-1">User Password</label>
                                <input type="password" id="password" class="w-full bg-slate-900 border border-slate-800 rounded-lg p-3 text-sm outline-none text-slate-200">
                            </div>
                        </div>
                        <div>
                            <label class="block text-[10px] font-bold text-rose-500 uppercase mb-1">Superuser Root Password</label>
                            <input type="password" id="root-password" class="w-full bg-slate-900 border border-rose-900/50 rounded-lg p-3 text-sm outline-none text-slate-200">
                        </div>
                    </div>
                </div>

                <div id="step-4" class="wizard-step hidden space-y-6">
                    <div class="text-center space-y-2">
                        <h2 class="text-2xl font-black text-white">Deploying Infrastructure</h2>
                        <p id="progress-msg" class="text-sm font-medium text-sky-400 font-mono">Transmitting JSON compilation maps...</p>
                    </div>
                    
                    <div class="flex items-center justify-between font-mono text-xs font-bold text-slate-400">
                        <span>INIT</span>
                        <span id="progress-pct" class="text-3xl text-white tracking-tighter">0%</span>
                        <span>DONE</span>
                    </div>

                    <div class="w-full bg-slate-950 rounded-full h-4 border border-slate-800 p-0.5 overflow-hidden shadow-inner">
                        <div id="progress-bar-fill" class="bg-gradient-to-r from-sky-500 to-emerald-400 h-full rounded-full w-0 transition-all duration-500 ease-out"></div>
                    </div>

                    <button type="button" id="btn-reboot" class="hidden w-full bg-gradient-to-r from-emerald-600 to-teal-600 hover:from-emerald-500 hover:to-teal-500 text-white font-bold p-4 rounded-xl uppercase tracking-widest text-sm transition-all shadow-lg shadow-emerald-900/50 mt-4 active:scale-95">
                        Close Volumes & Reboot
                    </button>
                </div>
            </form>
        </div>

        <div id="nav-footer" class="bg-slate-950 px-6 py-4 border-t border-slate-800 flex justify-between items-center">
            <button type="button" id="btn-back" class="text-slate-500 hover:text-white font-bold text-sm tracking-wide hidden transition-colors">Back</button>
            <button type="button" id="btn-next" class="ml-auto bg-sky-600 hover:bg-sky-500 text-white font-bold py-2.5 px-6 rounded-lg text-sm tracking-wide transition-all shadow-lg shadow-sky-900/50 active:scale-95">Next Step</button>
        </div>
    </div>

    <script>
        let currentStep = 1;
        const totalSteps = 4;
        
        fetch('/api/status').then(r => r.json()).then(data => {
            document.getElementById('target-cpu').innerText = `${data.cpu} | ${data.boot_mode}`;
            const diskSelect = document.getElementById('disk');
            data.hardware.blockdevices.forEach(dev => {
                if(dev.type === 'disk') {
                    diskSelect.innerHTML += `<option value="/dev/${dev.name}">/dev/${dev.name} (${dev.size})</option>`;
                }
            });
        });

        document.getElementById('btn-next').addEventListener('click', () => {
            if (currentStep === 3) { submitArchinstallConfig(); }
            if (currentStep < totalSteps) {
                document.getElementById(`step-${currentStep}`).classList.add('hidden');
                currentStep++;
                document.getElementById(`step-${currentStep}`).classList.remove('hidden');
                updateUI();
            }
        });

        document.getElementById('btn-back').addEventListener('click', () => {
            if (currentStep > 1 && currentStep < totalSteps) {
                document.getElementById(`step-${currentStep}`).classList.add('hidden');
                currentStep--;
                document.getElementById(`step-${currentStep}`).classList.remove('hidden');
                updateUI();
            }
        });

        function updateUI() {
            document.getElementById('step-indicator').innerText = `Step ${currentStep} of 3`;
            document.getElementById('btn-back').style.display = (currentStep > 1 && currentStep < 4) ? 'block' : 'none';
            
            if (currentStep === 3) {
                document.getElementById('btn-next').innerText = "Execute Native Build";
                document.getElementById('btn-next').className = "ml-auto bg-emerald-600 hover:bg-emerald-500 text-white font-bold py-2.5 px-6 rounded-lg text-sm tracking-wide transition-all shadow-lg shadow-emerald-900/50 active:scale-95";
            } else if (currentStep === 4) {
                document.getElementById('nav-footer').style.display = 'none';
            } else {
                document.getElementById('btn-next').innerText = "Next Step";
                document.getElementById('btn-next').className = "ml-auto bg-sky-600 hover:bg-sky-500 text-white font-bold py-2.5 px-6 rounded-lg text-sm tracking-wide transition-all shadow-lg shadow-sky-900/50 active:scale-95";
            }
        }

        async function submitArchinstallConfig() {
            const diskVal = document.getElementById('disk').value;
            const desktopVal = document.getElementById('desktop').value;
            const bootloaderVal = document.getElementById('bootloader').value;
            const fsVal = document.getElementById('fs').value;
            
            const configPayload = {
                "archinstall-language": "English",
                "audio_config": { "audio": document.getElementById('audio').value },
                "bootloader": bootloaderVal,
                "harddrives": [diskVal],
                "disk_config": {
                    "config_type": "default_layout",
                    "device_modifications": [
                        { "device": diskVal, "wipe": true, "partitions": [
                            { "btrfs": [], "flags": ["boot"], "fs_type": "fat32", "mountpoint": "/boot", "size": {"unit": "MiB", "value": 512}, "start": {"unit": "MiB", "value": 1}, "status": "create", "type": "primary" },
                            { "btrfs": [], "flags": [], "fs_type": fsVal, "mountpoint": "/", "size": {"unit": "B", "value": 100}, "start": {"unit": "MiB", "value": 513}, "status": "create", "type": "primary" }
                        ]}
                    ]
                },
                "hostname": document.getElementById('hostname').value,
                "kernels": [document.getElementById('kernel').value],
                "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
                "mirror_config": { "mirror_regions": { "Worldwide": ["https://geo.mirror.pkgbuild.com/$repo/os/$arch"] } },
                "network_config": { "type": "NetworkManager" },
                "swap": document.getElementById('swap').checked,
                "timezone": document.getElementById('timezone').value
            };

            if (desktopVal !== "none") {
                configPayload["profile_config"] = { "profile": { "details": [desktopVal], "type": "desktop" } };
            }

            const credsPayload = {
                "root-password": document.getElementById('root-password').value,
                "users": [{
                    "username": document.getElementById('username').value,
                    "password": document.getElementById('password').value,
                    "sudo": true
                }]
            };

            await fetch('/api/submit', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ config: configPayload, creds: credsPayload })
            });

            startTerminalStream();
        }

        function startTerminalStream() {
            const stream = new EventSource('/api/progress');
            
            stream.onmessage = (event) => {
                const data = JSON.parse(event.data);
                
                document.getElementById('progress-msg').innerText = data.message;
                document.getElementById('progress-pct').innerText = `${data.percentage}%`;
                document.getElementById('progress-bar-fill').style.width = `${data.percentage}%`;

                if(data.status === "error") {
                    document.getElementById('progress-msg').classList.replace('text-sky-400', 'text-rose-500');
                    document.getElementById('progress-bar-fill').classList.replace('from-sky-500', 'from-rose-500');
                    document.getElementById('progress-bar-fill').classList.replace('to-emerald-400', 'to-rose-400');
                    stream.close();
                }

                if(data.status === "completed") {
                    document.getElementById('btn-reboot').classList.remove('hidden');
                    stream.close();
                }
            };
        }

        document.getElementById('btn-reboot').addEventListener('click', async () => {
            await fetch('/api/reboot', { method: 'POST' });
            document.getElementById('btn-reboot').innerText = "Rebooting Hardware...";
            document.getElementById('btn-reboot').classList.add('opacity-50', 'cursor-not-allowed');
        });
    </script>
</body>
</html>
EOF

# ====================================================================
# 4. INITIALIZE SERVER & TUNNEL WITH CLEAN TERMINAL OUTPUT
# ====================================================================
echo " [+] Spinning up the Python background logic..."
python3 server.py &
PYTHON_PID=$!

echo " [+] Negotiating high-speed encrypted outbound tunnel layers..."
# Use standard flags to make sure the SSH output doesn't buffer abnormally
ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=5 -R 80:localhost:5000 free.pinggy.io > /tmp/tunnel.log 2>&1 &
SSH_PID=$!

sleep 5

# Scrape the public HTTPS tunnel output URL out of the log
PUBLIC_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.pinggy\.link" /tmp/tunnel.log | head -n 1)
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
if [ -z "$LOCAL_IP" ]; then
    LOCAL_IP=$(hostname -I | awk '{print $1}')
fi

# Fallback block: If public tunnel fails, route everything seamlessly over LAN
if [ -z "$PUBLIC_URL" ]; then
    DISPLAY_URL="http://${LOCAL_IP}:5000"
    CONNECTION_MODE="⚠️  LOCAL AREA NETWORK FALLBACK (Tunnel Failed)"
else
    DISPLAY_URL="${PUBLIC_URL}"
    CONNECTION_MODE="🌐 SECURE PUBLIC SSH TUNNEL"
fi

clear
echo "===================================================================="
echo "   NATIVE DEPLOYMENT GATEWAY ACTIVE                                "
echo "===================================================================="
echo " Connection Mode: ${CONNECTION_MODE}"
echo " Interface URL:   ${DISPLAY_URL}"
echo "===================================================================="
echo ""
qrencode -t utf8i "${DISPLAY_URL}"
echo ""
echo " ⏳ Awaiting JSON compilation from your mobile CRM dashboard..."

# Keep the foreground script loop alive and clear terminal print logs
while true; do
    sleep 3
    if ! kill -0 $PYTHON_PID 2>/dev/null; then break; fi
done

kill $SSH_PID 2>/dev/null || true
