# pi-reverse-proxy

Raspberry Pi setup for two things that work together:

1. **DDNS** — keeps an IPv64.net AAAA record pointing at the Pi's current public IPv6 address
2. **Nginx reverse proxy** — terminates TLS on port 443 and forwards HTTPS connections to IPv4-only backends on the local network (e.g. a Loxone Miniserver)

```
Internet (IPv6)
      │
      ▼  TCP 443 (HTTPS)
 Fritzbox (port 80 + 443 open)
      │
      ▼
Raspberry Pi – nginx
  │  listens on [::]:443  – TLS termination (Let's Encrypt cert)
  │  listens on [::]:80   – ACME challenges + redirect to HTTPS
      │
      ▼  plain HTTP on LAN
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

| Input | Example | Where to find |
|---|---|---|
| Domain | `myhost.ipv64.de` | Your IPv64.net domain |
| DynDNS Update Token | `abc123…` | IPv64 dashboard → DynDNS → Update Token |
| Account API Key | `xyz789…` | IPv64 dashboard → Account → API Key |
| Interface | `eth0` or `wlan0` | `ip link show` |

> **Two different credentials are needed.** The DynDNS Update Token sends IP updates. The Account API Key reads the currently stored record from the IPv64 API — this is necessary when using the IPv64 CDN/reverse proxy, where a DNS lookup would return the CDN's IP instead of the one stored in the database.

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
| `jq` not found | Package missing | `sudo apt install jq` |
| `ERROR: API-Abfrage fehlgeschlagen` | Wrong API key or network issue | Check Account API Key, `curl https://ipv64.net/api.php?get_domains -H "Authorization: Bearer <key>"` |
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

Terminates HTTPS on port 443 using a Let's Encrypt certificate and proxies to an IPv4-only backend on the local network. Port 80 is kept open only for ACME renewal challenges and redirects everything else to HTTPS. WebSocket support is included.

### Install

```bash
sudo bash nginx/install.sh
```

Asks for:

| Input | Example |
|---|---|
| Proxy name | `loxone1` |
| FQDN | `myhost.ipv64.de` |
| Let's Encrypt e-mail | `you@example.com` |
| Backend URL | `http://loxone.fritz.box` |
| Backend port | `1907` |

The script:
1. Installs nginx + certbot
2. Writes a temporary HTTP-only config so certbot can complete the ACME challenge
3. Obtains the certificate via `certbot certonly --nginx`
4. Rewrites the config to HTTPS-only with the certificate
5. Installs a deploy hook so nginx is reloaded on every automatic renewal

Each proxy gets its own nginx site config at `/etc/nginx/sites-available/<name>` and a metadata file at `nginx/.<name>.conf` that `update.sh` / `uninstall.sh` read later.

### Update (change FQDN, backend URL, or backend port)

```bash
sudo bash nginx/update.sh [proxy-name]
# or omit the name to be prompted
```

If the FQDN changes, a new certificate is obtained automatically.

### Uninstall

```bash
sudo bash nginx/uninstall.sh [proxy-name]
# or use 'alle' to remove every managed proxy
```

Optionally also revokes and deletes the Let's Encrypt certificate.

### After install: open ports on the Fritzbox

1. Fritzbox → Internet → Freigaben → IPv6
2. Add two rules pointing to the Pi's IPv6 address:
   - TCP **80** (needed for Let's Encrypt renewal)
   - TCP **443** (HTTPS proxy)

### Useful commands

```bash
# nginx error log
sudo tail -f /var/log/nginx/error.log

# Check ports are open
ss -tlnp | grep -E ':80|:443'

# Test config
sudo nginx -t

# Reload after manual edits
sudo systemctl reload nginx

# Show certificates and expiry dates
sudo certbot certificates

# Test automatic renewal
sudo certbot renew --dry-run
```

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `certbot: connection refused` | Port 80 not open on Fritzbox | Add IPv6 rule TCP 80 → Pi |
| Certificate expired / not renewed | Deploy hook missing | Check `/etc/letsencrypt/renewal-hooks/deploy/` |
| 502 Bad Gateway | Backend unreachable | `curl http://loxone.fritz.box:1907` from the Pi |
| `ssl_dhparam` file missing | certbot didn't write it | `sudo openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048` |

---

## Resources

- [IPv64.net Dashboard](https://ipv64.net)
- [IPv64.net API](https://ipv64.net/dyndns_updater_api)
