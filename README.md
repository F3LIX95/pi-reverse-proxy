# pi-reverse-proxy

Raspberry Pi setup for two things that work together:

1. **DDNS** — keeps an IPv64.net AAAA record pointing at the Pi's current public IPv6 address
2. **Nginx reverse proxy** — accepts incoming IPv6 connections and forwards them to IPv4-only backends on the local network (e.g. a Loxone Miniserver)

```
Internet (IPv6)
      │
      ▼
 Fritzbox (port open)
      │
      ▼
Raspberry Pi – nginx
      │   listens on [::]:PORT
      ▼
IPv4-only backend
 e.g. http://loxone.fritz.box:1907
```

---

## Repository layout

```
ddns/
  install.sh      ← interactive install
  update.sh       ← change domain / token / interface
  uninstall.sh    ← remove everything

nginx/
  install.sh      ← interactive install (asks for backend URL + port)
  update.sh       ← change backend or port for an existing proxy
  uninstall.sh    ← remove one proxy or all
```

---

## Part 1 – IPv64 DDNS Updater

Keeps an IPv64.net AAAA record in sync with the Pi's public IPv6 address.

### How it works

```
ISP assigns new IPv6 prefix
        │
        ├─► NetworkManager dispatcher fires immediately
        │
        └─► systemd timer fires every 5 min (fallback)
                │
                ▼
        Read IPv6 from interface (no external webcheck)
                │
                ▼
        Query DNS @ ns1.ipv64.net
                │
           ┌────┴────┐
           │ Match?  │
           └────┬────┘
             No │
                ▼
        POST update to ipv64.net API
                │
                ▼
        Log result → /var/log/ipv64-update.log
```

### Install

```bash
sudo bash ddns/install.sh
```

Asks for:

| Input | Example |
|---|---|
| Domain | `myhost.ipv64.de` |
| Update Token | From your [IPv64.net dashboard](https://ipv64.net) |
| Interface | `eth0` or `wlan0` |

### Update (change domain / token / interface)

```bash
sudo bash ddns/update.sh
```

Patches the running script in-place and performs a test run.

### Uninstall

```bash
sudo bash ddns/uninstall.sh
```

Removes all installed files and systemd units. The log file at `/var/log/ipv64-update.log` is kept.

### Installed files

| Path | Description |
|---|---|
| `/usr/local/bin/ipv64-update.sh` | Main update script |
| `/etc/systemd/system/ipv64-update.service` | systemd oneshot service |
| `/etc/systemd/system/ipv64-update.timer` | Timer (every 5 min, 30 s after boot) |
| `/etc/NetworkManager/dispatcher.d/99-ipv64-update` | Instant trigger on network change |
| `/etc/logrotate.d/ipv64-update` | Daily rotation, 14 days retention |
| `/var/log/ipv64-update.log` | Log file |

### Useful commands

```bash
# Live log
tail -f /var/log/ipv64-update.log

# Errors only
grep ERROR /var/log/ipv64-update.log

# Timer status and next run
systemctl list-timers ipv64-update.timer

# Manual run
sudo /usr/local/bin/ipv64-update.sh manual

# Check which IPv6 the script would use
ip -6 addr show eth0 scope global \
  | grep -oP '(?<=inet6 )[0-9a-f:]+(?=/)' \
  | grep -v '^f[cd]' \
  | head -1

# Check current DNS at IPv64 nameserver
dig AAAA <your-domain> +short @ns1.ipv64.net
```

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: Konnte keine öffentliche IPv6 ermitteln` | No IPv6 on interface / wrong interface | `ip -6 addr show eth0` |
| `ERROR: Update fehlgeschlagen` | Wrong token / IPv64.net unreachable | Check token, `curl ipv64.net` |
| Timer not running after reboot | Timer not enabled | `sudo systemctl enable ipv64-update.timer` |
| `dig` not found | Package missing | `sudo apt install dnsutils` |
| Dispatcher not firing | File not created | `ls /etc/NetworkManager/dispatcher.d/` |

**IPv6 address types on the Pi:**

| Prefix | Type | Used |
|---|---|---|
| `2003:...` / `2001:...` | Public (ISP) | ✅ DynDNS address |
| `fdXX:...` / `fcXX:...` | ULA (private) | ❌ Filtered out |
| `fe80:...` | Link-local | ❌ Not global |

> **Never commit your update token.** The token grants full control over your DNS entries.

---

## Part 2 – Nginx Reverse Proxy

Accepts IPv6 (and IPv4) connections on a given port and proxies them to an IPv4-only backend. WebSocket support is included (long-lived `Upgrade` connections).

### Install

```bash
sudo bash nginx/install.sh
```

Asks for:

| Input | Example |
|---|---|
| Proxy name | `loxone1` |
| Backend URL | `http://loxone.fritz.box` |
| Port | `1907` |

The same port is used for both listening and the backend. Each proxy gets its own nginx site config at `/etc/nginx/sites-available/<name>` and a metadata file at `nginx/.<name>.conf` that `update.sh` / `uninstall.sh` read later.

### Update (change backend URL or port)

```bash
sudo bash nginx/update.sh [proxy-name]
# or omit the name to be prompted
```

### Uninstall

```bash
sudo bash nginx/uninstall.sh [proxy-name]
# or use 'alle' to remove every managed proxy
```

### After install: open the port on the Fritzbox

1. Fritzbox → Internet → Freigaben → IPv6
2. Add rule: TCP, port `<PORT>` → your Pi's IPv6 address

### Useful commands

```bash
# nginx error log
sudo tail -f /var/log/nginx/error.log

# Check port is open
ss -tlnp | grep <PORT>

# Test config
sudo nginx -t

# Reload after manual edits
sudo systemctl reload nginx
```

---

## Resources

- [IPv64.net Dashboard](https://ipv64.net)
- [IPv64.net API](https://ipv64.net/dyndns_updater_api)
