import http.server
import socketserver
import json
import subprocess
import os
import threading
import time
import re
from urllib.parse import urlparse

PORT = 5000
CONFIG_PATH = '/tmp/config.json'
CREDS_PATH = '/tmp/creds.json'
LOG_FILE = '/tmp/archinstall-webui.log'
STATE_FILE = '/tmp/archinstall-state.txt'

install_state = {"percentage": 0, "message": "Awaiting mobile configuration matrix...", "status": "idle"}
ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
pacman_progress_re = re.compile(r'\( *(\d+)/ *(\d+)\)')

def update_state(pct, msg, status):
    global install_state
    if status not in ["idle", "error"] and pct < install_state["percentage"]:
        pct = install_state["percentage"]
    install_state = {"percentage": pct, "message": msg, "status": status}
    try:
        with open(STATE_FILE, 'w') as f:
            f.write(f"{pct}|{msg}|{status}\n")
    except: pass

def get_tail_logs(lines=150):
    try:
        with open(LOG_FILE, 'r') as f:
            return [line.strip() for line in f.readlines()[-lines:] if line.strip()]
    except:
        return []

def get_system_telemetry():
    telemetry = {"cpu": "x86_64 Architecture", "boot_mode": "BIOS", "hardware": {}}
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
    update_state(2, "Clearing disk locks and orphaned mounts...", "running")
    os.system('pkill -9 pacman >> /tmp/archinstall-webui.log 2>&1')
    os.system('pkill -9 pacstrap >> /tmp/archinstall-webui.log 2>&1')
    os.system('fuser -k -m /mnt/archinstall >> /tmp/archinstall-webui.log 2>&1')
    os.system('swapoff -a >> /tmp/archinstall-webui.log 2>&1')
    os.system('umount -R /mnt/archinstall >> /tmp/archinstall-webui.log 2>&1')
    try:
        with open(CONFIG_PATH, 'r') as f:
            config = json.load(f)
            devices = config.get('disk_config', {}).get('device_modifications', [])
            for mod in devices:
                dev = mod.get('device')
                if dev:
                    os.system(f'fuser -k -m {dev}* >> /tmp/archinstall-webui.log 2>&1')
                    os.system(f'umount -f {dev}* >> /tmp/archinstall-webui.log 2>&1')
                    os.system(f'wipefs -af {dev}* >> /tmp/archinstall-webui.log 2>&1')
                    os.system(f'wipefs -af {dev} >> /tmp/archinstall-webui.log 2>&1')
                    os.system(f'sgdisk --zap-all {dev} >> /tmp/archinstall-webui.log 2>&1')
                    os.system(f'partprobe {dev} >> /tmp/archinstall-webui.log 2>&1')
    except Exception as e:
        pass
    os.system('umount -l -R /mnt/archinstall >> /tmp/archinstall-webui.log 2>&1')
    os.system('udevadm settle >> /tmp/archinstall-webui.log 2>&1')
    time.sleep(2)
    update_state(5, "Synchronizing pacman mirror repositories...", "running")
    os.system('sed -i "s/#ParallelDownloads = 5/ParallelDownloads = 10/" /etc/pacman.conf')
    os.system('echo "FallbackNTP=time.google.com time.cloudflare.com" >> /etc/systemd/timesyncd.conf')
    os.system('systemctl restart systemd-timesyncd >> /tmp/archinstall-webui.log 2>&1')
    os.system('pacman -Sy --noconfirm >> /tmp/archinstall-webui.log 2>&1')
    
    cmd = ["archinstall", "--config", CONFIG_PATH, "--creds", CREDS_PATH, "--silent"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    
    indicators = [
        ("writing partition", 10, "Writing partition tables..."),
        ("formatting", 15, "Formatting storage block partitions..."),
        ("mounting", 18, "Mounting target filesystems..."),
        ("time sync", 22, "Synchronizing network precision NTP clocks..."),
        ("waiting for time sync", 22, "Synchronizing network precision NTP clocks..."),
        ("pacstrap", 25, "Bootstrapping Arch Linux base environment..."),
        ("installing packages to", 25, "Bootstrapping Arch Linux base environment..."),
        ("installing base", 25, "Bootstrapping Arch Linux base environment..."),
        ("installing kernel", 60, "Deploying Linux kernel modules..."),
        ("bootloader", 70, "Installing system bootloader..."),
        ("configuring bootloader", 74, "Injecting system core bootloader configuration..."),
        ("creating user", 80, "Configuring system users..."),
        ("useradd", 80, "Configuring system users..."),
        ("profile", 84, "Compiling environment configuration variables..."),
        ("enabling service", 88, "Enabling targeted network running services..."),
        ("setting timezone", 92, "Applying localization and timezone rules..."),
        ("creating initramfs", 95, "Generating initial ramdisk environment..."),
        ("mkinitcpio", 95, "Generating initial ramdisk environment..."),
        ("installation completed", 100, "Build Successful! Node is safe for hardware restart cycles.")
    ]
    
    with open(LOG_FILE, 'a') as master_log:
        for raw_line in process.stdout:
            line_clean = ansi_escape.sub('', raw_line.rstrip())
            lower_line = line_clean.lower()
            
            if "archinstall.lib.exceptions" in lower_line or "requires a uefi system" in lower_line or "fatal error:" in lower_line:
                update_state(99, f"Fatal Error: {line_clean}", "error")
                process.kill()
                break
                
            for key, pct, msg in indicators:
                if key in lower_line and install_state["percentage"] < pct:
                    update_state(pct, msg, "running" if pct < 100 else "completed")
            
            if 25 <= install_state["percentage"] < 60:
                match = pacman_progress_re.search(lower_line)
                if match:
                    current = int(match.group(1))
                    total = int(match.group(2))
                    if total > 50 and current <= total:
                        mapped_pct = int(25 + (current / total) * 34)
                        if mapped_pct > install_state["percentage"]:
                            update_state(mapped_pct, "Fetching and unpacking system components...", "running")
                elif "downloading" in lower_line and install_state["percentage"] < 35:
                    update_state(install_state["percentage"] + 1, "Downloading repository databases...", "running")
            
            if 95 <= install_state["percentage"] < 99 and "==> starting build" in lower_line:
                update_state(install_state["percentage"] + 1, "Compiling Linux initramfs kernel images...", "running")
                
            is_progress = False
            if re.search(r'\[#+ *-*\]', line_clean) or re.search(r'\[█+ *\]', line_clean) or re.search(r'\[=+ *> *\]', line_clean):
                is_progress = True
            if re.match(r'^[\s\d]+%\s*$', line_clean):
                is_progress = True
                
            if not is_progress and line_clean.strip():
                master_log.write(f"[ARCHINSTALL] {line_clean}\n")
                master_log.flush()
                
    process.wait()
    if process.returncode != 0 and install_state["status"] not in ["completed", "error"]:
        update_state(99, f"Archinstall crashed. Exit Code {process.returncode}. See Log.", "error")

class APIHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        super().end_headers()
    def do_OPTIONS(self):
        self.send_response(200, "ok")
        self.end_headers()
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/':
            self.path = '/index.html'
            return super().do_GET()
        if path == '/api/status':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            data = get_system_telemetry()
            data['install_state'] = install_state.copy()
            data['install_state']['logs'] = get_tail_logs()
            self.wfile.write(json.dumps(data).encode('utf-8'))
        elif path == '/api/progress':
            self.send_response(200)
            self.send_header('Content-type', 'text/event-stream')
            self.end_headers()
            try:
                while True:
                    payload = install_state.copy()
                    payload["logs"] = get_tail_logs()
                    self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode('utf-8'))
                    self.wfile.flush()
                    if install_state["status"] in ["completed", "error"]: break
                    time.sleep(1)
            except: pass
        else:
            return super().do_GET()
    def do_POST(self):
        path = urlparse(self.path).path
        if path == '/api/submit':
            length = int(self.headers['Content-Length'])
            post_data = json.loads(self.rfile.read(length))
            with open(CONFIG_PATH, 'w') as f: json.dump(post_data.get('config', {}), f, indent=4)
            with open(CREDS_PATH, 'w') as f: json.dump(post_data.get('creds', {}), f, indent=4)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode('utf-8'))
            threading.Thread(target=run_archinstall).start()
        elif path == '/api/reboot':
            self.send_response(200)
            self.end_headers()
            threading.Thread(target=lambda: (time.sleep(1), os.system('systemctl reboot'))).start()

class ReuseServer(socketserver.ThreadingTCPServer): allow_reuse_address = True

if __name__ == '__main__':
    update_state(0, "Awaiting WebUI configuration...", "idle")
    with ReuseServer(("", PORT), APIHandler) as httpd: httpd.serve_forever()