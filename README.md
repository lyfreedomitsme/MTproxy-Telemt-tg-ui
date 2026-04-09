# MTproxy-Telemt-tg-ui

MTProxy management interface with terminal UI. Built on the [Telemt](https://github.com/telemt/telemt) engine — adds multi-user support, DPI resistance, SNI masking, and an automated Mikrotik cascade tunnel.

---

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telmet-tg-ui/master/install.sh)
```
*Installs Docker, dependencies, and registers `tg-ui` as a global command.*

---

## Quick Update (Preserve Settings)

If you already have `tg-ui` installed and want to update to the latest version **without losing your users, secrets, or IP settings**, run:

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telmet-tg-ui/master/install.sh) --update
```
*Alternatively, use the **Update Panel** option in the interactive menu.*

---

## Usage

```bash
tg-ui              Open interactive menu
tg-ui start        Start / restart proxy
tg-ui stop         Stop proxy service
tg-ui link         Show all connection links
tg-ui qr           Generate QR codes for links
tg-ui update       Update management tool
tg-ui help         Show this help message
```

---

## Key Features

- **Multi-user Accounting**: Each user gets a unique secret and optional IP connection limit.
- **Mikrotik Cascade**: Automated WireGuard tunnel setup between Ubuntu and Mikrotik to bypass NAT and preserve real client IPs for accounting.
- **Manual IP Selection**: Choose which server IP to use for links/QR codes if your server has multiple interfaces.
- **Anti-DPI Hardening**: Pre-configured with SNI masking (Fake TLS) and active probing resistance.
- **Performance**: Written for speed with RAM-only configuration files (`/dev/shm`).
- **Resilience**: Automatic autostart after server reboots via `@reboot` cron.

---

## Advanced: Mikrotik Cascade

If your server sits behind a Mikrotik router, standard NAT will make all users appear as the router's IP, breaking connection limits. 

**Solution**: Go to `5) Advanced security settings` -> `6) Mikrotik Cascade`. 
1. The script will automatically configure a WireGuard tunnel (`wg-telemt`).
2. It generates a `.txt` file with exact commands to paste into your Mikrotik terminal.
3. Once active, all links will automatically use your Mikrotik's public IP.

---

## Security

- Container runs as a non-root user with a read-only filesystem.
- Secrets are generated using `openssl rand`.
- Configuration database and environment files are protected with strict permissions.

---

## Clean Uninstall

To remove the project and all associated data:

```bash
docker rm -f telemt-proxy; \
rm -f /usr/local/bin/tg-ui; \
rm -f ~/.telemt-ui-config.env; \
crontab -l | grep -v "tg-ui" | crontab -
```

---

## License

[TELEMT Public License 3](LICENSE_TELEMT.txt)
