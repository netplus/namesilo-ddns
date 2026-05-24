# namesilo-ddns

NameSilo DDNS updater for Debian systems, implemented as a **systemd timer + oneshot service**.

The updater detects the current public IP, compares it with the cached value, and updates the configured NameSilo DNS record only when the IP has changed.

---

## Features

- systemd timer-based scheduling
- oneshot execution; no daemon
- split configuration: general runtime settings and record-specific settings
- adaptive public IP provider pool
- provider statistics, cooldown, and exploration
- IPv4 / IPv6 / auto lookup mode
- no NameSilo API call when the cached IP is unchanged
- Debian `.deb` packaging

---

## Configuration Layout

namesilo-ddns uses two configuration files:

```text
/etc/default/namesilo-ddns
    General runtime configuration:
    provider pool, ranking mode, timeouts, state paths, logging behavior.

/etc/namesilo-ddns/record.conf
    Record-specific configuration:
    API_KEY, DOMAIN, HOST, TTL.
```

This split keeps domain-specific values stable during package upgrades. Future changes to provider ranking, timeouts, or runtime defaults should normally affect only `/etc/default/namesilo-ddns`.

---

## Execution Flow

```text
namesilo-ddns.timer
    ↓
namesilo-ddns.service
    ↓
load /etc/default/namesilo-ddns
    ↓
load /etc/namesilo-ddns/record.conf
    ↓
load provider statistics
    ↓
build and rank provider pool
    ↓
query public IP providers
    ↓
validate returned IP
    ↓
update provider statistics
    ↓
compare with cached IP
    ├── unchanged → exit without calling NameSilo API
    └── changed   → dnsListRecords → dnsUpdateRecord
```

The public IP lookup path is a feedback-driven query flow, not a fixed fallback chain.

---

## Build

```bash
sudo apt update
sudo apt install -y dpkg-dev
chmod +x build-deb.sh
./build-deb.sh
```

The package is generated under:

```text
./dist/namesilo-ddns_<version>_all.deb
```

---

## Install

```bash
sudo dpkg -i dist/namesilo-ddns_<version>_all.deb
```

Create the record-specific configuration before starting the timer:

```bash
sudo cp /etc/namesilo-ddns/record.conf.example /etc/namesilo-ddns/record.conf
sudo editor /etc/namesilo-ddns/record.conf
sudo chmod 600 /etc/namesilo-ddns/record.conf
```

Review general runtime configuration if needed:

```bash
sudo editor /etc/default/namesilo-ddns
```

Enable the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now namesilo-ddns.timer
```

Run once immediately:

```bash
sudo systemctl start namesilo-ddns.service
```

---

## Record Configuration

`/etc/namesilo-ddns/record.conf`:

```bash
API_KEY="your_namesilo_api_key"
DOMAIN="example.com"
HOST="home"
TTL="3600"
```

This file contains credentials and deployment-specific values. Keep it readable only by root.

---

## General Runtime Configuration

`/etc/default/namesilo-ddns` contains runtime behavior such as provider selection, ranking, timeout, and state settings.

Common settings:

```bash
STATE_DIR="/var/lib/namesilo-ddns"
DOMAIN_CONFIG_FILE="/etc/namesilo-ddns/record.conf"

IP_FAMILY="4"
IP_PROVIDER_MODE="adaptive"
ENABLE_HTTP_PROVIDERS="yes"

HTTP_IP_ECHO_PROVIDERS="https://ifconfig.co/ip https://ifconfig.me/ip https://ifconfig.io/ip https://ident.me https://icanhazip.com https://api.ipify.org"
DNS_IP_ECHO_PROVIDERS="opendns google"

PROVIDER_STATS_FILE="/var/lib/namesilo-ddns/provider_stats.tsv"
PROVIDER_MAX_CONSECUTIVE_FAILS="3"
PROVIDER_COOLDOWN_BASE_SEC="300"
PROVIDER_COOLDOWN_MAX_SEC="3600"
PROVIDER_EXPLORATION_INTERVAL_SEC="86400"
PROVIDER_LOG_RANKING="no"
```

---

## Provider Ranking

When `IP_PROVIDER_MODE="adaptive"`, the configured provider order is only a weak signal:

- cold-start priority when no statistics exist
- tie-breaker when scores are close

After runtime statistics are available, ranking is dominated by:

- success rate
- consecutive failures
- cooldown state
- EWMA latency
- exploration interval

To force configured order:

```bash
IP_PROVIDER_MODE="static"
```

---

## Provider Statistics

Provider statistics are stored in:

```text
/var/lib/namesilo-ddns/provider_stats.tsv
```

View them with:

```bash
sudo column -t -s $'\t' /var/lib/namesilo-ddns/provider_stats.tsv
```

Reset statistics:

```bash
sudo rm -f /var/lib/namesilo-ddns/provider_stats.tsv
sudo systemctl start namesilo-ddns.service
```

First run behavior:

- missing `provider_stats.tsv` is normal
- unreadable stats file logs a warning and starts with empty statistics
- unwritable stats file logs a warning; the current run continues but statistics are not persisted
- `last_ip` is critical state; if an existing `last_ip` file is unreadable or not a regular file, the updater fails to avoid unnecessary NameSilo API calls

---

## IP Family

| Value | Behavior |
|---|---|
| `4` | force IPv4 with `curl -4` and `dig -4` |
| `6` | force IPv6 with `curl -6` and `dig -6` |
| `auto` | do not force address family |

For IPv4 A records, use:

```bash
IP_FAMILY="4"
```

---

## Timer

Default timer behavior:

```ini
OnBootSec=30s
OnUnitInactiveSec=5min
```

Change the interval with a systemd override:

```bash
sudo systemctl edit namesilo-ddns.timer
sudo systemctl daemon-reload
sudo systemctl restart namesilo-ddns.timer
```

---

## Logs

```bash
sudo journalctl -u namesilo-ddns.service -f
sudo journalctl -t namesilo-ddns-check -n 100 --no-pager
sudo journalctl -u namesilo-ddns.timer -u namesilo-ddns.service -n 200 --no-pager
```

Check timer status:

```bash
systemctl list-timers | grep namesilo
systemctl status namesilo-ddns.timer
```

---

## Project Structure

```text
.
├── README.md
├── build-deb.sh
├── bin/namesilo-ddns-check.sh
├── packaging/debian/DEBIAN/
├── packaging/debian/etc/default/namesilo-ddns
├── packaging/debian/etc/namesilo-ddns/record.conf.example
├── packaging/debian/lib/systemd/system/
└── dist/
```

---

## Security

- Store credentials only in `/etc/namesilo-ddns/record.conf`.
- Restrict permissions with `sudo chmod 600 /etc/namesilo-ddns/record.conf`.
- Provider statistics do not contain credentials, but they may expose runtime network behavior.

---

## License

MIT License
