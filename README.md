# namesilo-ddns

A production-ready NameSilo DDNS updater built with **systemd timer + oneshot service**, designed for reliability, configurability, and clean deployment on Debian systems.

---

## ✨ Features

* Native **systemd timer-based scheduling**
* **Oneshot execution model** (no daemon)
* **HTTPS-first public IP detection**
* DNS-based fallback (OpenDNS + Google)
* Configurable **IP family selection** (`4`, `6`, `auto`)
* Safe update: **no NameSilo API call if IP unchanged**
* Detailed logging for network and DNS failures
* Clean configuration via `/etc/default`
* Native Debian `.deb` packaging

---

## 📦 Architecture

```text
namesilo-ddns.timer
        ↓
namesilo-ddns.service (Type=oneshot)
        ↓
namesilo-ddns-check.sh
        ↓
IP detection (HTTPS → DNS fallback)
        ↓
NameSilo API
```

### Components

| Component                    | Description                          |
| ---------------------------- | ------------------------------------ |
| `namesilo-ddns.timer`        | Schedules periodic execution         |
| `namesilo-ddns.service`      | Runs one update cycle                |
| `namesilo-ddns-check.sh`     | Performs IP detection and DNS update |
| `/etc/default/namesilo-ddns` | Runtime configuration                |

---

## ⚙️ Execution Model

Each execution performs:

1. Detect current public IP
2. Compare with cached IP
3. If unchanged → **exit immediately**
4. If changed → update NameSilo DNS record

Important:

* The service is **not a daemon**
* It runs only when triggered
* If IP is unchanged:

  * No `dnsListRecords`
  * No `dnsUpdateRecord`

---

## 🏗️ How to Build

### Prerequisites

```bash
sudo apt update
sudo apt install -y dpkg-dev
```

### Build

```bash
chmod +x build-deb.sh
./build-deb.sh
```

### Output

```text
./dist/namesilo-ddns_<version>_all.deb
```

### Install

```bash
sudo dpkg -i dist/namesilo-ddns_<version>_all.deb
```

---

## 🚀 Installation (from prebuilt package)

```bash
sudo dpkg -i namesilo-ddns_<version>_all.deb
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now namesilo-ddns.timer
```

---

## 🛠 Configuration

```bash
sudo editor /etc/default/namesilo-ddns
```

Example:

```bash
API_KEY="your_api_key"
DOMAIN="example.com"
HOST="home"
TTL="3600"

# IP family: 4 / 6 / auto
IP_FAMILY="4"

# HTTPS fallback
ENABLE_HTTP_FALLBACK="yes"
HTTP_IP_ECHO_PRIMARY="https://api.ipify.org"
HTTP_IP_ECHO_SECONDARY="https://ifconfig.co"

# DNS tuning
DIG_TIMEOUT_SEC="3"
DIG_TRIES="1"
DNS_LOOKUP_RETRY_DELAY_SEC="5"
```

Apply:

```bash
sudo systemctl restart namesilo-ddns.timer
```

---

## 🌐 Public IP Detection Strategy

Order:

1. HTTPS primary (`api.ipify.org`)
2. HTTPS secondary (`ifconfig.co`)
3. OpenDNS
4. Google DNS

### Why HTTPS first?

* Works when port 53 is blocked
* More stable in enterprise / cloud networks
* Uses standard outbound HTTPS (443)

---

## 🔀 IP Family Control

| Value  | Behavior                         |
| ------ | -------------------------------- |
| `4`    | Force IPv4 (`curl -4`, `dig -4`) |
| `6`    | Force IPv6 (`curl -6`, `dig -6`) |
| `auto` | No restriction                   |

Example:

```bash
IP_FAMILY="4"
```

---

## ⏱ Timer Behavior

Default:

```ini
OnBootSec=30s
OnUnitInactiveSec=5min
```

Meaning:

* Run once after boot
* Then run every 5 minutes

---

## 🔧 Modify Interval

```bash
sudo systemctl edit namesilo-ddns.timer
```

Example:

```ini
[Timer]
OnUnitInactiveSec=1min
```

Reload:

```bash
sudo systemctl daemon-reload
sudo systemctl restart namesilo-ddns.timer
```

---

## ▶️ Manual Run

```bash
sudo systemctl start namesilo-ddns.service
```

Use for:

* Immediate update
* Testing
* Debugging

---

## 📊 Logs

```bash
journalctl -u namesilo-ddns.service -f
```

---

## 🔍 Troubleshooting

### No IP detected

* Check HTTPS connectivity (443)
* Check DNS (53)
* Inspect logs

### Timer not running

```bash
systemctl status namesilo-ddns.timer
```

### DNS not updated

* Verify API key
* Verify domain/host
* Check NameSilo response code

---

## 📁 Project Structure

```text
.
├── README.md
├── build-deb.sh
├── bin/
│   └── namesilo-ddns-check.sh
├── packaging/
│   └── debian/
│       ├── DEBIAN/
│       │   ├── control
│       │   ├── postinst
│       │   └── prerm
│       ├── etc/default/namesilo-ddns
│       ├── lib/systemd/system/
│       │   ├── namesilo-ddns.service
│       │   └── namesilo-ddns.timer
│       └── usr/lib/namesilo-ddns/
│           └── namesilo-ddns-check.sh
└── dist/
```

---

## 🔐 Security

```bash
chmod 600 /etc/default/namesilo-ddns
```

---

## 🧠 Design Philosophy

* Keep it simple
* Keep it reliable
* Keep it systemd-native

Avoid:

* Daemons
* Network coupling
* Over-engineering

---

## 📄 License

MIT License

---

## 🤝 Contribution

Pull requests and issues are welcome.
