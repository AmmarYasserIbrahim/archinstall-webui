# ⚡ Archinstall WebUI

A decentralized, zero-dependency remote configuration wizard for Arch Linux. This project transforms the standard Arch Linux Live ISO environment into a temporary standalone web gateway, allowing you to configure, partition, and install Arch Linux directly from your mobile device or any browser on the same network layout.

```text
█████╗ ██████╗  ██████╗██╗  ██╗██╗███╗   ██╗███████╗████████╗ █████╗ ██╗     ██╗
██╔══██╗██╔══██╗██╔════╝██║  ██║██║████╗  ██║██╔════╝╚══██╔══╝██╔══██╗██║     ██║
███████║██████╔╝██║     ███████║██║██╔██╗ ██║███████╗   ██║   ███████║██║     ██║
██╔══██║██╔══██╗██║     ██╔══██║██║██║╚██╗██║╚════██║   ██║   ██╔══██║██║     ██║
██║  ██║██║  ██║╚██████╗██║  ██║██║██║ ╚████║███████║   ██║   ██║  ██║███████╗███████╗
╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚══════╝
                            ██╗    ██╗███████╗██████╗ ██╗   ██╗██╗                  
                            ██║    ██║██╔════╝██╔══██╗██║   ██║██║                  
                            ██║ █╗ ██║█████╗  ██████╔╝██║   ██║██║                  
                            ██║███╗██║██╔══╝  ██╔══██╗██║   ██║██║                  
                            ╚███╔███╔╝███████╗██████╔╝╚██████╔╝██║                  
                             ╚══╝╚══╝ ╚══════╝╚═════╝  ╚═════╝ ╚═╝
```

## 🚀 Key Architectural Advantages

* **Zero Central Server Overhead:** Completely independent. The target installation machine spawns its own ephemeral backend web services natively.
* **Instant Python Engine Deployment:** Eliminates Node.js and NPM completely from the runtime bootstrap path. Spawns milliseconds after terminal execution using Python 3 primitives already present in the official ISO.
* **Official Core Reliability:** Generates fully verified structural JSON templates consumable directly by the native `archinstall` libraries.
* **Secure Cloudless Tunnels:** Establishes encrypted reverse port forwarding tunnels via raw SSH hooks, instantly punching through local area network firewalls without external software layers.

---

## 📲 Quick Start Deployment

Boot your target server or virtual machine into an official **Arch Linux Live ISO** image and run the following automated micro-command:

    curl -sL is.gd/archui | bash

*(Note: Replace `is.gd/archui` with your own short URL generated from your raw launch.sh path)*

### The Execution Process
1. The script updates package markers and allocations.
2. The runtime engine components are fetched directly from your GitHub storage directory.
3. An internal Python API socket opens on port 5000.
4. A secure public HTTPS link maps to the local terminal workspace.
5. A text-rendered interactive QR code locks onto your monitor screen.
6. Scan the code with your smartphone browser, configure your partitions, desktop profiles, user accounts, and execute the background build!

---

## 📝 License

Distributed under the MIT License. See `LICENSE` for more detailed information parameters.
