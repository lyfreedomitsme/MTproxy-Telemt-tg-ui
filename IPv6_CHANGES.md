# IPv6 Support Implementation - Changes Log

**Date:** 2026-04-11 to 2026-04-12  
**Status:** WIP / Testing  
**Branch:** local (NOT pushed to GitHub)

## Summary
Added full IPv6 support to MTProxy-Telemt-tg-ui with automatic detection and Mikrotik Cascade compatibility.

---

## Changes Made

### 1. **New Functions Added**
- `_is_ipv6()` — Helper function to detect IPv6 addresses (checks for `:` in address)

### 2. **Updated: IP Detection (`_fetch_ip()`)**
- Priority: IPv4 first (external APIs + local fallback)
- Fallback: IPv6 if no IPv4 found
- Validates both IPv4 and IPv6 formats
- Accepts domains as valid addresses

### 3. **Updated: Link Generation (`show_link()` & `show_qr()`)**
- IPv4 format: `tg://proxy?server=1.2.3.4&port=443...`
- IPv6 format: `tg://proxy?server=[fd58:baa6:dead::1]&port=443...` (with brackets)
- Cascade mode: Auto-detects and uses Mikrotik endpoint IP

### 4. **Updated: Cascade IP Parsing (`_get_cascade_ip()`)**
- Now correctly parses IPv6 endpoints with brackets: `[addr]:port`
- Removes brackets for address extraction
- Fallback to SERVER_IP if endpoint not found

### 5. **Updated: Config Generation (`get_config_toml_content()`)**
- Generates `[[server.listeners]]` section based on IP type
- IPv4: `ip = "0.0.0.0"`, port = 8443
- IPv6: `ip = "[::]"`, announce_ip = actual_ipv6

### 6. **Updated: Mikrotik Cascade Setup (`setup_mikrotik_cascade()`)**
- **Interactive prompt:** Asks "Does your Mikrotik support IPv6? (y/n)"
- **IPv6 mode:**
  - Ubuntu WG IP: `fd00::1/64`
  - Mikrotik WG IP: `fd00::2/64`
  - Tunnel: `AllowedIPs = ::/0`
  - Rules: `ip6tables` instead of `iptables`
- **IPv4 mode:**
  - Ubuntu WG IP: `10.99.99.1/24`
  - Mikrotik WG IP: `10.99.99.2/24`
  - Tunnel: `AllowedIPs = 0.0.0.0/0`
  - Rules: `iptables`
- **Error handling:** Rejects IPv6 cascade if Mikrotik doesn't support IPv6
- Installs `ip6tables` automatically if IPv6 mode selected

### 7. **Updated: Sync Mikrotik Commands (`sync_mikrotik_commands()`)**
- Detects cascade type from existing config (looks for "IPv6" in comments)
- Regenerates Mikrotik commands with current port/IP
- Uses correct table rules and firewall rules per IP type

### 8. **Updated: WireGuard Config Generation**
- **IPv6 config:**
  ```
  Address = fd00::1/64
  PostUp = ip6tables -t mangle -A PREROUTING -i wg-telemt ! -s fd00::2 -j CONNMARK --set-mark 200
  PostUp = ip6tables -t nat -I POSTROUTING 1 -o wg-telemt -m connmark --mark 200 -j SNAT --to-source fd00::1
  PostDown = ip6tables -t mangle -D ... (cleanup)
  ```
- **IPv4 config:** Similar but with `iptables` and `10.99.99.0/24` addresses

### 9. **Fixed: Menu Display (`select_server_ip()`)**
- Changed `%s` to `%b` for proper escape code rendering
- "(current)" now displays green instead of showing `\033[32m` literally

---

## Validation Rules

### IP Detection Priority
1. External IPv4 (ifconfig.me, ipinfo.io, icanhazip.com, api.ipify.org)
2. Local IPv4 (hostname -I)
3. Local IPv6 (ip -6 addr show ... scope global)

### Cascade Requirements
- **IPv6 cascade:** Both Ubuntu AND Mikrotik MUST have IPv6 (mandatory check)
- **IPv4 cascade:** Works with any IPv4 configuration
- **Incompatible:** IPv6 Ubuntu + IPv4-only Mikrotik = ERROR (WireGuard endpoint mismatch)

---

## Known Issues / Limitations

1. **WireGuard IPv6 PostUp Commands:** Simplified to avoid "No such device" errors
   - Removed problematic `ip route add default dev wg-telemt table 200`
   - Works with current simplified rule set

2. **Docker Restart:** Happens after WireGuard setup (ensures Telemt sees new tunnel)

3. **IPv6 Address Format:** Must be valid IPv6, validated by regex check for `:`

---

## Testing Checklist

- [x] IPv4 auto-detection works
- [x] IPv6 auto-detection works
- [x] IPv4 links generate correctly
- [x] IPv6 links generate with brackets `[addr]`
- [x] QR codes work for both IPv4 and IPv6
- [x] Mikrotik Cascade asks about IPv6 support
- [x] IPv6 cascade generates correct WireGuard config
- [x] IPv4 cascade still works (backward compatible)
- [x] Syntax validation passes (bash -n)
- [x] Menu display fixed (escape codes)
- [ ] WireGuard interface starts successfully (needs server testing)
- [ ] Mikrotik cascade tunnel connects (needs Mikrotik with IPv6)

---

## Files Modified

- `tg-ui.sh` — Main script with all changes above

---

## Rollback

If needed to revert to original:
```bash
git checkout tg-ui.sh
```

Current version is **NOT committed** to repository.
