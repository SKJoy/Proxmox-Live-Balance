# Proxmox Live Balance

## Purpose

`check.sh` is a **Bash utility** for managing memory and storage resources of Proxmox virtual machines (VMs) and containers (CTs).  It reads a CSV file that defines per‑VM thresholds, queries the Proxmox REST API for current usage, and:
- **Raises** memory when usage exceeds the defined threshold.
- **Optimises** memory (decreases by 10 % rounded to the nearest 128 MiB) when the `-o` flag is supplied and usage is below the threshold.
- Reports storage consumption and emits alerts when storage exceeds its threshold.

The script is designed to be run from a **Linux/WSL** environment that has access to the Proxmox API and the required environment variables (`PROXMOX_HOST`, `PROXMOX_NODE`, `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET`).

## Repository Layout

```
Proxmox-Live-Balance/
├─ check.sh          # Main script (see below for usage)
├─ default.env       # Example `.env` file with the required variables
├─ item.csv          # Sample CSV file defining VM IDs and thresholds
└─ README.md         # This document
```

## Workflow

1. **Prepare environment** – Create a `.env` file (or edit `default.env`) with your Proxmox connection details.
2. **Create a CSV** – List the VMs/CTs you want to monitor.  Each line must contain:
   ```
   vmid, MEMORY_THRESHOLD_PERCENT, STORAGE_THRESHOLD_PERCENT
   ```
   Example:
   ```
   101,80,90
   102,75,85
   ```
3. **Run the script** – Execute `check.sh` with the desired options:
   - `-c <file>` – Specify a custom CSV (defaults to `item.csv`).
   - `-e <file>` – Specify a custom env file (defaults to `default.env`).
   - `-o` – Enable optimisation mode (decrease memory by 10 % when usage is below the threshold).
4. **Review output** – The script prints per‑VM status, any memory changes, storage alerts (prefixed with 🔔), and a summary section.

## Detailed Usage

```bash
# Basic usage (default CSV and env)
./check.sh

# Custom CSV and env file
./check.sh -c my_vms.csv -e my_env.env

# Optimisation mode (decrease memory when under‑utilised)
./check.sh -o

# Combine all options
./check.sh -c my_vms.csv -e my_env.env -o
```

### Expected Output

```
- VM <hostname>#101; Memory usage: 73% ; Storage usage: 45% ; 
🔔 ALERT: Storage consumption (92%) exceeds threshold (90%) for VM 102
…

Summary:
- Total items checked: 2
- Healthy items: 1
- Items exceeding memory threshold: 0
- Items exceeding storage threshold: 1
```

*Lines beginning with `🔔` indicate a storage‑threshold breach, while `⛔` warnings denote malformed CSV entries.*

## Installation & Prerequisites

- **Bash** (>= 4.0)
- **cURL** – for HTTP API calls.
- **Git** – the repository is already a Git repo; clone it with:
  ```bash
  git clone https://github.com/SKJoy/Proxmox-Live-Balance.git
  cd Proxmox-Live-Balance
  ```
- **Proxmox API token** – generate a token with `API` access in the Proxmox UI.

## Contributing

1. Fork the repository.
2. Create a feature branch:
   ```bash
   git checkout -b feature/<name>
   ```
3. Make your changes and ensure the script still runs against a test environment.
4. Commit with clear messages and push:
   ```bash
   git push origin feature/<name>
   ```
5. Open a Pull Request on GitHub.

## License

This project is licensed under the **MIT License** – see the `LICENSE` file for details.
