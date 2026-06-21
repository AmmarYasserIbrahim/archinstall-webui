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
LOG_FILE = '/tmp/archinstall-webui.log'
STATE_FILE = '/tmp/archinstall-state.txt'

install_state = {"percentage": 0, "message": "Awaiting mobile configuration matrix...", "status": "idle"}

def update_state(pct, msg, status):
    global install_state
    install_state = {"percentage": pct, "message": msg, "status": status}
    try:
        with open(STATE_FILE, 'w') as f:
            f.write(f"{pct}|{msg}|{status}\n")
    except: pass

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
    
    # 1. Global swap and mount clearing
    os.system('swapoff -a >> /tmp/archinstall-webui.log 2>&1')
    os.system('umount -R /mnt >> /tmp/archinstall-webui.log 2>&1')
    
    # 2. Aggressive Target Disk Zapping
    try:
        with open(CONFIG_PATH, 'r') as f:
            config = json.load(f)
            devices = config.get('disk_config', {}).get('device_modifications', [])
            for mod in devices:
                dev = mod.get('device')
                if dev:
                    # Unmount any specific partitions on this drive
                    os.system(f'umount -l {dev}* >> /tmp/archinstall-webui.log 2>&1')
                    # Destroy filesystem signatures so udev releases it
                    os.system(f'wipefs -af {dev}* >> /tmp/archinstall-webui.log 2>&1')
                    os.system(f'wipefs -af {dev} >> /tmp/archinstall-webui.log 2>&1')
                    # Zap GPT/MBR partition tables completely
                    os.system(f'sgdisk --zap-all {dev} >> /tmp/archinstall-webui.log 2>&1')
                    # Force the kernel to immediately re-read the now-empty block device
                    os.system(f'partprobe {dev} >> /tmp/archinstall-webui.log 2>&1')
    except Exception as e:
        pass

    # Give the kernel and udev a moment to settle down after the wipe
    time.sleep(2) 

    update_state(5, "Synchronizing pacman mirror repositories...", "running")
    os.system('pacman -Sy --noconfirm >> /tmp/archinstall-webui.log 2>&1')
    
    cmd = ["archinstall", "--config", CONFIG_PATH, "--creds", CREDS_PATH, "--silent"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    
    indicators = [
        ("formatting", 15, "Formatting storage block partitions..."),
        ("waiting for time sync", 22, "Synchronizing network precision NTP clocks..."),
        ("pacstrap", 48, "Extracting base core packages to dev structures..."),
        ("bootloader", 72, "Injecting system core bootloader modifications..."),
        ("profile", 84, "Compiling environment configuration variables..."),
        ("services", 93, "Enabling targeted network running services..."),
        ("installation completed", 100, "Build Successful! Node is safe for hardware restart cycles.")
    ]

    with open(LOG_FILE, 'a') as master_log:
        for line in process.stdout:
            master_log.write(f"[ARCHINSTALL] {line}")
            master_log.flush()
            lower_line = line.lower()
            
            for key, pct, msg in indicators:
                if key in lower_line and install_state["percentage"] < pct:
                    update_state(pct, msg, "running" if pct < 100 else "completed")

    process.wait()
    if process.returncode != 0 and install_state["status"] != "completed":
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
            data['install_state'] = install_state
            self.wfile.write(json.dumps(data).encode('utf-8'))
        elif path == '/api/progress':
            self.send_response(200)
            self.send_header('Content-type', 'text/event-stream')
            self.end_headers()
            try:
                while True:
                    self.wfile.write(f"data: {json.dumps(install_state)}\n\n".encode('utf-8'))
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