# MTproxy-Telemt-tg-ui

MTProxy management interface with terminal UI. Built on the [Telemt](https://github.com/telemt/telemt) engine — adds multi-user support, DPI resistance, SNI masking, and an automated Mikrotik cascade tunnel.

**Version: 1.0.0 (STABLE)**

---

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telemt-tg-ui/master/install.sh)
```

Installs Docker, dependencies (`git`, `xxd`, `qrencode`), and registers `tg-ui` as a global command.

---

## Quick Update (Preserve Settings)

To update to the latest version without losing users, secrets, or settings, run:

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telemt-tg-ui/master/install.sh) --update
```

Alternatively, use the **Update Panel** option (`9`) in the interactive menu — it pulls the latest code and restarts automatically.

---

## Usage

```bash
tg-ui              Open interactive menu
tg-ui start        Start / restart proxy
tg-ui stop         Stop proxy service
tg-ui link         Show all connection links
tg-ui qr           Generate QR codes for links
tg-ui logs         Tail proxy logs (Press Enter to stop)
tg-ui update       Update management tool
tg-ui help         Show this help message
```

---

## Key Features

- **Multi-user Accounting**: Each user gets a unique secret and an optional IP connection limit.
- **Active Masking (Fake TLS / SNI)**: Disguises traffic as HTTPS using a configurable domain. Can be enabled or disabled per deployment.
- **Mikrotik Cascade**: Automated WireGuard tunnel setup between Ubuntu and Mikrotik to bypass NAT and pass real client IPs for per-user accounting. Fully tested and stable.
- **Ad Channel Tag**: Promote a Telegram channel via `@MTProxybot` by setting an `AD_TAG`.
- **RAM-only Config**: Proxy configuration is held in `/dev/shm` — never touches disk at runtime.
- **Resilience**: Automatic autostart after server reboots via `@reboot` cron.
- **QR Codes**: Built-in QR code generation for connection links (`qrencode` auto-installed if missing).

---

## Mikrotik Cascade Setup

When a server sits behind a Mikrotik router, all clients appear with the router's IP, which breaks per-user connection limits. This breaks transparent source IP forwarding and per-user IP accounting.

### Solution

Navigate to `Advanced security settings` (menu option 5) and select `Mikrotik Cascade` (option 6).

**Setup Process:**

1. The script configures a WireGuard tunnel (`wg-telemt`) on the Ubuntu server.
2. Firewall rules are automatically configured to allow the WireGuard port (51830/UDP).
3. A text file is generated with exact commands to paste into the Mikrotik terminal.
4. Once the tunnel is active, all client connections route through it with their original source IPs preserved.
5. Connection links and QR codes automatically reflect the Mikrotik's public IP and external port.

**How it works:**

The WireGuard tunnel carries all proxy traffic through the Mikrotik router while preserving the original client IP. This allows the proxy to enforce per-user connection limits based on real source addresses instead of the router's IP.

**Removal:**

Use `Remove Mikrotik Cascade` (menu option 7) to cleanly remove the tunnel. The script will show exact commands to clean up the Mikrotik side as well.

---

## Security

- Container runs as a non-root user (65534:65534) with a read-only filesystem.
- Secrets are generated using `openssl rand` (16 bytes = 32 hex chars).
- Proxy config is stored in RAM only (`/dev/shm`) — never written to disk at runtime.
- User configuration stored locally in `~/.telemt-ui-config.env` with strict permissions.
- All sensitive files excluded from git repository via `.gitignore`.
- Supports `PROXY_PROTOCOL` mode to receive real client IPs from upstream load balancers.

---

## System Requirements

- Ubuntu/Debian-based Linux distribution
- Docker and Docker Compose installed
- `sudo` access for WireGuard cascade setup
- Ports: 8443 (proxy, configurable), 51830/UDP (WireGuard tunnel, if cascade enabled)

---

## Troubleshooting

**WireGuard Interface Failed to Start**

If you see "WireGuard interface failed to start" during cascade setup:
1. Check system status: `systemctl status wg-quick@wg-telemt`
2. View logs: `journalctl -xeu wg-quick@wg-telemt`
3. Ensure your server has WireGuard tools installed: `apt install wireguard`
4. Remove the cascade and retry: use menu option `7) Remove Mikrotik Cascade`

**Port Already in Use**

If the proxy port is in use, change it via menu option `3) Change port` or directly in `~/.telemt-ui-config.env`.

---

## Clean Uninstall

To completely remove MTproxy-Telemt-tg-ui:

```bash
docker rm -f telemt-proxy
sudo rm -f /usr/local/bin/tg-ui
rm -rf ~/MTproxy-Telamt-tg-ui
rm -f ~/.telemt-ui-config.env
crontab -l | grep -v "tg-ui" | crontab -
```

If cascade tunnel was active, also clean up Mikrotik using commands shown during removal.

---

## Release Notes

### Version 1.0.0 (Stable)

**WireGuard Cascade Fixes:**
- Fixed startup failures on fresh servers (RTNETLINK: File exists error)
- Removed dependency on /etc/iproute2/rt_tables file
- Split PostUp/PostDown commands into separate lines for proper wg-quick execution
- Aggressive cleanup on cascade removal prevents rule conflicts on recreation

**Improvements:**
- Enhanced view_logs function to handle both Enter and Ctrl+C for exit
- Install script now supports non-destructive --update flag
- Improved status detection for WireGuard PBR rules
- Better error messages and user feedback

---

## License

[TELEMT Public License 3](LICENSE_TELEMT.txt)
