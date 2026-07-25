import http.server
import json
import os
import re
import socketserver
import subprocess
import threading
import time
from urllib.parse import urlparse

PORT = int(os.environ.get('ARCHWEBUI_PORT', '5000'))
CONFIG_PATH = '/tmp/config.json'
CREDS_PATH = '/tmp/creds.json'
LOG_FILE = '/tmp/archinstall-webui.log'
STATE_FILE = '/tmp/archinstall-state.txt'
ALLOWED_ORIGIN = os.environ.get('ARCHWEBUI_CORS_ORIGIN', '').strip()
REMOTE_API_TOKEN = os.environ.get('ARCHWEBUI_API_TOKEN', '').strip()

install_state = {'percentage': 0, 'message': 'Awaiting mobile configuration matrix...', 'status': 'idle'}
ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
DEVICE_RE = re.compile(r'^/dev/[a-zA-Z0-9._/-]+$')
USERNAME_RE = re.compile(r'^[a-z_][a-z0-9_-]*$')
HOSTNAME_RE = re.compile(r'^[a-zA-Z0-9](?:[a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?$')


def update_state(pct, msg, status):
    global install_state
    if status not in ['idle', 'error'] and pct < install_state['percentage']:
        pct = install_state['percentage']
    install_state = {'percentage': pct, 'message': msg, 'status': status}
    try:
        with open(STATE_FILE, 'w', encoding='utf-8') as state_file:
            state_file.write(f'{pct}|{msg}|{status}\n')
    except Exception:
        pass


def get_tail_logs(lines=150):
    try:
        with open(LOG_FILE, 'r', encoding='utf-8') as log_file:
            return [line.strip() for line in log_file.readlines()[-lines:] if line.strip()]
    except Exception:
        return []


def safe_run(cmd, append_log=True, check=False):
    with open(LOG_FILE, 'a', encoding='utf-8') as log_file:
        stdout = log_file if append_log else subprocess.DEVNULL
        stderr = log_file if append_log else subprocess.DEVNULL
        return subprocess.run(cmd, stdout=stdout, stderr=stderr, check=check)


def read_stdout(cmd):
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
    return result.stdout.strip()


def discover_disk_devices():
    devices = set()
    try:
        lsblk_out = read_stdout(['lsblk', '-dn', '-o', 'NAME,TYPE'])
        for row in lsblk_out.splitlines():
            parts = row.split()
            if len(parts) == 2 and parts[1] == 'disk':
                devices.add(f'/dev/{parts[0]}')
    except Exception:
        return set()
    return devices


def validate_device_path(device):
    if not isinstance(device, str) or not DEVICE_RE.match(device):
        raise ValueError('Invalid device path format.')
    allowed = discover_disk_devices()
    if not allowed:
        raise ValueError('Unable to validate available block devices on host.')
    if device not in allowed:
        raise ValueError(f'Device {device} is not an available block disk.')


def validate_payload(config, creds):
    if not isinstance(config, dict):
        raise ValueError('config must be a JSON object.')
    if not isinstance(creds, dict):
        raise ValueError('creds must be a JSON object.')

    disk_cfg = config.get('disk_config', {}) or {}
    config_type = disk_cfg.get('config_type')
    disk_mods = disk_cfg.get('device_modifications', [])

    if config_type == 'pre_mounted_config':
        mountpoint = disk_cfg.get('mountpoint')
        if not isinstance(mountpoint, str) or not mountpoint.startswith('/'):
            raise ValueError('disk_config.mountpoint must be an absolute path for pre_mounted_config.')
    else:
        for mod in disk_mods:
            device = mod.get('device')
            validate_device_path(device)

    users = creds.get('users', [])
    root_password = creds.get('!root-password') or creds.get('root_enc_password')
    if not users and not root_password:
        raise ValueError('Provide creds.users or a root password in creds.')

    if users:
        username = users[0].get('username', '')
        if not USERNAME_RE.match(username):
            raise ValueError('Primary username has an invalid format.')

    hostname = config.get('hostname', 'archlinux')
    if hostname and not HOSTNAME_RE.match(hostname):
        raise ValueError('Hostname format is invalid.')


def get_system_telemetry():
    telemetry = {'cpu': 'x86_64 Architecture', 'boot_mode': 'BIOS', 'hardware': {}}
    try:
        cpu_out = read_stdout(['lscpu'])
        for line in cpu_out.splitlines():
            if line.strip().startswith('Model name:'):
                telemetry['cpu'] = line.split(':', 1)[1].strip()
                break
    except Exception:
        pass

    telemetry['boot_mode'] = 'UEFI' if os.path.exists('/sys/firmware/efi/efivars') else 'BIOS'
    try:
        lsblk_out = read_stdout(['lsblk', '-b', '-J', '-o', 'NAME,SIZE,TYPE'])
        telemetry['hardware'] = json.loads(lsblk_out) if lsblk_out else {}
    except Exception:
        pass
    return telemetry


def cleanup_for_install(device_modifications, config_type):
    if config_type == 'pre_mounted_config':
        return

    if not device_modifications:
        return

    safe_run(['pkill', '-9', 'pacman'])
    safe_run(['pkill', '-9', 'pacstrap'])
    safe_run(['swapoff', '-a'])
    safe_run(['umount', '-l', '-R', '/mnt/archinstall'])
    safe_run(['umount', '-l', '-R', '/mnt'])

    for mod in device_modifications:
        dev = mod.get('device')
        wipe = bool(mod.get('wipe', False))
        validate_device_path(dev)
        if wipe:
            safe_run(['wipefs', '-af', dev])
            safe_run(['sgdisk', '--zap-all', dev])
            safe_run(['partprobe', dev])

    safe_run(['udevadm', 'settle'])


def run_archinstall():
    update_state(2, 'Clearing disk locks and orphaned mounts...', 'running')

    try:
        with open(CONFIG_PATH, 'r', encoding='utf-8') as cfg_file:
            config = json.load(cfg_file)
    except Exception as exc:
        update_state(99, f'Invalid runtime config: {exc}', 'error')
        return

    device_modifications = []
    config_type = None
    try:
        disk_cfg = config.get('disk_config', {}) or {}
        config_type = disk_cfg.get('config_type')
        device_modifications = [
            mod
            for mod in disk_cfg.get('device_modifications', [])
            if mod.get('device')
        ]
        cleanup_for_install(device_modifications, config_type)
    except Exception as exc:
        update_state(99, f'Disk preflight failed: {exc}', 'error')
        return

    time.sleep(1)
    update_state(5, 'Synchronizing pacman repositories...', 'running')
    safe_run(['pacman', '-Sy', '--noconfirm'])

    cmd = ['archinstall', '--config', CONFIG_PATH, '--creds', CREDS_PATH, '--silent']
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    indicators = [
        ('writing partition', 10, 14, 'Writing partition tables...'),
        ('formatting', 15, 19, 'Formatting storage block partitions...'),
        ('mounting', 20, 24, 'Mounting target filesystems...'),
        ('waiting for time sync', 25, 29, 'Synchronizing network precision NTP clocks...'),
        ('installing packages to /mnt', 30, 69, 'Bootstrapping Arch Linux base environment...'),
        ('installing bootloader', 70, 74, 'Installing system bootloader...'),
        ('configuring bootloader', 75, 79, 'Injecting system core bootloader configuration...'),
        ('creating user', 80, 84, 'Configuring system users...'),
        ('enabling service', 85, 89, 'Enabling targeted network running services...'),
        ('setting timezone', 90, 94, 'Applying localization and timezone rules...'),
        ('creating initramfs', 95, 99, 'Generating initial ramdisk environment...'),
        ('installation completed', 100, 100, 'Build Successful! Node is safe for hardware restart cycles.'),
    ]

    current_pct = 5.0
    current_ceiling = 9.0

    with open(LOG_FILE, 'a', encoding='utf-8') as master_log:
        for raw_line in process.stdout:
            line_clean = ansi_escape.sub('', raw_line.rstrip())
            lower_line = line_clean.lower()

            if 'archinstall.lib.exceptions' in lower_line or 'requires a uefi system' in lower_line or 'fatal error:' in lower_line:
                update_state(99, f'Fatal Error: {line_clean}', 'error')
                process.kill()
                break

            hit_checkpoint = False
            for key, b_pct, m_pct, msg in indicators:
                if key in lower_line and current_pct < b_pct:
                    current_pct = float(b_pct)
                    current_ceiling = float(m_pct)
                    update_state(int(current_pct), msg, 'running' if b_pct < 100 else 'completed')
                    hit_checkpoint = True
                    break

            is_spam = False
            if ' [' in line_clean and ']' in line_clean and ('%' in line_clean or '#' in line_clean or '=' in line_clean or '-' in line_clean):
                is_spam = True
            if 'downloading...' in lower_line or 'Total (' in line_clean or line_clean.strip().endswith('%'):
                is_spam = True

            if not is_spam and line_clean.strip():
                if not hit_checkpoint and current_pct < current_ceiling:
                    current_pct += 0.1
                    if current_pct > current_ceiling:
                        current_pct = current_ceiling
                    if int(current_pct) > install_state['percentage']:
                        update_state(int(current_pct), install_state['message'], 'running')

                master_log.write(f'[ARCHINSTALL] {line_clean}\n')
                master_log.flush()

    process.wait()
    if process.returncode != 0 and install_state['status'] not in ['completed', 'error']:
        update_state(99, f'Archinstall crashed. Exit Code {process.returncode}. See logs.', 'error')


def request_has_valid_token(headers):
    if not REMOTE_API_TOKEN:
        return True
    return headers.get('X-ArchWebUI-Token', '') == REMOTE_API_TOKEN


class APIHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def end_headers(self):
        if ALLOWED_ORIGIN:
            self.send_header('Access-Control-Allow-Origin', ALLOWED_ORIGIN)
            self.send_header('Vary', 'Origin')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type, X-ArchWebUI-Token')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(200, 'ok')
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
                    payload['logs'] = get_tail_logs()
                    self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode('utf-8'))
                    self.wfile.flush()
                    if install_state['status'] in ['completed', 'error']:
                        break
                    time.sleep(1)
            except Exception:
                pass
        else:
            return super().do_GET()

    def do_POST(self):
        path = urlparse(self.path).path

        if not request_has_valid_token(self.headers):
            self.send_response(403)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': False, 'error': 'Invalid API token'}).encode('utf-8'))
            return

        if path == '/api/submit':
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if length <= 0:
                    raise ValueError('Empty request body.')
                post_data = json.loads(self.rfile.read(length))
                config_payload = post_data.get('config', {})
                creds_payload = post_data.get('creds', {})
                validate_payload(config_payload, creds_payload)

                with open(CONFIG_PATH, 'w', encoding='utf-8') as cfg_file:
                    json.dump(config_payload, cfg_file, indent=4)
                with open(CREDS_PATH, 'w', encoding='utf-8') as creds_file:
                    json.dump(creds_payload, creds_file, indent=4)
            except Exception as exc:
                self.send_response(400)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'success': False, 'error': str(exc)}).encode('utf-8'))
                return

            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': True}).encode('utf-8'))
            threading.Thread(target=run_archinstall, daemon=True).start()

        elif path == '/api/reboot':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'success': True}).encode('utf-8'))
            threading.Thread(target=lambda: (time.sleep(1), safe_run(['systemctl', 'reboot'])), daemon=True).start()


class ReuseServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


if __name__ == '__main__':
    update_state(0, 'Awaiting WebUI configuration...', 'idle')
    with ReuseServer(('', PORT), APIHandler) as httpd:
        httpd.serve_forever()
