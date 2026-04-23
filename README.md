# IPv64 DynDNS Updater

Automatic IPv6 DynDNS update for [IPv64.net](https://ipv64.net) on Raspberry Pi / Ubuntu Linux.

No external IP-check service needed — the public IPv6 address is read directly from the network interface and compared against the live DNS entry via `dig`.

---

## Features

- 📡 **No webcheck** — reads IPv6 directly from interface
- 🔍 **DNS comparison** — queries IPv64 nameserver directly, no local DNS caching
- 🏷️ **Event logging** — logs which trigger caused the update (`timer`, `nm-dhcp6-change`, etc.)
- ⚡ **Dual trigger** — NetworkManager dispatcher (instant) + systemd timer (fallback)
- 🔄 **logrotate** — daily rotation, 14 days retention
- 🚀 **One-command install** — interactive install script for new devices

---

## How It Works

```
ISP assigns new IPv6 prefix
        │
        ▼
NetworkManager detects change
        │
        ▼
Dispatcher triggers script immediately
        │                    │
        ▼                    ▼
  Read IPv6 from         systemd Timer
  interface (eth0)       (every 5 min,
        │                 as fallback)
        ▼
  Query DNS entry
  @ns1.ipv64.net
        │
   ┌────┴────┐
   │ Match?  │
   └────┬────┘
     No │
        ▼
  Send update to
  ipv64.net API
        │
        ▼
  Log result to
  /var/log/ipv64-update.log
```

---

## Requirements

- Raspberry Pi / Ubuntu Linux
- NetworkManager
- `curl`, `dnsutils` (installed automatically by install script)
- IPv64.net account with a domain and update token

---

## Quick Install

```bash
wget https://raw.githubusercontent.com/<your-username>/<your-repo>/main/install-ipv64.sh
chmod +x install-ipv64.sh
sudo ./install-ipv64.sh
```

The script will ask for:

| Input | Example |
|---|---|
| Domain | `myhost.ipv64.de` |
| Update Token | From your IPv64.net dashboard |
| Interface | `eth0` or `wlan0` |

---

## Files

| File | Description |
|---|---|
| `install-ipv64.sh` | Interactive install script |
| `ipv64-update.sh` | Main update script |

After installation the following files are created on the system:

| Path | Description |
|---|---|
| `/usr/local/bin/ipv64-update.sh` | Update script |
| `/etc/systemd/system/ipv64-update.service` | systemd service (oneshot) |
| `/etc/systemd/system/ipv64-update.timer` | systemd timer (every 5 min) |
| `/etc/NetworkManager/dispatcher.d/99-ipv64-update` | NM dispatcher |
| `/etc/logrotate.d/ipv64-update` | logrotate config |
| `/var/log/ipv64-update.log` | Log file |

---

## Log Examples

```
[2026-04-24 01:00:32] [timer] INFO: Keine Änderung - DNS stimmt überein (2003:eb:5726:b500:...)
[2026-04-24 01:14:17] [nm-dhcp6-change] SUCCESS: DNS aktualisiert 2003:eb:5726:... → 2003:eb:9999:...
[2026-04-24 01:15:00] [timer] INFO: Keine Änderung - DNS stimmt überein (2003:eb:9999:...)
[2026-04-24 02:00:01] [timer] ERROR: Update fehlgeschlagen. Response: ...
```

---

## Useful Commands

```bash
# Watch live log
tail -f /var/log/ipv64-update.log

# Show only errors
grep ERROR /var/log/ipv64-update.log

# Check timer status & next run
systemctl list-timers ipv64-update.timer

# Trigger manual run
sudo /usr/local/bin/ipv64-update.sh manual

# Check what IP the script would use
ip -6 addr show eth0 scope global \
  | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
  | grep -v '^f[cd]' \
  | head -1

# Check current DNS entry at IPv64 nameserver
dig AAAA <your-domain> +short @ns1.ipv64.net

# View systemd journal for this service
journalctl -u ipv64-update.service -n 20
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: Konnte keine öffentliche IPv6 ermitteln` | No IPv6 on interface / wrong interface | Check `ip -6 addr show eth0` |
| `ERROR: Update fehlgeschlagen` | Wrong token / IPv64.net unreachable | Verify token, check `curl ipv64.net` |
| Timer not running after reboot | Timer not enabled | `sudo systemctl enable ipv64-update.timer` |
| Script not found | Missing permissions | `sudo chmod +x /usr/local/bin/ipv64-update.sh` |
| `dig` not found | Package missing | `sudo apt install dnsutils` |
| Dispatcher not firing | File not created | Check `ls /etc/NetworkManager/dispatcher.d/` |

### IPv6 Address Types

The Raspberry Pi may have multiple global IPv6 addresses:

| Prefix | Type | Used for |
|---|---|---|
| `2003:...` / `2001:...` | Public (ISP) | ✅ This is the DynDNS address |
| `fdXX:...` / `fcXX:...` | ULA (private, not routable) | ❌ Filtered out automatically |
| `fe80:...` | Link-local | ❌ Not global scope |

---

## Security Notes

> ⚠️ **Never commit your update token to Git.**
>
> The token in `ipv64-update.sh` grants full control over your DNS entries.
> Either add the script to `.gitignore` or replace the token with a placeholder before committing.

Recommended `.gitignore`:
```
ipv64-update.sh
```

---

## License

MIT

---

## Resources

- [IPv64.net Dashboard](https://ipv64.net)
- [IPv64.net API Documentation](https://ipv64.net/dyndns_updater_api)
- [IPv64.net DynDNS Helper](https://ipv64.net/dyndns_helper)
