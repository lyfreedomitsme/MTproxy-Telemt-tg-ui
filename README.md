# MTproxy-Telemt-tg-ui

MTProxy management interface with terminal UI. Built on the [Telemt](https://github.com/telemt/telemt) engine — adds multi-user support, DPI resistance, SNI masking, and an automated Mikrotik cascade tunnel.

---

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telemt-tg-ui/master/install.sh)
```
*Installs Docker, dependencies (`git`, `xxd`, `qrencode`), and registers `tg-ui` as a global command.*

---

## Quick Update (Preserve Settings)

To update to the latest version **without losing users, secrets, or settings**, run:

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telmet-tg-ui/master/install.sh) --update
```
*Alternatively, use the **Update Panel** option (`9`) in the interactive menu.*

---

## Usage

```bash
tg-ui              Open interactive menu
tg-ui start        Start / restart proxy
tg-ui stop         Stop proxy service
tg-ui link         Show all connection links
tg-ui qr           Generate QR codes for links
tg-ui logs         Tail proxy logs (Ctrl+C to stop)
tg-ui update       Update management tool
tg-ui help         Show this help message
```

---

## Key Features

- **Multi-user Accounting**: Each user gets a unique secret and an optional IP connection limit.
- **Active Masking (Fake TLS / SNI)**: Disguises traffic as HTTPS using a configurable domain. Can be enabled or disabled per deployment.
- **Mikrotik Cascade**: Automated WireGuard tunnel setup between Ubuntu and Mikrotik to bypass NAT and pass real client IPs for per-user accounting.
- **Ad Channel Tag**: Promote a Telegram channel via `@MTProxybot` by setting an `AD_TAG`.
- **RAM-only Config**: Proxy configuration is held in `/dev/shm` — never touches disk at runtime.
- **Resilience**: Automatic autostart after server reboots via `@reboot` cron.
- **QR Codes**: Built-in QR code generation for connection links (`qrencode` required).

---

## Advanced: Mikrotik Cascade

When a server sits behind a Mikrotik router, all clients appear with the router's IP, which breaks per-user connection limits.

**Solution**: Go to `5) Advanced security settings` → `6) Mikrotik Cascade`.
1. The script configures a WireGuard tunnel (`wg-telemt`) on the Ubuntu server.
2. A `.txt` file is generated with exact commands to paste into the Mikrotik terminal.
3. Once active, connection links automatically switch to the Mikrotik's public IP.

> **Note on IP Limits with Cascade**: Connection limits are enforced at the proxy level based on the source IP the proxy receives. When using the WireGuard cascade, the proxy sees real client IPs (not the Mikrotik's IP), so per-user limits work correctly.

---

## Security

- Container runs as a non-root user (`65534:65534`) with a read-only filesystem.
- Secrets are generated using `openssl rand` (16 bytes = 32 hex chars).
- Environment files are protected with strict permissions (`644`).
- Supports `PROXY_PROTOCOL` mode to receive real client IPs from upstream load balancers.

---

## Clean Uninstall

```bash
docker rm -f telemt-proxy; \
sudo rm -f /usr/local/bin/tg-ui; \
rm -f ~/.telemt-ui-config.env; \
crontab -l | grep -v "tg-ui" | crontab -
```

---

## License

[TELEMT Public License 3](LICENSE_TELEMT.txt)
