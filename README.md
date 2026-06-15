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

## Dependencies

Required runtime packages (declared in `DEBIAN/control`):

| Package | Purpose |
|---|---|
| `bash` | Script interpreter |
| `curl` | HTTP public-IP providers and NameSilo API calls |
| `dnsutils` | `dig` for DNS-based public-IP providers |
| `libxml2-utils` | `xmllint` for NameSilo XML API responses |
| `systemd` | Timer and service management |

Install on a fresh Debian system:

```bash
sudo apt-get install -y bash curl dnsutils libxml2-utils systemd
```

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

## End-to-End Update Flow

The DDNS update flow has three distinct phases:

```text
Phase 1: public IP discovery
    provider pool → ranking → query → validation → provider statistics

Phase 2: local change detection
    current public IP → compare with cached last_ip

Phase 3: NameSilo update
    only when IP changed → dnsListRecords → dnsUpdateRecord → update local cache
```

Full execution path:

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
build provider pool
    ↓
rank providers
    ↓
try providers in ranked order
    ↓
validate returned public IP
    ↓
update provider statistics
    ↓
compare with cached public IP
    ├── unchanged
    │       └── exit 0
    │           no dnsListRecords
    │           no dnsUpdateRecord
    │
    └── changed
            ↓
        dnsListRecords
            ↓
        find record_id
            ↓
        dnsUpdateRecord
            ↓
        update local last_ip cache
```

The public IP lookup path is a feedback-driven query flow, not a fixed fallback chain.

---

## Provider Subsystem

The provider subsystem is responsible only for one thing: discovering the current public IP.

It does **not** update DNS directly. DNS update is a later stage and happens only after the discovered public IP is compared with the cached `last_ip` value.

### Provider Control Plane

The control plane decides **which provider should be tried first**.

```text
configuration
    ↓
HTTP_IP_ECHO_PROVIDERS
DNS_IP_ECHO_PROVIDERS
    ↓
registered provider pool
    ↓
provider_stats.tsv
    ↓
adaptive score calculation
    ↓
ranked provider list
```

Signals used by adaptive ranking:

| Signal | Role |
|---|---|
| success count | raises confidence |
| failure count | lowers confidence |
| consecutive failures | strong penalty |
| EWMA latency | penalizes slow providers |
| cooldown state | temporarily suppresses bad providers |
| exploration interval | gives old failed providers a chance to recover |
| configured order | cold-start priority and tie-breaker only |

In `adaptive` mode, configured order is intentionally weak. Once runtime statistics exist, provider quality is dominated by observed behavior, not by list position.

In `static` mode, configured order becomes the actual query order.

### Provider Data Plane

The data plane performs the actual public IP lookup.

```text
ranked provider
    ↓
provider type?
    ├── http
    │       └── curl [-4|-6] <endpoint>
    │
    └── dns
            ├── opendns → dig [-4|-6] myip.opendns.com @resolverX.opendns.com
            └── google  → dig [-4|-6] TXT o-o.myaddr.l.google.com @nsX.google.com
    ↓
raw output
    ↓
parse public IP
    ↓
validate against IP_FAMILY
```

HTTP providers are configured by:

```bash
HTTP_IP_ECHO_PROVIDERS="https://ifconfig.co/ip https://ifconfig.me/ip https://ifconfig.io/ip https://ident.me https://icanhazip.com https://api.ipify.org"
```

DNS providers are configured by:

```bash
DNS_IP_ECHO_PROVIDERS="opendns google"
```

Supported DNS providers:

| Provider | Query method |
|---|---|
| `opendns` | `dig myip.opendns.com @resolverX.opendns.com` |
| `google` | `dig TXT o-o.myaddr.l.google.com @nsX.google.com` |

### Provider Feedback Loop

Every provider attempt updates runtime statistics.

```text
provider attempt
    ↓
success?
    ├── yes
    │       ├── success += 1
    │       ├── consecutive_fail = 0
    │       ├── update ewma_ms
    │       ├── clear cooldown
    │       └── save provider_stats.tsv
    │
    └── no
            ├── fail += 1
            ├── consecutive_fail += 1
            ├── update last_fail
            ├── maybe enter cooldown
            └── save provider_stats.tsv
```

This loop allows namesilo-ddns to adapt to the current host network. A provider that repeatedly fails will be pushed back or cooled down; a provider that is fast and stable will naturally move forward.

### Provider Failure Scope

Provider failures do not directly mean DDNS update failure.

```text
provider A fails
    ↓
record failure statistics
    ↓
try next ranked provider
```

Only when all usable providers fail does the service fail with:

```text
Unable to determine current public IP via configured provider pool
```

---

## NameSilo API Gate

The NameSilo API is protected by a local change-detection gate.

```text
current public IP
    ↓
compare with last_ip cache
    ↓
changed?
    ├── no  → exit 0; do not call NameSilo
    └── yes → call NameSilo APIs
```

When the IP is unchanged, the updater does not call:

- `dnsListRecords`
- `dnsUpdateRecord`

This is intentional. It reduces API traffic and avoids unnecessary writes.

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
