# namesilo-ddns

A production-ready NameSilo DDNS updater built with **systemd timer + oneshot service**, designed for clean deployment, reliability, and long-term maintainability on Debian systems.

---

## ✨ Features

* Native **systemd timer-based scheduling**
* **Oneshot service execution** (no daemon)
* Lightweight and minimal dependencies
* Clean configuration via `/etc/default`
* Automatic public IP detection
* Safe update (only triggers when IP changes)
* Concurrency-safe (lock protection)
* Debian `.deb` packaging included

---

## 📦 Architecture

This project follows a **systemd-native design**:

```
namesilo-ddns.timer
        ↓
namesilo-ddns.service (Type=oneshot)
        ↓
namesilo-ddns script
        ↓
NameSilo API
```

### Components

| Component               | Description                     |
| ----------------------- | ------------------------------- |
| `namesilo-ddns.timer`   | Triggers execution periodically |
| `namesilo-ddns.service` | Executes one DDNS update cycle  |
| Script                  | Detects IP and updates DNS      |
| Config                  | `/etc/default/namesilo-ddns`    |

---

## ⚙️ Execution Model

* The service is **NOT a daemon**
* Each run:

  1. Detect current public IP
  2. Compare with cached IP
  3. Update NameSilo DNS if changed
  4. Exit

✔ No long-running process
✔ Fully controlled by systemd timer

---

## 🚀 Installation

```bash
sudo dpkg -i namesilo-ddns_1.1.0_all.deb
```

Enable and start the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now namesilo-ddns.timer
```

---

## 🛠 Configuration

Edit:

```bash
sudo editor /etc/default/namesilo-ddns
```

Example:

```bash
API_KEY="your_namesilo_api_key"
DOMAIN="example.com"
HOST="home"      # Use @ for root domain
TTL="3600"
```

Apply changes:

```bash
sudo systemctl restart namesilo-ddns.timer
```

---

## ⏱ Timer Behavior

Default schedule:

```ini
OnBootSec=30s
OnUnitInactiveSec=5min
```

Meaning:

* Run once **30 seconds after boot**
* Then run every **5 minutes after last execution finishes**

---

## 🔧 Modify Timer Interval

Override timer config:

```bash
sudo systemctl edit namesilo-ddns.timer
```

Example (run every 1 minute):

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

## ▶️ Manual Execution

Run once immediately:

```bash
sudo systemctl start namesilo-ddns.service
```

Use cases:

* Test configuration
* Immediate DNS update
* Debugging

---

## 📊 Monitoring & Logs

View logs:

```bash
journalctl -u namesilo-ddns.service -f
```

Check timer:

```bash
systemctl list-timers | grep namesilo
```

Check service status:

```bash
systemctl status namesilo-ddns.service
```

---

## 🔍 Troubleshooting

### No update happening

* Check API key validity
* Verify domain/host match in NameSilo
* Check logs:

```bash
journalctl -u namesilo-ddns.service -n 50
```

---

### Timer not running

```bash
systemctl status namesilo-ddns.timer
```

Ensure it's enabled:

```bash
systemctl enable namesilo-ddns.timer
```

---

### DNS not updated

* Confirm public IP detection works
* Check XML parsing (`xmllint`)
* Verify record ID extraction

---

## 📁 Project Structure

```
.
├── debian/
│   ├── control
│   ├── postinst
│   └── ...
├── usr/lib/namesilo-ddns/
│   └── namesilo-ddns.sh
├── etc/default/
│   └── namesilo-ddns
├── systemd/
│   ├── namesilo-ddns.service
│   └── namesilo-ddns.timer
├── build-deb.sh
└── README.md
```

---

## 🔐 Security Notes

* API key stored in `/etc/default/namesilo-ddns`
* File should be readable by root only:

```bash
chmod 600 /etc/default/namesilo-ddns
```

---

## 🧠 Design Philosophy

This project intentionally avoids:

* Long-running daemons
* Tight coupling with network interfaces (e.g. wg, eth0)
* Over-engineering

Instead, it focuses on:

✔ Clear responsibility (DDNS only)
✔ systemd-native scheduling
✔ Simplicity and reliability

---

## 📌 Future Improvements (Optional)

* Multi-record support
* IPv6 support
* JSON API support (instead of XML)
* Retry/backoff strategy
* Metrics export

---

## 📄 License

MIT License (or your choice)

---

## 🤝 Contribution

Contributions are welcome.
Feel free to submit issues or pull requests.

---
