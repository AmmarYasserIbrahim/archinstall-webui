# Archinstall WebUI 🚀

A gorgeous, mobile-friendly remote dashboard for the official Arch Linux installer.

Building an Arch Linux system usually means staring at a text-based installer in a terminal. Archinstall WebUI transforms that experience by launching a lightweight server directly from your Arch Live USB, creating a secure temporary tunnel, and generating a QR code. Scan the code with your phone and configure your entire Arch Linux installation from a beautiful web interface.

## ✨ Key Features

- 📱 **Mobile-First Dashboard** — Configure language, disk partitions, desktop profiles, and user credentials from any web browser.
- 🔗 **Zero-Setup Tunneling** — Automatically exposes the local server using a secure `localhost.run` tunnel.
- 🧠 **Smart Partitioning Engine** — Handles sector alignment, GPT header buffers, and BTRFS subvolume creation automatically.
- ⚡ **Real-Time Progress Sync** — Installation progress updates live on both your phone and monitor.
- 🎨 **Complete Customization** — Select desktop environments, window managers, kernels, audio servers, and additional packages.

---

## 🚀 Quick Start

### 1. Boot the Arch Linux Live ISO

Start your computer using the official Arch Linux installation media.

### 2. Connect to the Internet

Use Ethernet or connect to Wi-Fi:

```bash
iwctl
```

### 3. Launch Archinstall WebUI

Run:

```bash
curl -sL is.gd/archinstall_webui | bash
```

### 4. Scan the QR Code

After the script finishes downloading and starting the services, a QR code will appear in your terminal.

Scan it with your phone's camera.

### 5. Configure and Install

Open the dashboard, configure your installation preferences, and click **Start Installation**.

Your computer will immediately begin partitioning disks and installing Arch Linux.

---

## 🛠️ How It Works

The project consists of three lightweight components:

### `install.sh`

The deployment wrapper that:

- Installs required dependencies (such as `qrencode`)
- Downloads project assets
- Starts the backend server
- Creates the SSH reverse tunnel

### `server.py`

The Python backend that:

- Detects system hardware
- Processes WebUI requests
- Generates a validated Archinstall configuration
- Executes the official `archinstall` engine

### `index.html`

A single-file frontend built with Tailwind CSS that provides:

- Interactive installation dashboard
- Live validation
- Partition sizing calculations
- Responsive mobile interface

---

## ⚠️ Troubleshooting

### Tunnel Failed / LAN Mode Activated

If the SSH tunnel is blocked or times out, the application automatically falls back to LAN mode.

Ensure your phone is connected to the same network as the target computer, then open the displayed address in your browser:

```text
http://192.168.1.50:5000
```

(Your IP address may differ.)

### "Target Is Busy" or Disk Mount Errors

The backend automatically attempts lazy unmounts to clean up drives from previous failed installation attempts.

If disk sizing or partitioning issues persist:

1. Open **Disk Configuration**
2. Click **Restore Default**
3. Generate a safe partition layout automatically

This creates a mathematically valid configuration designed to avoid partition alignment and sizing errors.

---

## 📦 Requirements

- Arch Linux Live ISO
- Internet connection
- Smartphone, tablet, or another device with a web browser

---

### Repository

```bash
git clone https://github.com/AmmarYasserIbrahim/archinstall-webui.git
```

---

## 📝 License

Distributed under the MIT License. See `LICENSE` for more detailed information parameters.
