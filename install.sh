#!/bin/bash
clear

LOG_FILE="/tmp/archinstall-webui.log"
echo "--- NEW INSTALLATION SESSION: $(date) ---" > "$LOG_FILE"

cleanup() {
    pkill -9 -f "server.py" >> "$LOG_FILE" 2>&1
    pkill -9 -f "localhost.run" >> "$LOG_FILE" 2>&1
    if [ ! -z "$PYTHON_PID" ]; then kill -9 "$PYTHON_PID" >/dev/null 2>&1; fi
    if [ ! -z "$SSH_PID" ]; then kill -9 "$SSH_PID" >/dev/null 2>&1; fi
}
trap cleanup EXIT INT TERM

mkdir -p /var/cache/pacman/pkg
pacman -Sy --noconfirm qrencode archinstall >> "$LOG_FILE" 2>&1

mkdir -p /run/archinstall-ui && chmod 700 /run/archinstall-ui && cd /run/archinstall-ui

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

LOG_FILE = '/tmp/archinstall-webui.log'
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.DEBUG,
    format='%(asctime)s [PYTHON] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

PORT = 5000
CONFIG_PATH = '/run/archinstall-ui/config.json'
CREDS_PATH = '/run/archinstall-ui/creds.json'

install_state = {"percentage": 0, "message": "Awaiting mobile configuration matrix...", "status": "idle"}

def get_system_telemetry():
    telemetry = {"cpu": "Unknown", "boot_mode": "BIOS", "hardware": {}}
    try:
        cpu_out = subprocess.check_output('lscpu | grep "Model name:" | sed "s/Model name: *//"', shell=True)
        telemetry['cpu'] = cpu_out.decode('utf-8').strip()
    except: pass
    telemetry['boot_mode'] = "UEFI" if os.path.exists('/sys/firmware/efi/efivars') else "BIOS"
    try:
        lsblk_out = subprocess.check_output('lsblk -b -Jno NAME,SIZE,TYPE', shell=True)
        telemetry['hardware'] = json.loads(lsblk_out.decode('utf-8'))
    except: pass
    return telemetry

def run_archinstall():
    global install_state
    install_state = {"percentage": 5, "message": "Synchronizing pacman mirror repositories...", "status": "running"}
    os.system('pacman -Sy --noconfirm >> /tmp/archinstall-webui.log 2>&1')
    install_state = {"percentage": 10, "message": "Initializing official Archinstall engine...", "status": "running"}
    
    cmd = ["archinstall", "--config", CONFIG_PATH, "--creds", CREDS_PATH, "--silent"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    
    with open(LOG_FILE, 'a') as master_log:
        for line in process.stdout:
            master_log.write(f"[ARCHINSTALL] {line}")
            master_log.flush()
            lower_line = line.lower()
            current_pct = install_state["percentage"]
            
            if "formatting" in lower_line or "creating file system" in lower_line:
                if current_pct < 15: install_state = {"percentage": 15, "message": "Formatting storage block devices...", "status": "running"}
            elif "waiting for time sync" in lower_line:
                if current_pct < 20: install_state = {"percentage": 20, "message": "Synchronizing system hardware clocks...", "status": "running"}
            elif "pacstrap" in lower_line or "installing packages" in lower_line:
                if current_pct < 45: install_state = {"percentage": 45, "message": "Extracting base system packages...", "status": "running"}
            elif "bootloader" in lower_line or "systemd-boot" in lower_line or "grub" in lower_line:
                if current_pct < 75: install_state = {"percentage": 75, "message": "Injecting bootloader configurations...", "status": "running"}
            elif "profile" in lower_line or "desktop" in lower_line:
                if current_pct < 85: install_state = {"percentage": 85, "message": "Compiling targeted desktop environments...", "status": "running"}
            elif "services" in lower_line or "networkmanager" in lower_line:
                if current_pct < 92: install_state = {"percentage": 92, "message": "Enabling core systemd runtime services...", "status": "running"}
            elif "installation completed" in lower_line:
                install_state = {"percentage": 100, "message": "Build Successful! System ready for reboot.", "status": "completed"}
                
    process.wait()
    if process.returncode == 0:
        install_state = {"percentage": 100, "message": "Build Successful! System ready for reboot.", "status": "completed"}
    else:
        install_state = {"percentage": 99, "message": f"Archinstall halted with exit code {process.returncode}. Check logs.", "status": "error"}

class APIHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

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
            data = get_system_telemetry()
            data['install_state'] = install_state
            self.wfile.write(json.dumps(data).encode('utf-8'))
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
            if content_length > 10 * 1024 * 1024:
                self.send_response(413)
                self.end_headers()
                return
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
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            threading.Thread(target=lambda: (time.sleep(1.5), os.system('systemctl reboot'))).start()

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
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<<<<<<< HEAD
    <title>Arch Installer</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', sans-serif; background-color: #2C001E; }
        .custom-scrollbar::-webkit-scrollbar { width: 4px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: transparent; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: #334155; border-radius: 10px; }
    </style>
</head>
<body class="min-h-screen flex items-center justify-center p-0 sm:p-4 md:p-6 text-slate-200 selection:bg-orange-600/40">
    <div class="bg-[#111111] w-full max-w-4xl min-h-screen sm:min-h-[640px] flex flex-col justify-between overflow-hidden shadow-2xl sm:rounded-xl border border-[#222222]">
        
        <div class="px-6 py-4 bg-[#181818] border-b border-[#222222] flex items-center justify-between shrink-0">
            <div class="flex items-center gap-3">
                <span class="text-xs font-mono tracking-tight text-slate-400" id="target-cpu">Resolving hardware context...</span>
            </div>
            <div class="flex items-center gap-1.5" id="nav-dots">
                <span class="w-2 h-2 rounded-full bg-orange-500 shadow-lg shadow-orange-500/50"></span>
                <span class="w-2 h-2 rounded-full bg-[#333333]"></span>
                <span class="w-2 h-2 rounded-full bg-[#333333]"></span>
                <span class="w-2 h-2 rounded-full bg-[#333333]"></span>
            </div>
        </div>

        <div class="p-6 md:p-10 flex-grow overflow-y-auto custom-scrollbar">
            <div id="validation-alert" class="hidden mb-4 p-3 bg-red-950/50 border border-red-900/60 text-red-400 text-xs rounded-lg font-medium"></div>
            <form id="wizard-form" onsubmit="event.preventDefault();" class="space-y-6">
                
                <div id="step-1" class="wizard-step block space-y-4">
                    <h3 class="text-xl font-light text-slate-100 tracking-tight" id="step-title-1">Select target block storage</h3>
                    <div class="border border-[#222222] bg-[#090909] rounded-xl overflow-hidden h-48 custom-scrollbar overflow-y-auto" id="disk-list"></div>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-4 pt-2">
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-2 tracking-wider">Bootloader Payload Hook</label>
                            <select id="bootloader" class="w-full bg-[#181818] border border-[#262626] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500 cursor-pointer">
                                <option value="Grub">GRUB 2 Universal Bootloader</option>
                                <option value="Systemd-boot">Systemd-boot (EFI Native)</option>
                            </select>
                        </div>
                    </div>
                    <div class="flex items-center gap-3 p-4 bg-[#141414] border border-[#222222] rounded-xl mt-4 cursor-pointer" onclick="document.getElementById('swap').click()">
                        <input type="checkbox" id="swap" checked class="w-4 h-4 text-orange-500 border-[#262626] bg-[#090909] rounded focus:ring-orange-500 accent-orange-500" onclick="event.stopPropagation()">
                        <label for="swap" class="text-sm font-medium text-slate-300 cursor-pointer">Enable automated zRAM architecture</label>
                    </div>
                </div>

                <div id="step-2" class="wizard-step hidden space-y-4">
                    <h3 class="text-xl font-light text-slate-100 tracking-tight">Manual partitioning map configuration</h3>
                    <div class="bg-[#090909] border border-[#222222] rounded-xl p-3 md:p-4">
                        <div class="flex font-bold text-[10px] md:text-xs text-slate-400 mb-3 border-b border-[#222222] pb-2 uppercase tracking-wider">
                            <div class="w-[30%]">Mount Point</div>
                            <div class="w-[25%]">Filesystem</div>
                            <div class="w-[35%]">Sizing Alloc</div>
                            <div class="w-[10%] text-center">Drop</div>
                        </div>
                        <div id="partition-list" class="space-y-2 mb-4"></div>
                        <button type="button" onclick="addPartition()" class="text-xs bg-[#181818] border border-[#262626] px-4 py-2.5 rounded-lg font-semibold text-slate-300 hover:bg-[#222222] transition-colors shadow-sm">+ Add Volume Allocation</button>
                    </div>
                </div>

                <div id="step-3" class="wizard-step hidden space-y-4">
                    <h3 class="text-xl font-light text-slate-100 tracking-tight">Select desktop core target profile</h3>
                    <div class="border border-[#222222] bg-[#090909] rounded-xl overflow-hidden p-2.5 custom-scrollbar overflow-y-auto max-h-44 grid grid-cols-2 md:grid-cols-3 gap-2" id="desktop-grid"></div>
                    
                    <h4 class="text-[11px] font-bold text-slate-400 uppercase tracking-wider mt-4">Ecosystem Packages & Services</h4>
                    <div class="grid grid-cols-2 gap-2 md:gap-3">
                        <label class="flex items-center gap-2 p-3 bg-[#141414] border border-[#222222] rounded-lg text-xs text-slate-300 cursor-pointer hover:border-[#262626]"><input type="checkbox" id="bluetooth" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-[#090909] border-[#222222] accent-orange-500"> Bluetooth Setup</label>
                        <label class="flex items-center gap-2 p-3 bg-[#141414] border border-[#222222] rounded-lg text-xs text-slate-300 cursor-pointer hover:border-[#262626]"><input type="checkbox" id="firewall" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-[#090909] border-[#222222] accent-orange-500"> UFW Daemon</label>
                        <label class="flex items-center gap-2 p-3 bg-[#141414] border border-[#222222] rounded-lg text-xs text-slate-300 cursor-pointer hover:border-[#262626]"><input type="checkbox" id="printing" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-[#090909] border-[#222222] accent-orange-500"> CUPS Server</label>
                        <label class="flex items-center gap-2 p-2.5 bg-[#141414] border border-[#222222] rounded-lg text-xs text-slate-300 cursor-pointer hover:border-[#262626]"><input type="checkbox" id="fonts" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-[#090909] border-[#222222] accent-orange-500"> Noto Fonts</label>
                    </div>

                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1.5">Ecosystem Kernel</label>
                            <select id="kernel" class="w-full bg-[#181818] border border-[#262626] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500">
                                <option value="linux">Standard Mainline Stable</option>
                                <option value="linux-lts">LTS (Long Term Support)</option>
                                <option value="linux-zen">Zen Performance Core</option>
                            </select>
                        </div>
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1.5">Audio Payload Server</label>
                            <select id="audio" class="w-full bg-[#181818] border border-[#262626] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500">
                                <option value="pipewire">Pipewire Processing Unit</option>
                                <option value="pulseaudio">Legacy PulseAudio Server</option>
                            </select>
                        </div>
                    </div>
                </div>

                <div id="step-4" class="wizard-step hidden space-y-4">
                    <h3 class="text-xl font-light text-slate-100 tracking-tight">Accounts & identity context mapping</h3>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1.5">Hostname Mapping</label>
                            <input type="text" id="hostname" value="archlinux" class="w-full bg-[#181818] border border-[#262626] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500">
                        </div>
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1.5">Timezone Node</label>
                            <input type="text" id="timezone" value="UTC" class="w-full bg-[#181818] border border-[#262626] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500">
                        </div>
                    </div>
                    <div class="bg-[#090909] border border-[#222222] rounded-xl p-4 space-y-3">
                        <h4 class="text-xs font-bold text-slate-400 uppercase tracking-wider border-b border-[#222222] pb-2">Target Profile Matrix</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><input type="text" id="username" placeholder="Username mapping" class="w-full bg-[#141414] border border-[#222222] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500"></div>
                            <div><input type="password" id="password" placeholder="Account password" class="w-full bg-[#141414] border border-[#222222] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500"></div>
                        </div>
                        <div><input type="password" id="root-password" placeholder="Superuser administration root password" class="w-full bg-[#141414] border border-[#222222] rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-red-500"></div>
                    </div>
                </div>

                <div id="step-5" class="wizard-step hidden flex flex-col items-center justify-center h-full pt-8 pb-8">
                    <div class="text-center w-full max-w-lg">
                        <h2 class="text-xl font-light text-slate-100 tracking-tight mb-2">Executing native system generation loop</h2>
                        <p id="progress-msg" class="text-xs font-semibold text-orange-500 font-mono tracking-tight mb-8">Compiling layout structural vectors...</p>
                        <div class="flex justify-between items-end mb-2 px-1">
                            <span class="text-[10px] font-bold text-slate-400 uppercase tracking-wider">Deployment Gauge</span>
                            <span id="progress-pct" class="text-3xl font-bold text-slate-100">0%</span>
                        </div>
                        <div class="w-full bg-[#090909] rounded-full h-3 overflow-hidden p-0.5 border border-[#222222] mb-8">
                            <div id="progress-bar-fill" class="bg-gradient-to-r from-orange-500 to-amber-500 h-full rounded-full w-0 transition-all duration-500 ease-out"></div>
                        </div>
                        <button type="button" id="btn-reboot" class="hidden w-full bg-gradient-to-r from-emerald-600 to-teal-600 text-white font-bold py-4 rounded-xl text-sm transition-all tracking-wider shadow-lg shadow-emerald-950/30">Close Volumes & Reboot Machine</button>
                    </div>
                </div>
            </form>
        </div>

        <div id="nav-footer" class="px-6 py-4 bg-[#181818] border-t border-[#222222] flex justify-between items-center shrink-0">
            <button type="button" id="btn-back" class="text-slate-400 hover:text-white font-bold text-sm hidden py-2.5 px-5 border border-[#262626] rounded-lg bg-[#141414] hover:bg-[#222222] transition-colors">Previous</button>
            <button type="button" id="btn-next" class="ml-auto bg-orange-600 hover:bg-orange-500 text-white font-bold py-2.5 px-6 rounded-lg text-sm shadow-md shadow-orange-950/20 transition-all active:scale-95">Next</button>
=======
    <title>Ubuntu Desktop Installer style for Arch</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <script>
        tailwind.config = {
            theme: {
                extend: {
                    colors: {
                        ubuntuOrange: '#E95420',
                        ubuntuAubergine: '#77216F',
                        ubuntuDarkAubergine: '#5E2750',
                        ubuntuWarmGrey: '#AEA79F',
                        ubuntuLightGrey: '#F7F7F7',
                    }
                }
            }
        }
    </script>
    <style>
        body { font-family: 'Inter', sans-serif; background-color: #2C001E; }
        .custom-scrollbar::-webkit-scrollbar { width: 6px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: transparent; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: #AEA79F; border-radius: 10px; }
    </style>
</head>
<body class="min-h-screen flex items-center justify-center p-0 md:p-6 text-gray-800">
    <div class="bg-white md:rounded-lg shadow-2xl w-full max-w-5xl min-h-[100vh] md:min-h-[680px] flex flex-col overflow-hidden border border-gray-300">
        
        <div class="bg-ubuntuLightGrey px-6 md:px-10 py-4 flex justify-between items-center border-b border-gray-200 shrink-0 select-none">
            <div class="flex items-center gap-3">
                <div class="bg-ubuntuOrange text-white font-bold h-7 w-7 rounded flex items-center justify-center text-sm shadow-sm">A</div>
                <div>
                    <span class="font-bold tracking-tight text-sm text-gray-900 block">Arch Linux Core Installation Setup</span>
                    <span class="text-[11px] text-gray-500 font-mono block w-[220px] md:w-auto truncate" id="target-cpu">Connecting...</span>
                </div>
            </div>
            <span class="text-xs font-semibold text-gray-500 tracking-wide uppercase bg-gray-200/60 px-3 py-1 rounded" id="step-indicator">Step 1 of 4</span>
        </div>

        <div class="flex flex-col md:flex-row flex-grow overflow-hidden bg-white">
            
            <div class="w-full md:w-1/4 bg-ubuntuLightGrey border-r border-gray-200 p-6 hidden md:block shrink-0">
                <ul class="space-y-3 text-sm font-medium" id="left-nav-steps">
                    <li class="nav-item text-ubuntuOrange font-bold flex items-center gap-2" id="nav-idx-1"><span class="w-1.5 h-1.5 bg-ubuntuOrange rounded-full"></span> Target Storage Device</li>
                    <li class="nav-item text-gray-400 flex items-center gap-2" id="nav-idx-2"><span class="w-1.5 h-1.5 bg-transparent rounded-full"></span> Manual Partition Table</li>
                    <li class="nav-item text-gray-400 flex items-center gap-2" id="nav-idx-3"><span class="w-1.5 h-1.5 bg-transparent rounded-full"></span> Operating Ecosystem</li>
                    <li class="nav-item text-gray-400 flex items-center gap-2" id="nav-idx-4"><span class="w-1.5 h-1.5 bg-transparent rounded-full"></span> Credential Mapping</li>
                </ul>
            </div>

            <div class="w-full md:w-3/4 flex flex-col bg-white overflow-hidden p-6 md:p-10 flex-grow">
                <div class="flex-grow overflow-y-auto custom-scrollbar pr-1">
                    <form id="wizard-form" class="space-y-6">
                        
                        <div id="step-1" class="wizard-step block space-y-4">
                            <h3 class="text-lg font-light text-gray-900 border-b border-gray-100 pb-2">Select your storage block architecture</h3>
                            <div class="border border-gray-300 rounded overflow-hidden h-44 custom-scrollbar overflow-y-auto bg-white shadow-inner" id="disk-list"></div>
                            <div class="grid grid-cols-2 gap-4 pt-2">
                                <div>
                                    <label class="block text-xs font-semibold text-gray-600 mb-1">Bootloader Interface Target</label>
                                    <select id="bootloader" class="w-full border border-gray-300 rounded py-2 px-3 text-sm bg-white text-gray-800 outline-none focus:border-ubuntuOrange">
                                        <option value="Grub">GRUB 2 Module</option>
                                        <option value="Systemd-boot">Systemd-boot Native</option>
                                    </select>
                                </div>
                            </div>
                            <div class="flex items-center gap-3 py-3 px-4 bg-ubuntuLightGrey border border-gray-200 rounded mt-4">
                                <input type="checkbox" id="swap" checked class="w-4 h-4 text-ubuntuOrange focus:ring-ubuntuOrange rounded accent-ubuntuOrange cursor-pointer">
                                <label for="swap" class="text-sm font-medium text-gray-700 cursor-pointer">Configure Virtualized zRAM Memory Layer</label>
                            </div>
                        </div>

                        <div id="step-2" class="wizard-step hidden space-y-4">
                            <h3 class="text-lg font-light text-gray-900 border-b border-gray-100 pb-2">Define partition mount table schemas</h3>
                            <div class="bg-ubuntuLightGrey border border-gray-200 rounded-lg p-3 md:p-4 shadow-inner">
                                <div class="flex font-semibold text-[10px] md:text-xs text-gray-500 mb-2 border-b border-gray-200 pb-2 uppercase tracking-wider">
                                    <div class="w-[30%]">Mount Path</div>
                                    <div class="w-[25%]">Filesystem</div>
                                    <div class="w-[35%]">Block Sizing</div>
                                    <div class="w-[10%] text-center">Drop</div>
                                </div>
                                <div id="partition-list" class="space-y-2 mb-4"></div>
                                <button type="button" onclick="addPartition()" class="text-xs bg-white border border-gray-300 px-4 py-2 rounded font-medium text-gray-700 hover:bg-gray-100 shadow-sm transition-all">+ Add System Block Mount</button>
                            </div>
                        </div>

                        <div id="step-3" class="wizard-step hidden space-y-4">
                            <h3 class="text-lg font-light text-gray-900 border-b border-gray-100 pb-2">Select your targeted runtime desktop target</h3>
                            <div class="border border-gray-200 rounded-lg p-3 custom-scrollbar overflow-y-auto max-h-48 grid grid-cols-2 md:grid-cols-3 gap-2 bg-ubuntuLightGrey" id="desktop-grid"></div>
                            
                            <h4 class="text-xs font-bold text-gray-500 uppercase tracking-wider mt-4">Integrated App Services Core Packages</h4>
                            <div class="grid grid-cols-2 gap-3">
                                <label class="flex items-center gap-2 p-2.5 bg-white border border-gray-200 rounded text-xs font-medium cursor-pointer hover:border-ubuntuWarmGrey"><input type="checkbox" id="bluetooth" checked class="text-ubuntuOrange focus:ring-ubuntuOrange rounded w-4 h-4 accent-ubuntuOrange"> Enable Bluetooth</label>
                                <label class="flex items-center gap-2 p-2.5 bg-white border border-gray-200 rounded text-xs font-medium cursor-pointer hover:border-ubuntuWarmGrey"><input type="checkbox" id="firewall" checked class="text-ubuntuOrange focus:ring-ubuntuOrange rounded w-4 h-4 accent-ubuntuOrange"> Secure UFW Firewall</label>
                                <label class="flex items-center gap-2 p-2.5 bg-white border border-gray-200 rounded text-xs font-medium cursor-pointer hover:border-ubuntuWarmGrey"><input type="checkbox" id="printing" checked class="text-ubuntuOrange focus:ring-ubuntuOrange rounded w-4 h-4 accent-ubuntuOrange"> CUPS Print Stack</label>
                                <label class="flex items-center gap-2 p-2.5 bg-white border border-gray-200 rounded text-xs font-medium cursor-pointer hover:border-ubuntuWarmGrey"><input type="checkbox" id="fonts" checked class="text-ubuntuOrange focus:ring-ubuntuOrange rounded w-4 h-4 accent-ubuntuOrange"> Noto Typography</label>
                            </div>

                            <div class="grid grid-cols-2 gap-4 pt-2">
                                <div>
                                    <label class="block text-xs font-semibold text-gray-600 mb-1">Target Base Kernel Payload</label>
                                    <select id="kernel" class="w-full border border-gray-300 rounded py-2 px-3 text-sm bg-white text-gray-800 outline-none focus:border-ubuntuOrange">
                                        <option value="linux">Standard Mainline Kernel</option>
                                        <option value="linux-lts">Long Term Support (LTS)</option>
                                        <option value="linux-zen">Optimized Zen Engine</option>
                                    </select>
                                </div>
                                <div>
                                    <label class="block text-xs font-semibold text-gray-600 mb-1">Audio Routing Server</label>
                                    <select id="audio" class="w-full border border-gray-300 rounded py-2 px-3 text-sm bg-white text-gray-800 outline-none focus:border-ubuntuOrange">
                                        <option value="pipewire">Pipewire Driver (Default)</option>
                                        <option value="pulseaudio">Legacy PulseAudio Engine</option>
                                    </select>
                                </div>
                            </div>
                        </div>

                        <div id="step-4" class="wizard-step hidden space-y-4">
                            <h3 class="text-lg font-light text-gray-900 border-b border-gray-100 pb-2">Map local identity context details</h3>
                            <div class="grid grid-cols-2 gap-4">
                                <div>
                                    <label class="block text-xs font-semibold text-gray-600 mb-1">Machine Hostname</label>
                                    <input type="text" id="hostname" value="archlinux" class="w-full bg-white border border-gray-300 rounded py-2 px-3 text-sm focus:outline-none focus:border-ubuntuOrange shadow-sm">
                                </div>
                                <div>
                                    <label class="block text-xs font-semibold text-gray-600 mb-1">Timezone Location</label>
                                    <input type="text" id="timezone" value="UTC" class="w-full bg-white border border-gray-300 rounded py-2 px-3 text-sm focus:outline-none focus:border-ubuntuOrange shadow-sm">
                                </div>
                            </div>
                            <div class="bg-ubuntuLightGrey border border-gray-200 rounded-lg p-4 mt-4 space-y-3">
                                <h4 class="text-xs font-bold text-gray-500 uppercase tracking-wider border-b border-gray-200 pb-1.5">User Identity Matrix</h4>
                                <div class="grid grid-cols-2 gap-4">
                                    <div><input type="text" id="username" placeholder="Target Account Name" class="w-full border border-gray-300 rounded py-2.5 px-3 text-sm focus:outline-none focus:border-ubuntuOrange bg-white"></div>
                                    <div><input type="password" id="password" placeholder="Account Password" class="w-full border border-gray-300 rounded py-2.5 px-3 text-sm focus:outline-none focus:border-ubuntuOrange bg-white"></div>
                                </div>
                                <div><input type="password" id="root-password" placeholder="System Superuser Root Password" class="w-full border border-gray-300 rounded py-2.5 px-3 text-sm focus:outline-none focus:border-red-400 bg-white"></div>
                            </div>
                        </div>

                        <div id="step-5" class="wizard-step hidden flex flex-col items-center justify-center h-full pt-8 pb-8">
                            <div class="text-center w-full max-w-lg">
                                <h2 class="text-xl font-medium text-gray-900 mb-1" id="installation-header-title">Deploying components to storage block targets</h2>
                                <p id="progress-msg" class="text-xs font-medium text-ubuntuOrange font-mono tracking-tight mb-8">Compiling internal JSON array maps...</p>
                                <div class="flex justify-between items-end mb-2 px-1">
                                    <span class="text-[10px] font-bold text-gray-400 uppercase tracking-wider">Installation Progress Metric</span>
                                    <span id="progress-pct" class="text-3xl font-light text-ubuntuOrange tracking-tighter">0%</span>
                                </div>
                                <div class="w-full bg-gray-200 rounded-full h-2 overflow-hidden mb-8 shadow-inner">
                                    <div id="progress-bar-fill" class="bg-gradient-to-r from-ubuntuOrange to-ubuntuAubergine h-full rounded-full w-0 transition-all duration-500 ease-out"></div>
                                </div>
                                <button type="button" id="btn-reboot" class="hidden w-full bg-ubuntuOrange hover:bg-orange-600 text-white font-medium py-3 rounded text-sm transition-colors shadow-md uppercase tracking-wider text-xs">Close Volumes & Reboot Hardware</button>
                            </div>
                        </div>
                    </form>
                </div>

                <div id="nav-footer" class="pt-5 bg-white border-t border-gray-100 flex justify-between items-center shrink-0 mt-4 select-none">
                    <button type="button" id="btn-back" class="text-gray-500 hover:text-gray-900 font-medium text-sm hidden py-2 px-4 border border-gray-300 rounded shadow-sm hover:bg-gray-50 transition-colors">Back</button>
                    <button type="button" id="btn-next" class="ml-auto bg-ubuntuOrange hover:bg-orange-600 text-white font-medium py-2.5 px-6 rounded text-sm shadow-sm transition-colors border border-transparent">Continue</button>
                </div>
            </div>
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
        </div>
    </div>

    <script>
        let currentStep = 1; const totalSteps = 5;
        let selectedDiskVal = ""; let selectedDiskBytes = 0; let selectedDesktopVal = "none";
        const stepTitles = ["Select target drive", "Configure partitions", "Select environment", "Set credentials", "System Deployment"];
        
        let partitions = [
            { id: genUUID(), mountpoint: '/boot', fs: 'fat32', size: 512, unit: 'MiB' },
            { id: genUUID(), mountpoint: '/', fs: 'btrfs', size: 100, unit: 'Percent' }
        ];

        const desktops = ["Awesome","Bspwm","Budgie","Cinnamon","Cosmic","Cutefish","Deepin","Enlightenment","GNOME","Hyprland","i3-wm","KDE Plasma","Labwc","Lxqt","Mate","Niri","Qtile","River","Sway","Xfce4","Xmonad","none"];

        function genUUID() {
            return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
                var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
<<<<<<< HEAD
                return v.toString(36);
=======
                return v.toString(16);
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
            });
        }

        window.onload = async () => {
            const dGrid = document.getElementById('desktop-grid');
            desktops.forEach(d => {
<<<<<<< HEAD
                let text = d === 'none' ? 'Minimal Shell Only' : d;
                let c = d === 'none' ? 'border-orange-500 text-orange-500 bg-orange-950/20 font-semibold' : 'border-[#222222] text-slate-300 hover:border-[#262626] bg-[#090909]';
                dGrid.innerHTML += `<div class="desktop-item p-3 text-xs border rounded-xl cursor-pointer transition-all flex items-center gap-2 ${c}" data-val="${d}" onclick="selectDesktop('${d}', this)"><span class="w-1.5 h-1.5 rounded-full ${d==='none'?'bg-orange-500':'bg-transparent'}"></span>${text}</div>`;
=======
                let text = d === 'none' ? 'Minimal CLI Core' : d;
                let c = d === 'none' ? 'border-ubuntuOrange text-ubuntuOrange bg-orange-50 font-semibold' : 'border-gray-200 text-gray-600 hover:bg-gray-50 bg-white';
                dGrid.innerHTML += `<div class="desktop-item p-2.5 text-xs border rounded cursor-pointer transition-all shadow-sm flex items-center gap-2 ${c}" data-val="${d}" onclick="selectDesktop('${d}', this)"><span class="w-1.5 h-1.5 rounded-full ${d==='none'?'bg-ubuntuOrange':'bg-transparent'}"></span>${text}</div>`;
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
            });
            renderPartitions();
            
            const res = await fetch('/api/status');
            const data = await res.json();
            
            document.getElementById('target-cpu').innerText = `${data.cpu} | ${data.boot_mode}`;
            
            if(data.install_state && data.install_state.status !== "idle") {
                document.getElementById('step-1').classList.add('hidden');
                document.getElementById('step-5').classList.remove('hidden');
                document.getElementById('nav-footer').style.display = 'none';
                document.getElementById('step-indicator').innerText = "Deploying Engine Process Matrix";
                
<<<<<<< HEAD
                if(data.install_state.status === "completed") {
                    document.getElementById('progress-msg').innerText = "Build Successful! System ready for reboot.";
                    document.getElementById('progress-pct').innerText = "100%";
                    document.getElementById('progress-bar-fill').style.width = "100%";
                    document.getElementById('btn-reboot').classList.remove('hidden');
                } else {
                    startTerminalStream();
=======
                if(data.install_state && data.install_state.status !== "idle") {
                    document.getElementById('step-1').classList.add('hidden');
                    document.getElementById('step-5').classList.remove('hidden');
                    document.getElementById('nav-footer').style.display = 'none';
                    document.getElementById('step-indicator').innerText = "Installing Workspace Profile Setup";
                    document.getElementById('step-title').innerText = stepTitles[4];
                    document.getElementById('left-nav-steps').style.display = 'none';
                    
                    if(data.install_state.status === "completed") {
                        document.getElementById('progress-msg').innerText = "Build Successful! System ready for reboot.";
                        document.getElementById('progress-pct').innerText = "100%";
                        document.getElementById('progress-bar-fill').style.width = "100%";
                        document.getElementById('btn-reboot').classList.remove('hidden');
                    } else {
                        startTerminalStream();
                    }
                    return;
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
                }
                return;
            }

<<<<<<< HEAD
            const diskList = document.getElementById('disk-list');
            let isFirst = true;
            data.hardware.blockdevices.forEach(dev => {
                if(dev.type === 'disk') {
                    const extraClasses = isFirst ? 'text-orange-500 bg-orange-950/20 border-l-4 border-orange-500 font-medium' : 'text-slate-400 border-l-4 border-transparent hover:bg-slate-800/20';
                    if(isFirst) { selectedDiskVal = `/dev/${dev.name}`; selectedDiskBytes = parseInt(dev.size); }
                    const sizeGB = (parseInt(dev.size) / (1024 ** 3)).toFixed(1);
                    diskList.innerHTML += `<div class="disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-[#222222] bg-[#090909] items-center ${extraClasses}" onclick="selectDisk('/dev/${dev.name}', '${dev.size}', this)"><span>🚀 Storage Unit Target: /dev/${dev.name}</span> <span class="bg-[#111111] border border-[#222222] px-2 py-0.5 rounded text-xs font-semibold font-mono text-slate-300">${sizeGB} GB</span></div>`;
                    isFirst = false;
                }
=======
                const diskList = document.getElementById('disk-list');
                let isFirst = true;
                data.hardware.blockdevices.forEach(dev => {
                    if(dev.type === 'disk') {
                        const extraClasses = isFirst ? 'text-ubuntuOrange bg-orange-50/40 border-l-4 border-ubuntuOrange font-medium' : 'text-gray-600 border-l-4 border-transparent hover:bg-gray-50';
                        if(isFirst) { selectedDiskVal = `/dev/${dev.name}`; selectedDiskBytes = parseInt(dev.size); }
                        const sizeGB = (parseInt(dev.size) / (1024 ** 3)).toFixed(1);
                        diskList.innerHTML += `<div class="disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-gray-100 bg-white items-center ${extraClasses}" onclick="selectDisk('/dev/${dev.name}', '${dev.size}', this)"><span>💾 Drive Mapping Allocation: /dev/${dev.name}</span> <span class="bg-gray-200 px-2 py-0.5 rounded text-xs font-semibold font-mono text-gray-700">${sizeGB} GB</span></div>`;
                        isFirst = false;
                    }
                });
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
            });
        };

        function renderPartitions() {
            const list = document.getElementById('partition-list');
            list.innerHTML = '';
            partitions.forEach((p, i) => {
                list.innerHTML += `
<<<<<<< HEAD
                    <div class="flex gap-1 md:gap-2 items-center bg-[#111111] p-1.5 rounded-xl border border-[#222222]">
                        <input type="text" value="${p.mountpoint}" onchange="partitions[${i}].mountpoint=this.value" class="w-[30%] bg-[#090909] border border-[#222222] p-2 rounded-lg text-xs outline-none focus:border-orange-500 text-slate-200">
                        <select onchange="partitions[${i}].fs=this.value" class="w-[25%] bg-[#090909] border border-[#222222] p-2 rounded-lg text-xs outline-none text-slate-300 cursor-pointer">
=======
                    <div class="flex gap-1 md:gap-2 items-center bg-white p-1 rounded shadow-sm">
                        <input type="text" value="${p.mountpoint}" onchange="partitions[${i}].mountpoint=this.value" class="w-[30%] border border-gray-300 p-1.5 rounded text-[11px] md:text-xs outline-none focus:border-ubuntuOrange">
                        <select onchange="partitions[${i}].fs=this.value" class="w-[25%] border border-gray-300 p-1.5 rounded text-[11px] md:text-xs outline-none bg-white">
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
                            <option value="fat32" ${p.fs=='fat32'?'selected':''}>fat32</option>
                            <option value="ext4" ${p.fs=='ext4'?'selected':''}>ext4</option>
                            <option value="btrfs" ${p.fs=='btrfs'?'selected':''}>btrfs</option>
                            <option value="xfs" ${p.fs=='xfs'?'selected':''}>xfs</option>
                            <option value="linux-swap" ${p.fs=='linux-swap'?'selected':''}>swap</option>
                        </select>
<<<<<<< HEAD
                        <div class="w-[35%] flex bg-[#090909] border border-[#222222] rounded-lg overflow-hidden">
                            <input type="number" value="${p.size}" onchange="partitions[${i}].size=parseFloat(this.value)" class="w-[55%] p-2 bg-[#090909] text-xs outline-none border-r border-[#222222] text-slate-200">
                            <select onchange="partitions[${i}].unit=this.value" class="w-[45%] bg-[#111111] text-[10px] outline-none font-bold text-slate-400 cursor-pointer">
=======
                        <div class="w-[35%] flex border border-gray-300 rounded overflow-hidden bg-white">
                            <input type="number" value="${p.size}" onchange="partitions[${i}].size=parseFloat(this.value)" class="w-[55%] md:w-1/2 p-1.5 text-[11px] md:text-xs outline-none border-r border-gray-300">
                            <select onchange="partitions[${i}].unit=this.value" class="w-[45%] md:w-1/2 bg-gray-50 text-[10px] outline-none font-medium text-gray-600">
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
                                <option value="MiB" ${p.unit=='MiB'?'selected':''}>MB</option>
                                <option value="GiB" ${p.unit=='GiB'?'selected':''}>GB</option>
                                <option value="Percent" ${p.unit=='Percent'?'selected':''}>%</option>
                            </select>
                        </div>
<<<<<<< HEAD
                        <button type="button" onclick="partitions.splice(${i}, 1); renderPartitions()" class="w-[10%] text-rose-500 font-bold text-xs hover:bg-rose-950/20 rounded-lg py-2 transition-colors">Drop</button>
=======
                        <button type="button" onclick="partitions.splice(${i}, 1); renderPartitions()" class="w-[10%] text-red-500 font-bold text-xs md:text-sm hover:bg-red-50 rounded py-1.5 transition-colors">Drop</button>
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
                    </div>
                `;
            });
        }

        function addPartition() {
            partitions.push({ id: genUUID(), mountpoint: '/home', fs: 'ext4', size: 10, unit: 'GiB' });
            renderPartitions();
        }

        function selectDisk(val, bytes, el) {
            selectedDiskVal = val; selectedDiskBytes = parseInt(bytes);
<<<<<<< HEAD
            document.querySelectorAll('.disk-item').forEach(i => i.className = "disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-[#222222] bg-[#090909] items-center text-slate-400 border-l-4 border-transparent hover:bg-slate-800/40");
            el.className = "disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-[#222222] bg-[#090909] items-center text-orange-500 bg-orange-950/20 border-l-4 border-orange-500 font-medium";
=======
            document.querySelectorAll('.disk-item').forEach(i => i.className = "disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-gray-100 bg-white items-center text-gray-600 border-l-4 border-transparent hover:bg-gray-50");
            el.className = "disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-gray-100 bg-white items-center text-ubuntuOrange bg-orange-50/40 border-l-4 border-ubuntuOrange font-medium";
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
        }

        function selectDesktop(val, el) {
            selectedDesktopVal = val;
            document.querySelectorAll('.desktop-item').forEach(i => {
<<<<<<< HEAD
                i.className = "desktop-item p-2.5 text-xs border rounded-lg cursor-pointer transition-all flex items-center gap-2 border-[#222222] text-slate-300 hover:border-slate-700 bg-slate-950/40";
=======
                i.className = "desktop-item p-2.5 text-xs border rounded cursor-pointer transition-all shadow-sm flex items-center gap-2 border-gray-200 text-gray-600 hover:bg-gray-50 bg-white";
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
                i.querySelector('span').className = "w-1.5 h-1.5 rounded-full bg-transparent";
            });
            el.className = "desktop-item p-2.5 text-xs border rounded cursor-pointer transition-all shadow-sm flex items-center gap-2 border-ubuntuOrange text-ubuntuOrange bg-orange-50 font-semibold";
            el.querySelector('span').className = "w-1.5 h-1.5 rounded-full bg-ubuntuOrange";
        }

        document.getElementById('btn-next').addEventListener('click', () => {
<<<<<<< HEAD
            const alertBox = document.getElementById('validation-alert');
            alertBox.classList.add('hidden');

            if (currentStep === 2) {
                let hasBoot = partitions.some(p => p.mountpoint === '/boot' || p.mountpoint === '/boot/efi');
                let hasRoot = partitions.some(p => p.mountpoint === '/');
                if (!hasBoot || !hasRoot) {
                    alertBox.innerText = "Validation Check Block: An isolated primary root (/) and /boot partition profile are strictly mandated to continue.";
                    alertBox.classList.remove('hidden');
                    return;
                }
            }
=======
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
            if (currentStep === 4) { submitArchinstallConfig(); }
            if (currentStep < totalSteps) {
                document.getElementById(`step-${currentStep}`).classList.add('hidden');
                document.getElementById(`nav-idx-${currentStep}`).className = "nav-item text-gray-400 flex items-center gap-2";
                document.getElementById(`nav-idx-${currentStep}`).querySelector('span').className = "w-1.5 h-1.5 bg-transparent rounded-full";
                
                currentStep++;
                document.getElementById(`step-${currentStep}`).classList.remove('hidden');
                if (currentStep < totalSteps) {
                    document.getElementById(`nav-idx-${currentStep}`).className = "nav-item text-ubuntuOrange font-bold flex items-center gap-2";
                    document.getElementById(`nav-idx-${currentStep}`).querySelector('span').className = "w-1.5 h-1.5 bg-ubuntuOrange rounded-full";
                }
                updateUI();
            }
        });

        document.getElementById('btn-back').addEventListener('click', () => {
            if (currentStep > 1 && currentStep < totalSteps) {
                document.getElementById(`step-${currentStep}`).classList.add('hidden');
                document.getElementById(`nav-idx-${currentStep}`).className = "nav-item text-gray-400 flex items-center gap-2";
                document.getElementById(`nav-idx-${currentStep}`).querySelector('span').className = "w-1.5 h-1.5 bg-transparent rounded-full";
                
                currentStep--;
                document.getElementById(`step-${currentStep}`).classList.remove('hidden');
                document.getElementById(`nav-idx-${currentStep}`).className = "nav-item text-ubuntuOrange font-bold flex items-center gap-2";
                document.getElementById(`nav-idx-${currentStep}`).querySelector('span').className = "w-1.5 h-1.5 bg-ubuntuOrange rounded-full";
                updateUI();
            }
        });

        function updateUI() {
            const dContainer = document.getElementById('nav-dots');
            dContainer.innerHTML = '';
            for(let i=1; i<totalSteps; i++) {
                let activeClass = (i === currentStep) ? 'bg-orange-500 shadow-lg shadow-orange-500/50' : 'bg-[#333333]';
                dContainer.innerHTML += `<span class="w-2 h-2 rounded-full ${activeClass}"></span>`;
            }

            document.getElementById('btn-back').style.display = (currentStep > 1 && currentStep < totalSteps) ? 'block' : 'none';
            if (currentStep < totalSteps) {
                document.getElementById('step-indicator').innerText = `Step ${currentStep} of ${totalSteps - 1}`;
            } else {
<<<<<<< HEAD
                document.getElementById('step-indicator').innerText = "Active Installation";
            }
            
            if (currentStep === totalSteps - 1) {
                document.getElementById('btn-next').innerText = "Execute Installation";
                document.getElementById('btn-next').className = "ml-auto bg-orange-600 hover:bg-orange-500 text-white font-bold py-2.5 px-6 rounded-lg text-sm shadow-md border border-transparent uppercase tracking-wider text-xs active:scale-95";
            } else if (currentStep === totalSteps) {
                document.getElementById('nav-footer').style.display = 'none';
            } else {
                document.getElementById('btn-next').innerText = "Next Step";
                document.getElementById('btn-next').className = "ml-auto bg-orange-600 hover:bg-orange-50 text-white font-bold py-2.5 px-6 rounded-lg text-sm shadow-md transition-colors active:scale-95";
=======
                document.getElementById('step-indicator').innerText = "Installing Payload Environment Setup";
                document.getElementById('step-title').innerText = stepTitles[4];
            }
            
            if (currentStep === totalSteps - 1) {
                document.getElementById('btn-next').innerText = "Install Now";
                document.getElementById('btn-next').className = "ml-auto bg-ubuntuOrange hover:bg-orange-600 text-white font-medium py-2.5 px-6 rounded text-sm shadow-sm transition-colors border border-transparent uppercase tracking-wider text-xs";
            } else if (currentStep === totalSteps) {
                document.getElementById('nav-footer').style.display = 'none';
            } else {
                document.getElementById('btn-next').innerText = "Continue";
                document.getElementById('btn-next').className = "ml-auto bg-white border border-gray-300 hover:border-gray-400 text-gray-800 font-medium py-2 px-6 rounded text-sm shadow-sm shadow-inner transition-colors";
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
            }
        }

        async function submitArchinstallConfig() {
            let currentStartBytes = 1048576;

            let btrfsConfigured = false;
            let partsPayload = partitions.map(p => {
                let pSizeB = 0;
                if(p.unit === 'Percent') pSizeB = Math.floor((selectedDiskBytes - currentStartBytes) * (p.size / 100));
                else if(p.unit === 'MiB') pSizeB = p.size * 1024 * 1024;
                else if(p.unit === 'GiB') pSizeB = p.size * 1024 * 1024 * 1024;

                let isBoot = (p.mountpoint === '/boot' || p.mountpoint === '/boot/efi' || p.fs === 'fat32');
                let isBtrfs = p.fs === 'btrfs';
                if(isBtrfs) btrfsConfigured = true;
                
                let btrfsVols = (isBtrfs && p.mountpoint === '/') ? [
                    { "mountpoint": "/", "name": "@" },
                    { "mountpoint": "/home", "name": "@home" },
                    { "mountpoint": "/var/log", "name": "@log" },
                    { "mountpoint": "/var/cache/pacman/pkg", "name": "@pkg" }
                ] : [];

                let pObj = {
                    "obj_id": p.id,
                    "status": "create",
                    "type": "primary",
                    "start": { "sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": currentStartBytes },
                    "size": { "sector_size": {"unit": "B", "value": 512}, "unit": "B", "value": pSizeB },
                    "fs_type": p.fs,
                    "mountpoint": (isBtrfs && p.mountpoint === '/') ? null : p.mountpoint,
                    "mount_options": isBtrfs ? ["compress=zstd"] : [],
                    "flags": isBoot ? ["boot"] : [],
                    "dev_path": null,
                    "btrfs": btrfsVols
                };
                currentStartBytes += pSizeB;
                return pObj;
            });

            const configPayload = {
                "version": "4.3",
                "archinstall-language": "English",
                "app_config": { "audio_config": { "audio": document.getElementById('audio').value } },
                "bootloader_config": { "bootloader": document.getElementById('bootloader').value, "removable": false, "uki": false },
                "disk_config": {
                    "config_type": "default_layout",
                    "device_modifications": [{ "device": selectedDiskVal, "wipe": true, "partitions": partsPayload }]
                },
                "hostname": document.getElementById('hostname').value,
                "kernels": [document.getElementById('kernel').value],
                "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US.UTF-8" },
                "mirror_config": { "mirror_regions": { "Worldwide": ["https://geo.mirror.pkgbuild.com/$repo/os/$arch"] } },
                "network_config": { "type": "nm" },
                "no_pkg_lookups": false,
                "ntp": true,
                "offline": true,
                "packages": [],
                "pacman_config": { "color": true, "parallel_downloads": 5 },
                "script": null,
                "swap": document.getElementById('swap').checked ? { "enabled": true, "algorithm": "zstd" } : { "enabled": false },
                "timezone": document.getElementById('timezone').value
            };

            if (btrfsConfigured) configPayload.disk_config.btrfs_options = { "snapshot_config": { "type": "Timeshift" } };
            if (document.getElementById('bluetooth').checked) configPayload.app_config.bluetooth_config = { "enabled": true };
            if (document.getElementById('firewall').checked) configPayload.app_config.firewall_config = { "firewall": "ufw" };
            if (document.getElementById('printing').checked) configPayload.app_config.print_service_config = { "enabled": true };
            if (document.getElementById('fonts').checked) configPayload.app_config.fonts_config = { "fonts": ["noto-fonts-emoji", "noto-fonts-cjk", "ttf-liberation", "ttf-dejavu", "noto-fonts"] };

            if (selectedDesktopVal !== "none") {
                let mainType = "Desktop";
                const wms = ["Awesome","Bspwm","Hyprland","i3-wm","Labwc","Niri","Qtile","River","Sway","Xmonad"];
                const polkits = ["Hyprland","Sway","Labwc","Niri"];
                if (wms.includes(selectedDesktopVal)) mainType = "WindowMgr";
                
                let cSettings = {};
                cSettings[selectedDesktopVal] = {};
                if(polkits.includes(selectedDesktopVal)) cSettings[selectedDesktopVal].seat_access = "polkit";
                if(selectedDesktopVal === "KDE Plasma") cSettings[selectedDesktopVal].plasma_flavor = "plasma-meta";

                configPayload.profile_config = {
                    "gfx_driver": "All open-source",
                    "greeter": "sddm",
                    "profile": {
                        "custom_settings": cSettings,
                        "details": [selectedDesktopVal],
                        "main": mainType
                    }
                };
            }

            const credsPayload = {
                "root_enc_password": null,
                "users": [{
                    "username": document.getElementById('username').value,
                    "enc_password": null,
                    "password": document.getElementById('password').value,
                    "groups": [],
                    "sudo": true
                }]
            };

            const rootPass = document.getElementById('root-password').value;
            if (rootPass) {
                credsPayload["root-password"] = rootPass;
            }

<<<<<<< HEAD
            document.getElementById('progress-msg').innerText = "Transmitting configuration mapping vectors to background socket layers...";
=======
            document.getElementById('left-nav-steps').style.display = 'none';
            document.getElementById('progress-msg').innerText = "Transmitting metrics to local deployment socket layers...";
>>>>>>> parent of 0f1bd1f (updated design and improved partitioning logic)
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
                    document.getElementById('progress-msg').classList.replace('text-ubuntuOrange', 'text-red-600');
                    document.getElementById('progress-bar-fill').className = "bg-red-600 h-full rounded-full";
                    document.getElementById('progress-pct').classList.replace('text-ubuntuOrange', 'text-red-600');
                    document.getElementById('installation-header-title').innerText = "Deployment Fault Encountered";
                    stream.close();
                }
                if(data.status === "completed") {
                    document.getElementById('btn-reboot').classList.remove('hidden');
                    stream.close();
                }
            };
        }

        document.getElementById('btn-reboot').addEventListener('click', async () => {
            document.getElementById('btn-reboot').innerText = "Rebooting Hardware...";
            document.getElementById('btn-reboot').classList.add('opacity-50', 'cursor-not-allowed');
            await fetch('/api/reboot', { method: 'POST' });
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