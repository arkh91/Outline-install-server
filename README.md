# Outline server with key panel

`install_server.sh` installs the stock Outline server (Shadowbox + Watchtower) plus a small service, `outline-panel`,
that adds usage, online status, time limits, pause/resume, key editing and one device per key.
Keys stay normal Outline keys (`ss://` URLs work in the Outline Client). `outline_panel.py` is the panel on its own;
it is already embedded in the installer (byte-identical), so you only need `install_server.sh`.

## Install

Run as root on x86_64 Linux with systemd (Docker is offered if missing; python3, iptables, conntrack are installed if missing):

    sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/arkh91/Outline-install-server/refs/heads/main/install_server.sh)" install_server.sh --api-port=11111

Flags: `--hostname`, `--api-port`, `--keys-port` (first port of the key range), `--port-range <first>-<last>` (default `20000-20999`).

**Open in your cloud firewall:** the API port (TCP) and the whole key port range (TCP **and** UDP). Every key gets its own
port from that range; this is what makes one-device-per-key, online status and pause possible. ufw/firewalld are opened automatically if active.

The installer prints the usual `{"apiUrl":...,"certSha256":...}` line for Outline Manager / your app.

## Features

| Feature | Behaviour |
|---|---|
| Kept traffic | Per-key kernel counters, saved to `state.json`; survive restarts and reboots |
| One device per key | Newest device wins, the older one is cut off; scanners/probes don't count. A blocked device may return once the owner has been idle 60 s |
| Online / last seen | Last real traffic on the key's port; online = within 180 s (`lastSeen`, `lastHandshake`) |
| Live rate | `liveUploadBps`, `liveDownloadBps` per key |
| Time limit | Date, duration from now, duration after first connection, or none |
| Usage | `uploadBytes`, `downloadBytes`, `totalBytes`, optional data limit |
| Pause / resume | Blocks the key's port; stays blocked across reboots |
| Edit | Name, traffic, time limit, paused, singleDevice |

## API

Base: `https://<host>:<api-port>/<secret>` (self-signed; pin `certSha256`). Unknown routes are forwarded to Shadowbox.

| Method & path | Purpose |
|---|---|
| `GET /access-keys` | All keys + totals (`/keys` is the same under `keys`) |
| `GET /access-keys/<id>` | One key |
| `GET /live` | Light polling: online + live rates |
| `GET /usage`, `/usage/<id>`, `/metrics/transfer`, `/server` | Usage, Outline-style totals, server info |
| `POST /access-keys` | Create: `{"name","traffic","expires"}` (all optional) |
| `PATCH /access-keys/<id>` | Edit any of `name`, `traffic`, `expires`/`expiresOn`/`expiresAfterFirstConnection`, `paused`, `singleDevice` |
| `POST /access-keys/<id>/pause` · `/resume` | Pause / resume |
| `PUT\|DELETE /access-keys/<id>/limit` (`/data-limit`) | Set / clear traffic limit |
| `PUT\|DELETE /access-keys/<id>/expiry` | Set / clear time limit |
| `POST /access-keys/<id>/reset-usage` | Zero the usage |
| `POST /access-keys/<id>/migrate-port` | Give an old shared-port key its own port (its access URL changes) |
| `DELETE /access-keys/<id>` | Delete |

Values: `traffic` = `"20G"` (decimal), `"20GiB"`, bytes, or `"unlimited"`; `{"limit":{"bytes":N}}` also works.
`expires` = `"30d"`, `"12h"`, `"2w"`, `"1m"` (month), `"1y"`, `"never"` or a date; `expiresOn` = `"2026-12-31"` or `"2026-12-31 18:00"` (server time);
`expiresAfterFirstConnection` = `"30d"`.

## Operate

- Logs: `journalctl -u outline-panel -f`
- Settings: `vi /opt/outline/panel/config.json`, then `systemctl restart outline-panel`
- Files: `/opt/outline/panel/` (`panel.py`, `config.json`, `state.json`); units `outline-panel` and `outline-panel-firewall` (restores blocks at boot before Docker)
- Re-running the installer rewrites `config.json` (new secret/ports/cert); keys and usage in `state.json` are kept.

## Limits

- Devices behind the same public IP count as one device; IPv6 is grouped by /64.
- "Handshake" = last traffic (Shadowsocks has no handshake).
- Keys created before the panel on one shared port show as `unmanaged` and can't be paused/limited until migrated.
- Traffic is counted at the port (wire bytes), so a flood aimed at a key's port counts against it.
- Tested against a fake Shadowbox on a real kernel; try one real server with two phones before rollout.
