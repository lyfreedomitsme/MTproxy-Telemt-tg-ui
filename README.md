# MTproxy-Telemt-tg-ui

MTProxy management interface with terminal UI. Built on the [Telemt](https://github.com/telemt/telemt) engine — adds multi-user support, DPI resistance, SNI masking, and a clean interactive menu accessible from anywhere in your terminal.

---

## Quick Install

```bash
bash <(curl -sL https://raw.githubusercontent.com/lyfreedomitsme/MTproxy-Telemt-tg-ui/master/install.sh)
```

Installs Docker, Docker Compose, builds the proxy image, and registers `tg-ui` as a global command.

---

## Manual Install

```bash
git clone https://github.com/lyfreedomitsme/MTproxy-Telemt-tg-ui.git
cd MTproxy-Telemt-tg-ui
chmod +x install.sh tg-ui.sh
./install.sh
```

After installation, run `tg-ui` from any directory.

---

## Usage

```
tg-ui              Open interactive menu
tg-ui start        Start / restart proxy
tg-ui stop         Stop proxy service
tg-ui link         Print all connection links
tg-ui qr           Generate QR codes for all links
tg-ui help         Show this reference
```

---

## Menu

```
  MTProxy-Telemt-tg-ui  |  Settings
  status  ● running  (port 8443)
  ──────────────────────────────────────────────────────
  1)  Restart proxy
  2)  Change Fake TLS  (google.com)
  3)  Change port  (8443)
  4)  Manage links & users
  5)  Advanced security settings
  6)  Update proxy image
  7)  Stop proxy
  8)  View logs
  0)  Exit
```

---

## Features

**Multi-user links**
Each user gets an independent secret and optional IP limit. Admin and public links are created automatically on first run.

**Fake TLS / SNI masking**
Traffic is disguised as HTTPS to a configurable trusted domain (Google, Apple, Cloudflare, or custom). Active masking mode responds to probes like a real web server.

**RAM-only config**
`config.toml` is written to `/dev/shm` and never touches the disk. Reconstructed automatically on every start and after reboot.

**Reboot persistence**
A `@reboot` cron job restarts the proxy automatically after system reboot with the last saved configuration.

**Smart port selection**
If the requested port is busy, the script scans a list of CDN-compatible ports (443, 2053, 2083, 2087, 2096, 8443, 9443) and picks the first available one.

**Anti-DPI hardening**
Runs with `use_middle_proxy = true` and elevated `ulimits` for better resistance against deep packet inspection.

**Secret rotation**
All user secrets can be rotated at once from the security menu.

**QR codes**
`tg-ui qr` renders scannable QR codes directly in the terminal for each connection link.

---

## Advanced: Cascading & Tunneling (Mikrotik / HAProxy)

If you place this server behind another router or VPN (like Mikrotik) using standard NAT/Masquerading, the proxy will see the router's IP instead of the original clients' IPs. This completely breaks per-user IP connection limits. 

To deploy a cascade properly, choose one of the following methods depending on your architecture. (It is usually best to set `PORT=443` in `tg-ui` if you intend to run your frontends on port 443).

### Scenario A: Hardware Router (Mikrotik) over WireGuard
If your server sits behind a Mikrotik routing traffic via a WireGuard/IPIP tunnel, **do not use Proxy Protocol**. Instead, configure the routing natively so the real IP is preserved on a packet level:

1. **On Mikrotik (Disable Masquerade for MTProxy):**
   Add an exclusion rule at the very top of your NAT list to prevent masquerading specifically for the proxy port (e.g., `8443`).
   ```routeros
   /ip firewall nat add action=accept chain=srcnat protocol=tcp dst-port=8443 out-interface=wg0 place-before=0
   ```
2. **On Ubuntu (Policy-Based Routing):**
   Force the Ubuntu server to reply to incoming tunnel packets back through the tunnel, making masquerade unnecessary.
   ```bash
   echo "200 wg_table" >> /etc/iproute2/rt_tables
   ip rule add from <UBUNTU_WG_IP> table wg_table
   ip route add default via <MIKROTIK_WG_IP> dev wg0 table wg_table
   ```

### Scenario B: Linux VPS Cascading (HAProxy / Xray)
If you use a Linux VPS in another country to forward traffic, standard port forwarding will destroy the client IP. Instead, use the built-in PROXY Protocol feature.

1. **On Ubuntu (Configure \`tg-ui\`):**
   Go to `5) Advanced security settings` -> `4) PROXY Protocol` and turn it ON. Enter your frontend VPS IP to trust its headers.
   *Note: Directly connecting to the server will no longer work; it will strictly expect HAProxy standard headers.*
2. **On your Frontend server (HAProxy config):**
   Configure HAProxy to append the `send-proxy` directive when forwarding traffic to Ubuntu.
   ```haproxy
   listen proxy_in
       bind *:443
       mode tcp
       server telemt-backend <UBUNTU_IP>:8443 send-proxy
   ```

---

## Security

- Container runs as a non-root user with a read-only filesystem and dropped Linux capabilities
- Local database and `.env` files are protected with `chmod 600`
- Secrets are generated with `openssl rand` (falls back to `/dev/urandom`)
- No sensitive data is stored on disk between restarts

---

## Reset Configuration

```bash
rm ~/.telemt-ui-config.env
```

Then run `tg-ui` or `./install.sh` to start fresh.

---

## Clean Uninstall

To delete all data associated with a project, run the following command:

```bash
docker rm -f telemt-proxy 2>/dev/null; \
rm -rf ~/telemt-plus; \
rm -f /usr/local/bin/tg-ui; \
rm -f ~/.telemt-ui-config.env; \
rm -f /dev/shm/telemt-tgui-config.toml; \
crontab -l 2>/dev/null | grep -v "tg-ui" | crontab -
```

---

## Credits

Core proxy engine — [Telemt](https://github.com/telemt/telemt)  
UI & automation — [lyfreedomitsme](https://github.com/lyfreedomitsme)

---

## License

[TELEMT Public License 3](LICENSE_TELEMT.txt)
