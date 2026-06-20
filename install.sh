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
    os.system('umount -R /mnt >/dev/null 2>&1')
    os.system('swapoff -a >/dev/null 2>&1')
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
    <title>Arch Linux Installer</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
    <style>
        body { font-family: 'Inter', sans-serif; background: #020617; color: #f8fafc; }
        .custom-scrollbar::-webkit-scrollbar { width: 6px; }
        .custom-scrollbar::-webkit-scrollbar-track { background: transparent; }
        .custom-scrollbar::-webkit-scrollbar-thumb { background: #1e293b; border-radius: 10px; }
    </style>
</head>
<body class="min-h-screen flex items-center justify-center p-2 md:p-4">
    <div class="w-full max-w-4xl bg-slate-900 border border-slate-800 rounded-2xl shadow-2xl overflow-hidden flex flex-col min-h-[92vh] md:min-h-[620px]">
        
        <div class="bg-slate-950 px-4 md:px-6 py-4 border-b border-slate-800 flex justify-between items-center select-none">
            <div class="flex items-center gap-3">
                <div class="bg-orange-500 text-white font-black h-8 w-8 rounded-lg flex items-center justify-center shadow-md">Æ</div>
                <div>
                    <span class="font-bold tracking-wide uppercase text-sm text-slate-200 block">Archinstall Engine</span>
                    <span class="text-[10px] text-slate-500 font-mono block w-[160px] md:w-auto truncate -mt-0.5" id="target-cpu">Connecting...</span>
                </div>
            </div>
            <span id="step-indicator" class="text-xs font-bold bg-slate-800 px-3 py-1 rounded-full text-slate-300">Step 1 of 4</span>
        </div>

        <div class="p-4 md:p-8 flex-grow overflow-y-auto custom-scrollbar">
            <div id="validation-alert" class="hidden mb-4 p-3 bg-red-950/40 border border-red-900 text-red-400 text-xs rounded-lg font-medium"></div>
            <form id="wizard-form" class="space-y-6">
                
                <div id="step-1" class="wizard-step block space-y-4">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-orange-500">1. Storage Architecture</h2>
                    </div>
                    <div class="border border-slate-800 bg-slate-950 rounded-lg overflow-hidden h-44 custom-scrollbar overflow-y-auto" id="disk-list"></div>
                    <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                        <div>
                            <label class="block text-[11px] font-bold text-slate-400 uppercase mb-1.5">Bootloader Target</label>
                            <select id="bootloader" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-3 text-sm text-slate-200 outline-none focus:border-orange-500">
                                <option value="Grub">GRUB 2 Module</option>
                                <option value="Systemd-boot">Systemd-boot Native</option>
                            </select>
                        </div>
                    </div>
                    <div class="flex items-center gap-3 p-3.5 bg-slate-950 border border-slate-800 rounded-lg">
                        <input type="checkbox" id="swap" checked class="w-4 h-4 text-orange-500 border-slate-800 bg-slate-900 rounded focus:ring-orange-500 accent-orange-500 cursor-pointer">
                        <label for="swap" class="text-sm font-semibold text-slate-200 cursor-pointer">Allocate zRAM Swap Module</label>
                    </div>
                </div>

                <div id="step-2" class="wizard-step hidden space-y-4">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-orange-500">2. Partition Table Configuration</h2>
                    </div>
                    <div class="bg-slate-950 border border-slate-800 rounded-lg p-3 md:p-4">
                        <div class="flex font-bold text-[10px] md:text-xs text-slate-400 mb-2 border-b border-slate-800 pb-2 uppercase tracking-wider">
                            <div class="w-[30%]">Mount Point</div>
                            <div class="w-[25%]">FS Type</div>
                            <div class="w-[35%]">Block Size</div>
                            <div class="w-[10%] text-center">Drop</div>
                        </div>
                        <div id="partition-list" class="space-y-2 mb-3"></div>
                        <button type="button" onclick="addPartition()" class="text-xs bg-slate-900 border border-slate-800 px-4 py-2 rounded font-semibold text-slate-300 hover:bg-slate-800 transition-colors">+ Add Custom Partition</button>
                    </div>
                </div>

                <div id="step-3" class="wizard-step hidden space-y-4">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-orange-500">3. Workspace & Core Ecosystem</h2>
                    </div>
                    <div class="border border-slate-800 bg-slate-950 rounded-lg overflow-hidden p-2 custom-scrollbar overflow-y-auto max-h-44 grid grid-cols-2 md:grid-cols-3 gap-2" id="desktop-grid"></div>
                    
                    <h4 class="text-[11px] font-bold text-slate-400 uppercase tracking-wider mt-4">Additional Core App Services</h4>
                    <div class="grid grid-cols-2 gap-2 md:gap-3">
                        <label class="flex items-center gap-2 p-2.5 bg-slate-950 border border-slate-800 rounded text-xs text-slate-300 cursor-pointer hover:border-slate-700"><input type="checkbox" id="bluetooth" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-slate-900 border-slate-800 accent-orange-500"> Bluetooth</label>
                        <label class="flex items-center gap-2 p-2.5 bg-slate-950 border border-slate-800 rounded text-xs text-slate-300 cursor-pointer hover:border-slate-700"><input type="checkbox" id="firewall" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-slate-900 border-slate-800 accent-orange-500"> UFW Firewall</label>
                        <label class="flex items-center gap-2 p-2.5 bg-slate-950 border border-slate-800 rounded text-xs text-slate-300 cursor-pointer hover:border-slate-700"><input type="checkbox" id="printing" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-slate-900 border-slate-800 accent-orange-500"> CUPS Printing</label>
                        <label class="flex items-center gap-2 p-2.5 bg-slate-950 border border-slate-800 rounded text-xs text-slate-300 cursor-pointer hover:border-slate-700"><input type="checkbox" id="fonts" checked class="text-orange-500 focus:ring-orange-500 rounded w-4 h-4 bg-slate-900 border-slate-800 accent-orange-500"> Noto Fonts</label>
                    </div>

                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1">Target Base Kernel</label>
                            <select id="kernel" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-orange-500">
                                <option value="linux">Standard Upstream</option>
                                <option value="linux-lts">LTS (Long Term Support)</option>
                                <option value="linux-zen">Zen Kernel</option>
                            </select>
                        </div>
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1">Audio Server</label>
                            <select id="audio" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-orange-500">
                                <option value="pipewire">Pipewire (Default)</option>
                                <option value="pulseaudio">Legacy PulseAudio</option>
                            </select>
                        </div>
                    </div>
                </div>

                <div id="step-4" class="wizard-step hidden space-y-4">
                    <div class="border-b border-slate-800 pb-2">
                        <h2 class="text-lg font-bold text-orange-500">4. Accounts & Access Layer</h2>
                    </div>
                    <div class="grid grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1">Hostname</label>
                            <input type="text" id="hostname" value="archlinux" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-orange-500 shadow-sm">
                        </div>
                        <div>
                            <label class="block text-xs font-semibold text-slate-400 mb-1">Timezone</label>
                            <input type="text" id="timezone" value="UTC" class="w-full bg-slate-950 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-orange-500 shadow-sm">
                        </div>
                    </div>
                    <div class="bg-slate-950 border border-slate-800 rounded-lg p-4 space-y-3">
                        <h4 class="text-xs font-bold text-slate-400 uppercase tracking-wider border-b border-slate-800 pb-1.5">User Profile Configuration</h4>
                        <div class="grid grid-cols-2 gap-4">
                            <div><input type="text" id="username" placeholder="Username" class="w-full bg-slate-900 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-orange-500"></div>
                            <div><input type="password" id="password" placeholder="User Password" class="w-full bg-slate-900 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-orange-500"></div>
                        </div>
                        <div><input type="password" id="root-password" placeholder="Superuser Root Password" class="w-full bg-slate-900 border border-slate-800 rounded-lg p-2.5 text-sm text-slate-200 outline-none focus:border-red-500"></div>
                    </div>
                </div>

                <div id="step-5" class="wizard-step hidden flex flex-col items-center justify-center h-full pt-8 pb-8">
                    <div class="text-center w-full max-w-lg">
                        <h2 class="text-xl font-bold text-white mb-2">Deploying Infrastructure Engine</h2>
                        <p id="progress-msg" class="text-xs font-semibold text-orange-500 font-mono tracking-tight mb-8">Transmitting deployment matrices...</p>
                        <div class="flex justify-between items-end mb-2 px-1">
                            <span class="text-[10px] font-bold text-slate-400 uppercase tracking-wider">Installation Progress Metric</span>
                            <span id="progress-pct" class="text-3xl font-bold text-white tracking-tighter">0%</span>
                        </div>
                        <div class="w-full bg-slate-950 rounded-full h-3 overflow-hidden p-0.5 border border-slate-800 mb-8 shadow-inner">
                            <div id="progress-bar-fill" class="bg-gradient-to-r from-orange-500 to-amber-400 h-full rounded-full w-0 transition-all duration-500 ease-out"></div>
                        </div>
                        <button type="button" id="btn-reboot" class="hidden w-full bg-gradient-to-r from-emerald-600 to-teal-600 hover:from-emerald-500 hover:to-teal-500 text-white font-bold py-3.5 rounded-xl text-sm transition-all shadow-lg uppercase tracking-wider">Close Volumes & Reboot Hardware</button>
                    </div>
                </div>
            </form>
        </div>

        <div id="nav-footer" class="px-4 md:px-6 py-4 bg-slate-950 border-t border-slate-800 flex justify-between items-center shrink-0">
            <button type="button" id="btn-back" class="text-slate-400 hover:text-white font-bold text-sm hidden py-2 px-4 border border-slate-800 rounded-lg shadow-sm hover:bg-slate-900 transition-colors">Back</button>
            <button type="button" id="btn-next" class="ml-auto bg-orange-600 hover:bg-orange-50 text-white font-bold py-2.5 px-6 rounded-lg text-sm shadow-md transition-all active:scale-95">Continue</button>
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
                return v.toString(166);
            });
        }

        window.onload = () => {
            const dGrid = document.getElementById('desktop-grid');
            desktops.forEach(d => {
                let text = d === 'none' ? 'Minimal (CLI Core)' : d;
                let c = d === 'none' ? 'border-orange-500 text-orange-500 bg-orange-950/20 font-semibold' : 'border-slate-800 text-slate-300 hover:border-slate-700 bg-slate-950/40';
                dGrid.innerHTML += `<div class="desktop-item p-2.5 text-xs border rounded-lg cursor-pointer transition-all flex items-center gap-2 ${c}" data-val="${d}" onclick="selectDesktop('${d}', this)"><span class="w-1.5 h-1.5 rounded-full ${d==='none'?'bg-orange-500':'bg-transparent'}"></span>${text}</div>`;
            });
            renderPartitions();
            
            fetch('/api/status').then(r => r.json()).then(data => {
                document.getElementById('target-cpu').innerText = `${data.cpu} | ${data.boot_mode}`;
                
                if(data.install_state && data.install_state.status !== "idle") {
                    document.getElementById('step-1').classList.add('hidden');
                    document.getElementById('step-5').classList.remove('hidden');
                    document.getElementById('nav-footer').style.display = 'none';
                    document.getElementById('step-indicator').innerText = "Installing";
                    document.getElementById('step-title').innerText = stepTitles[4];
                    
                    if(data.install_state.status === "completed") {
                        document.getElementById('progress-msg').innerText = "Build Successful! System ready for reboot.";
                        document.getElementById('progress-pct').innerText = "100%";
                        document.getElementById('progress-bar-fill').style.width = "100%";
                        document.getElementById('btn-reboot').classList.remove('hidden');
                    } else {
                        startTerminalStream();
                    }
                    return;
                }

                const diskList = document.getElementById('disk-list');
                let isFirst = true;
                data.hardware.blockdevices.forEach(dev => {
                    if(dev.type === 'disk') {
                        const extraClasses = isFirst ? 'text-orange-500 bg-orange-950/20 border-l-4 border-orange-500 font-medium' : 'text-slate-400 border-l-4 border-transparent hover:bg-slate-800/40';
                        if(isFirst) { selectedDiskVal = `/dev/${dev.name}`; selectedDiskBytes = parseInt(dev.size); }
                        const sizeGB = (parseInt(dev.size) / (1024 ** 3)).toFixed(1);
                        diskList.innerHTML += `<div class="disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-slate-800 bg-slate-950 items-center ${extraClasses}" onclick="selectDisk('/dev/${dev.name}', '${dev.size}', this)"><span> 💡 Block Drive: /dev/${dev.name}</span> <span class="bg-slate-900 border border-slate-800 px-2 py-0.5 rounded text-xs font-semibold font-mono text-slate-300">${sizeGB} GB</span></div>`;
                        isFirst = false;
                    }
                });
            });
        };

        function renderPartitions() {
            const list = document.getElementById('partition-list');
            list.innerHTML = '';
            partitions.forEach((p, i) => {
                list.innerHTML += `
                    <div class="flex gap-1 md:gap-2 items-center bg-slate-900 p-1 rounded-lg border border-slate-800/60">
                        <input type="text" value="${p.mountpoint}" onchange="partitions[${i}].mountpoint=this.value" class="w-[30%] bg-slate-950 border border-slate-800 p-1.5 rounded text-[11px] md:text-xs outline-none focus:border-orange-500 text-slate-200">
                        <select onchange="partitions[${i}].fs=this.value" class="w-[25%] bg-slate-950 border border-slate-800 p-1.5 rounded text-[11px] md:text-xs outline-none text-slate-200">
                            <option value="fat32" ${p.fs=='fat32'?'selected':''}>fat32</option>
                            <option value="ext4" ${p.fs=='ext4'?'selected':''}>ext4</option>
                            <option value="btrfs" ${p.fs=='btrfs'?'selected':''}>btrfs</option>
                            <option value="xfs" ${p.fs=='xfs'?'selected':''}>xfs</option>
                            <option value="linux-swap" ${p.fs=='linux-swap'?'selected':''}>swap</option>
                        </select>
                        <div class="w-[35%] flex bg-slate-950 border border-slate-800 rounded overflow-hidden">
                            <input type="number" value="${p.size}" onchange="partitions[${i}].size=parseFloat(this.value)" class="w-[55%] md:w-1/2 bg-slate-950 p-1.5 text-[11px] md:text-xs outline-none border-r border-slate-800 text-slate-200">
                            <select onchange="partitions[${i}].unit=this.value" class="w-[45%] md:w-1/2 bg-slate-900 text-[10px] outline-none font-semibold text-slate-400">
                                <option value="MiB" ${p.unit=='MiB'?'selected':''}>MB</option>
                                <option value="GiB" ${p.unit=='GiB'?'selected':''}>GB</option>
                                <option value="Percent" ${p.unit=='Percent'?'selected':''}>%</option>
                            </select>
                        </div>
                        <button type="button" onclick="partitions.splice(${i}, 1); renderPartitions()" class="w-[10%] text-rose-500 font-bold text-xs md:text-sm hover:bg-rose-950/20 rounded py-1.5 transition-colors">Drop</button>
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
            document.querySelectorAll('.disk-item').forEach(i => i.className = "disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-slate-800 bg-slate-950 items-center text-slate-400 border-l-4 border-transparent hover:bg-slate-800/40");
            el.className = "disk-item p-4 text-sm cursor-pointer transition-all flex justify-between border-b border-slate-800 bg-slate-950 items-center text-orange-500 bg-orange-950/20 border-l-4 border-orange-500 font-medium";
        }

        function selectDesktop(val, el) {
            selectedDesktopVal = val;
            document.querySelectorAll('.desktop-item').forEach(i => {
                i.className = "desktop-item p-2.5 text-xs border rounded-lg cursor-pointer transition-all flex items-center gap-2 border-slate-800 text-slate-300 hover:border-slate-700 bg-slate-950/40";
                i.querySelector('span').className = "w-1.5 h-1.5 rounded-full bg-transparent";
            });
            el.className = "desktop-item p-2.5 text-xs border rounded-lg cursor-pointer transition-all flex items-center gap-2 border-orange-500 text-orange-500 bg-orange-950/20 font-semibold";
            el.querySelector('span').className = "w-1.5 h-1.5 rounded-full bg-orange-500";
        }

        document.getElementById('btn-next').addEventListener('click', () => {
            const alertBox = document.getElementById('validation-alert');
            alertBox.classList.add('hidden');

            if (currentStep === 2) {
                let hasBoot = partitions.some(p => p.mountpoint === '/boot' || p.mountpoint === '/boot/efi');
                let hasRoot = partitions.some(p => p.mountpoint === '/');
                if (!hasBoot || !hasRoot) {
                    alertBox.innerText = "Error: Layout validation failure. You must define an active /boot and root (/) mount configuration path before continuing.";
                    alertBox.classList.remove('hidden');
                    return;
                }
            }
            if (currentStep === 4) { submitArchinstallConfig(); }
            if (currentStep < totalSteps) {
                document.getElementById(`step-${currentStep}`).classList.add('hidden');
                currentStep++;
                document.getElementById(`step-${currentStep}`).classList.remove('hidden');
                updateUI();
            }
        });

        document.getElementById('btn-back').addEventListener('click', () => {
            document.getElementById('validation-alert').classList.add('hidden');
            if (currentStep > 1 && currentStep < totalSteps) {
                document.getElementById(`step-${currentStep}`).classList.add('hidden');
                currentStep--;
                document.getElementById(`step-${currentStep}`).classList.remove('hidden');
                updateUI();
            }
        });

        function updateUI() {
            document.getElementById('btn-back').style.display = (currentStep > 1 && currentStep < totalSteps) ? 'block' : 'none';
            if (currentStep < totalSteps) {
                document.getElementById('step-indicator').innerText = `Step ${currentStep} of ${totalSteps - 1}`;
                document.getElementById('step-title').innerText = stepTitles[currentStep - 1];
            } else {
                document.getElementById('step-indicator').innerText = "Installing";
                document.getElementById('step-title').innerText = stepTitles[4];
            }
            
            if (currentStep === totalSteps - 1) {
                document.getElementById('btn-next').innerText = "Install Now";
                document.getElementById('btn-next').className = "ml-auto bg-orange-600 hover:bg-orange-500 text-white font-bold py-2.5 px-6 rounded-lg text-sm shadow-md border border-transparent uppercase tracking-wider text-xs active:scale-95";
            } else if (currentStep === totalSteps) {
                document.getElementById('nav-footer').style.display = 'none';
            } else {
                document.getElementById('btn-next').innerText = "Continue";
                document.getElementById('btn-next').className = "ml-auto bg-orange-600 hover:bg-orange-50 text-white font-bold py-2.5 px-6 rounded-lg text-sm shadow-md transition-colors active:scale-95";
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

            document.getElementById('progress-msg').innerText = "Transmitting parameters to local deployment socket layers...";
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
                    document.getElementById('progress-msg').classList.replace('text-orange-500', 'text-red-500');
                    document.getElementById('progress-bar-fill').className = "bg-red-600 h-full rounded-full";
                    document.getElementById('progress-pct').classList.replace('text-white', 'text-red-500');
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

kill $SSH_PID 2>/dev/null || true