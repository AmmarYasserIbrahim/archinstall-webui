#!/bin/bash
clear

LOG_FILE="/tmp/archinstall-web.log"
echo "--- NEW INSTALLATION SESSION: $(date) ---" > "$LOG_FILE"

pacman -Sy --noconfirm qrencode archinstall >> "$LOG_FILE" 2>&1

mkdir -p /tmp/engine && cd /tmp/engine

pkill -9 -f "server.py" >> "$LOG_FILE" 2>&1
pkill -9 -f "localhost.run" >> "$LOG_FILE" 2>&1
if command -v fuser &> /dev/null; then
    fuser -k 5000/tcp >> "$LOG_FILE" 2>&1
fi
sleep 2

cat << 'EOF' > server.py
import http.server
import socketserver
import json
import subprocess
import os
import threading
import time
import logging
from urllib.parse import urlparse

LOG_FILE = '/tmp/archinstall-web.log'
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.DEBUG,
    format='%(asctime)s [PYTHON] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

PORT = 5000
CONFIG_PATH = '/tmp/config.json'
CREDS_PATH = '/tmp/creds.json'

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
    os.system('pacman -Sy --noconfirm >> /tmp/archinstall-web.log 2>&1')
    install_state = {"percentage": 10, "message": "Initializing official Archinstall engine...", "status": "running"}
    
    cmd = ["archinstall", "--config", CONFIG_PATH, "--creds", CREDS_PATH, "--silent"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    
    with open(LOG_FILE, 'a') as master_log:
        for line in process.stdout:
            master_log.write(f"[ARCHINSTALL] {line}")
            master_log.flush()
            lower_line = line.lower()
            if "formatting" in lower_line or "creating file system" in lower_line:
                install_state = {"percentage": 15, "message": "Formatting storage block devices...", "status": "running"}
            elif "waiting for time sync" in lower_line:
                install_state = {"percentage": 20, "message": "Synchronizing system hardware clocks...", "status": "running"}
            elif "pacstrap" in lower_line or "installing packages" in lower_line:
                install_state = {"percentage": 45, "message": "Extracting base system packages...", "status": "running"}
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
    def log_message(self, format, *args):
        logging.info(f"HTTP Req: {format%args}")

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
                    if install_state["status"] in ["completed", "error"]: break
                    time.sleep(1)
            except: pass
        else:
            return http.server.SimpleHTTPRequestHandler.do_GET(self)

    def do_POST(self):
        parsed_path = urlparse(self.path).path
        if parsed_path == '/api/submit':
            content_length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(content_length))
            with open(CONFIG_PATH, 'w') as f: json.dump(post_data.get('config', {}), f, indent=4)
            with open(CREDS_PATH, 'w') as f: json.dump(post_data.get('creds', {}), f, indent=4)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            threading.Thread(target=run_archinstall).start()
        elif parsed_path == '/api/reboot':
            self.send_response(200)
            self.end_headers()
            os.system('umount -R /mnt && reboot')

class ReuseServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True

with ReuseServer(("", PORT), APIHandler) as httpd:
    httpd.serve_forever()
EOF

cat << 'EOF' > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Arch Linux Installer</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', sans-serif; }
        .custom-scrollbar::-webkit-scrollbar { width: 6px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: transparent; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: #e5e7eb; border-radius: 10px; }
        .custom-scrollbar::-webkit-scrollbar-thumb:hover { background: #d1d5db; }
    </style>
</head>
<body class="bg-gray-100 min-h-screen flex items-center justify-center p-4 text-gray-800">
    <div class="bg-white rounded-2xl shadow-2xl w-full max-w-4xl min-h-[550px] flex overflow-hidden border border-gray-200">
        <div class="w-2/5 bg-gray-50 flex flex-col items-center justify-center p-8 border-r border-gray-200 hidden md:flex relative">
            <div class="text-center absolute top-8 left-8">
                <span class="font-bold tracking-widest uppercase text-xs text-gray-400">Arch WebUI</span>
            </div>
            <svg width="200" height="200" viewBox="0 0 200 200" fill="none" xmlns="http://www.w3.org/2000/svg" class="mb-6 opacity-90">
                <path d="M100 40L160 70V130L100 160L40 130V70L100 40Z" fill="#ffffff" stroke="#e5e7eb" stroke-width="4" stroke-linejoin="round"/>
                <path d="M100 40L160 70L100 100L40 70L100 40Z" fill="#f9fafb" stroke="#d1d5db" stroke-width="2" stroke-linejoin="round"/>
                <path d="M100 100V160" stroke="#d1d5db" stroke-width="2" stroke-linejoin="round"/>
                <path d="M100 100L160 70" stroke="#d1d5db" stroke-width="2" stroke-linejoin="round"/>
                <path d="M40 70L100 100" stroke="#d1d5db" stroke-width="2" stroke-linejoin="round"/>
                <rect x="75" y="65" width="20" height="15" fill="#f97316" transform="skewY(26)" opacity="0.8"/>
                <rect x="105" y="80" width="20" height="15" fill="#e5e7eb" transform="skewY(26)"/>
                <rect x="65" y="110" width="30" height="10" fill="#f97316" transform="skewY(-26)" opacity="0.8"/>
            </svg>
            <div class="text-center">
                <h3 class="font-bold text-gray-700 text-lg">System Configuration</h3>
                <p id="target-cpu" class="text-xs text-gray-400 mt-2 font-medium">Connecting...</p>
            </div>
        </div>

        <div class="w-full md:w-3/5 flex flex-col bg-white">
            <div class="px-10 pt-10 pb-4 flex justify-between items-center border-b border-gray-100">
                <h2 id="step-title" class="text-xl font-bold text-gray-800">Select target drive</h2>
                <span class="bg-white border border-gray-200 text-gray-500 px-3 py-1 rounded-md text-xs font-semibold shadow-sm" id="step-indicator">Step 1 of 4</span>
            </div>

            <div class="p-10 flex-grow overflow-y-auto custom-scrollbar">
                <form id="wizard-form" class="space-y-6">
                    <div id="step-1" class="wizard-step block">
                        <div class="border border-gray-300 rounded-lg overflow-hidden mb-6 h-48 custom-scrollbar overflow-y-auto" id="disk-list"></div>
                        <div class="flex items-center justify-between gap-4 mb-4">
                            <div class="w-1/2">
                                <label class="block text-xs font-semibold text-gray-500 mb-2">Filesystem:</label>
                                <select id="fs" class="w-full border border-gray-300 rounded-md py-2.5 px-3 text-sm text-gray-700 focus:outline-none focus:border-orange-500">
                                    <option value="ext4">Ext4 (Standard)</option>
                                    <option value="btrfs">Btrfs (Modern)</option>
                                </select>
                            </div>
                            <div class="w-1/2">
                                <label class="block text-xs font-semibold text-gray-500 mb-2">Bootloader:</label>
                                <select id="bootloader" class="w-full border border-gray-300 rounded-md py-2.5 px-3 text-sm text-gray-700 focus:outline-none focus:border-orange-500">
                                    <option value="Systemd-boot">Systemd-boot</option>
                                    <option value="grub-install">GRUB 2</option>
                                </select>
                            </div>
                        </div>
                        <div class="flex items-center gap-3 py-3 px-4 bg-gray-50 border border-gray-200 rounded-md">
                            <input type="checkbox" id="swap" checked class="w-4 h-4 text-orange-500 border-gray-300 rounded focus:ring-orange-500 accent-orange-500 cursor-pointer">
                            <label for="swap" class="text-sm font-medium text-gray-700 cursor-pointer">Allocate zRAM Swap Module</label>
                        </div>
                    </div>

                    <div id="step-2" class="wizard-step hidden">
                        <label class="block text-xs font-semibold text-gray-500 mb-2">Desktop environment</label>
                        <div class="border border-gray-300 rounded-lg overflow-hidden mb-6 h-48 custom-scrollbar overflow-y-auto">
                            <div class="desktop-item p-3.5 text-sm text-orange-600 font-medium bg-orange-50/50 border-l-2 border-orange-500 cursor-pointer transition-colors" data-val="Awesome" onclick="selectDesktop('Awesome', this)">Awesome WM</div>
                            <div class="desktop-item p-3.5 text-sm text-gray-600 hover:bg-gray-50 border-l-2 border-transparent cursor-pointer transition-colors" data-val="KDE Plasma" onclick="selectDesktop('KDE Plasma', this)">KDE Plasma</div>
                            <div class="desktop-item p-3.5 text-sm text-gray-600 hover:bg-gray-50 border-l-2 border-transparent cursor-pointer transition-colors" data-val="GNOME" onclick="selectDesktop('GNOME', this)">GNOME</div>
                            <div class="desktop-item p-3.5 text-sm text-gray-600 hover:bg-gray-50 border-l-2 border-transparent cursor-pointer transition-colors" data-val="none" onclick="selectDesktop('none', this)">Minimal Server (No GUI)</div>
                        </div>
                        <div class="flex items-center justify-between gap-4">
                            <div class="w-1/2">
                                <label class="block text-xs font-semibold text-gray-500 mb-2">Kernel Payload:</label>
                                <select id="kernel" class="w-full border border-gray-300 rounded-md py-2.5 px-3 text-sm text-gray-700 focus:outline-none focus:border-orange-500">
                                    <option value="linux">Standard (linux)</option>
                                    <option value="linux-lts">LTS (linux-lts)</option>
                                </select>
                            </div>
                            <div class="w-1/2">
                                <label class="block text-xs font-semibold text-gray-500 mb-2">Audio Server:</label>
                                <select id="audio" class="w-full border border-gray-300 rounded-md py-2.5 px-3 text-sm text-gray-700 focus:outline-none focus:border-orange-500">
                                    <option value="pipewire">Pipewire</option>
                                    <option value="pulseaudio">PulseAudio</option>
                                </select>
                            </div>
                        </div>
                    </div>

                    <div id="step-3" class="wizard-step hidden space-y-5">
                        <div class="grid grid-cols-2 gap-4">
                            <div>
                                <label class="block text-xs font-semibold text-gray-500 mb-2">Hostname</label>
                                <input type="text" id="hostname" value="arch-system" class="w-full bg-white border border-gray-300 rounded-md py-2.5 px-4 text-sm focus:outline-none focus:border-orange-500">
                            </div>
                            <div>
                                <label class="block text-xs font-semibold text-gray-500 mb-2">Timezone</label>
                                <input type="text" id="timezone" value="UTC" class="w-full bg-white border border-gray-300 rounded-md py-2.5 px-4 text-sm focus:outline-none focus:border-orange-500">
                            </div>
                        </div>
                        <div class="bg-gray-50 border border-gray-200 rounded-lg p-5 mt-4">
                            <h4 class="text-xs font-bold text-gray-500 uppercase tracking-wider mb-4 border-b border-gray-200 pb-2">User Accounts</h4>
                            <div class="grid grid-cols-2 gap-4 mb-4">
                                <div><input type="text" id="username" placeholder="Username" class="w-full border border-gray-300 rounded-md py-2.5 px-4 text-sm focus:outline-none focus:border-orange-500"></div>
                                <div><input type="password" id="password" placeholder="Password" class="w-full border border-gray-300 rounded-md py-2.5 px-4 text-sm focus:outline-none focus:border-orange-500"></div>
                            </div>
                            <div><input type="password" id="root-password" placeholder="Root Password" class="w-full border border-gray-300 rounded-md py-2.5 px-4 text-sm focus:outline-none focus:border-red-400"></div>
                        </div>
                    </div>

                    <div id="step-4" class="wizard-step hidden flex flex-col items-center justify-center h-full pt-8">
                        <div class="text-center w-full">
                            <h2 class="text-xl font-bold text-gray-800 mb-2">Installing Arch Linux</h2>
                            <p id="progress-msg" class="text-sm font-medium text-gray-500 mb-8">Compiling definitions...</p>
                            <div class="flex justify-between items-end mb-2 px-2">
                                <span class="text-xs font-bold text-gray-400 uppercase">Progress</span>
                                <span id="progress-pct" class="text-2xl font-bold text-orange-500">0%</span>
                            </div>
                            <div class="w-full bg-gray-200 rounded-full h-2 overflow-hidden mb-8">
                                <div id="progress-bar-fill" class="bg-orange-500 h-full rounded-full w-0 transition-all duration-500 ease-out"></div>
                            </div>
                            <button type="button" id="btn-reboot" class="hidden w-full bg-gray-900 hover:bg-black text-white font-medium py-3 rounded-lg text-sm transition-colors">Restart Now</button>
                        </div>
                    </div>
                </form>
            </div>

            <div id="nav-footer" class="px-10 py-5 bg-gray-50 border-t border-gray-200 flex justify-between items-center rounded-br-2xl">
                <button type="button" id="btn-back" class="text-gray-500 hover:text-gray-800 font-medium text-sm hidden">Back</button>
                <button type="button" id="btn-next" class="ml-auto bg-white border border-gray-300 hover:border-gray-400 text-gray-800 font-medium py-2 px-6 rounded-md text-sm">Continue</button>
            </div>
        </div>
    </div>

    <script>
        let currentStep = 1; const totalSteps = 4;
        let selectedDiskVal = ""; let selectedDesktopVal = "Awesome";
        const stepTitles = ["Select target drive", "Select environment", "Set credentials", "Installing system"];
        
        fetch('/api/status').then(r => r.json()).then(data => {
            document.getElementById('target-cpu').innerText = `${data.cpu} | ${data.boot_mode}`;
            const diskList = document.getElementById('disk-list');
            let isFirst = true;
            data.hardware.blockdevices.forEach(dev => {
                if(dev.type === 'disk') {
                    const extraClasses = isFirst ? 'text-orange-600 bg-orange-50/50 border-orange-500' : 'text-gray-600 border-transparent hover:bg-gray-50';
                    if(isFirst) selectedDiskVal = `/dev/${dev.name}`;
                    diskList.innerHTML += `<div class="disk-item p-3.5 text-sm font-medium border-l-2 cursor-pointer transition-colors ${extraClasses}" onclick="selectDisk('/dev/${dev.name}', this)">/dev/${dev.name} <span class="text-xs text-gray-400 ml-2 font-normal">${dev.size}</span></div>`;
                    isFirst = false;
                }
            });
        });

        function selectDisk(val, el) {
            selectedDiskVal = val;
            document.querySelectorAll('.disk-item').forEach(i => i.className = "disk-item p-3.5 text-sm font-medium border-l-2 cursor-pointer transition-colors text-gray-600 border-transparent hover:bg-gray-50");
            el.className = "disk-item p-3.5 text-sm font-medium border-l-2 cursor-pointer transition-colors text-orange-600 bg-orange-50/50 border-orange-500";
        }

        function selectDesktop(val, el) {
            selectedDesktopVal = val;
            document.querySelectorAll('.desktop-item').forEach(i => i.className = "desktop-item p-3.5 text-sm font-medium border-l-2 cursor-pointer transition-colors text-gray-600 border-transparent hover:bg-gray-50");
            el.className = "desktop-item p-3.5 text-sm font-medium border-l-2 cursor-pointer transition-colors text-orange-600 bg-orange-50/50 border-orange-500";
        }

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
            document.getElementById('step-title').innerText = stepTitles[currentStep - 1];
            document.getElementById('btn-back').style.display = (currentStep > 1 && currentStep < 4) ? 'block' : 'none';
            if (currentStep === 3) {
                document.getElementById('btn-next').innerText = "Install Now";
                document.getElementById('btn-next').className = "ml-auto bg-orange-500 hover:bg-orange-600 text-white font-medium py-2 px-6 rounded-md text-sm border border-transparent";
            } else if (currentStep === 4) {
                document.getElementById('nav-footer').style.display = 'none';
            } else {
                document.getElementById('btn-next').innerText = "Continue";
                document.getElementById('btn-next').className = "ml-auto bg-white border border-gray-300 hover:border-gray-400 text-gray-800 font-medium py-2 px-6 rounded-md text-sm";
            }
        }

        async function submitArchinstallConfig() {
            const configPayload = {
                "archinstall-language": "English",
                "audio_config": { "audio": document.getElementById('audio').value },
                "bootloader_config": {
                    "bootloader": document.getElementById('bootloader').value,
                    "uki": false,
                    "removable": false
                },
                "debug": false,
                "disk_config": {
                    "config_type": "default_layout",
                    "device_modifications": [{
                        "device": selectedDiskVal,
                        "partitions": [
                            {
                                "btrfs": [],
                                "dev_path": selectedDiskVal + "1",
                                "flags": ["boot"],
                                "fs_type": "fat32",
                                "mount_options": [],
                                "mountpoint": "/boot",
                                "size": {"sector_size": {"value": 512, "unit": "B"}, "unit": "MiB", "value": 512},
                                "start": {"sector_size": {"value": 512, "unit": "B"}, "unit": "MiB", "value": 1},
                                "status": "create",
                                "type": "primary"
                            },
                            {
                                "btrfs": [],
                                "dev_path": selectedDiskVal + "2",
                                "flags": [],
                                "fs_type": document.getElementById('fs').value,
                                "mount_options": [],
                                "mountpoint": "/",
                                "size": {"sector_size": {"value": 512, "unit": "B"}, "unit": "Percent", "value": 100},
                                "start": {"sector_size": {"value": 512, "unit": "B"}, "unit": "MiB", "value": 513},
                                "status": "create",
                                "type": "primary"
                            }
                        ],
                        "wipe": true
                    }]
                },
                "hostname": document.getElementById('hostname').value,
                "kernels": [document.getElementById('kernel').value],
                "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
                "mirror_config": { "mirror_regions": { "Worldwide": ["https://geo.mirror.pkgbuild.com/$repo/os/$arch"] } },
                "network_config": { "type": "NetworkManager" },
                "no_pkg_lookups": false,
                "ntp": true,
                "offline": false,
                "packages": [],
                "pacman_config": { "color": false, "parallel_downloads": 5 },
                "script": "guided",
                "silent": false,
                "swap": document.getElementById('swap').checked ? { "enabled": true, "algorithm": "zstd" } : { "enabled": false },
                "timezone": document.getElementById('timezone').value,
                "version": "2.8.6"
            };

            if (selectedDesktopVal !== "none") {
                let mainType = "Desktop";
                if (selectedDesktopVal === "Awesome") mainType = "WindowMgr";
                configPayload["profile_config"] = {
                    "profile": {
                        "details": [selectedDesktopVal],
                        "main": mainType
                    }
                };
            }

            const credsPayload = {
                "root-password": document.getElementById('root-password').value,
                "users": [{ "username": document.getElementById('username').value, "password": document.getElementById('password').value, "sudo": true }]
            };

            await fetch('/api/submit', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ config: configPayload, creds: credsPayload }) });
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
                    document.getElementById('progress-msg').classList.replace('text-gray-500', 'text-red-500');
                    document.getElementById('progress-bar-fill').classList.replace('bg-orange-500', 'bg-red-500');
                    document.getElementById('progress-pct').classList.replace('text-orange-500', 'text-red-500');
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
            document.getElementById('btn-reboot').innerText = "Rebooting System...";
        });
    </script>
</body>
</html>
EOF

python3 server.py &
PYTHON_PID=$!

if ! kill -0 $PYTHON_PID 2>/dev/null; then
    exit 1
fi

ssh -o StrictHostKeyChecking=no -o ServerAliveInterval=10 -o ConnectTimeout=5 -R 80:localhost:5000 nokey@localhost.run >> "$LOG_FILE" 2>&1 &
SSH_PID=$!

PUBLIC_URL=""
for i in {1..20}; do
    PUBLIC_URL=$(grep -oE "https://[a-zA-Z0-9.-]+\.lhr\.life" "$LOG_FILE" | tail -n 1)
    if [ ! -z "$PUBLIC_URL" ]; then break; fi
    sleep 1
done

LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')
if [ -z "$LOCAL_IP" ]; then LOCAL_IP=$(hostname -I | awk '{print $1}'); fi

if [ -z "$PUBLIC_URL" ]; then
    DISPLAY_URL="http://${LOCAL_IP}:5000"
    CONNECTION_MODE="LAN"
else
    DISPLAY_URL="${PUBLIC_URL}"
    CONNECTION_MODE="PUBLIC TUNNEL"
fi

clear
qrencode -t utf8i "${DISPLAY_URL}"
echo ""
echo " URL:  ${DISPLAY_URL}"
echo " Mode: ${CONNECTION_MODE}"
echo ""

while kill -0 $PYTHON_PID 2>/dev/null; do
    sleep 3
done

kill $SSH_PID 2>/dev/null || true