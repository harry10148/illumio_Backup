# Illumio PCE Smart Backup Script

[繁體中文](README_zh.md) | **English**

This script provides an automated, HA-aware backup solution for an Illumio PCE Cluster. It automatically detects the primary database node, executes the backup (Policy DB, Traffic DB, and run-time environment), and securely transfers the files to one or more selected destinations (Local, SMB, NFS, SCP) with a built-in retention policy, disk-space guard, and configurable backup frequency.

## 1. Architecture & Design Logic

### 1.1 Primary Database Detection
In an Illumio PCE High Availability (HA) architecture, backups can only be safely performed on the primary database node. According to the official *Illumio Core 23.2 Administration* guide, the backup must be executed from the data node running the `agent_traffic_redis_server` service.

**Script Implementation:**
The script runs `illumio-pce-ctl cluster-status` to find the node running the `agent_traffic_redis_server`. It then compares that node's IP to the local machine's IP:
- **Match**: The local node is the Primary database. The script proceeds with the backup.
- **Mismatch**: The local node is a secondary/standby node. The script logs the event and exits safely without performing a backup.

This design means you can deploy the script and configure the exact same cron job on **all data nodes**. They will all run seamlessly, but only the active Primary node will actually perform the backup, preventing conflicts.

### 1.2 Error Handling & Logging
The built-in `log` function handles status updates:
1. **Local Log Files**: If `--local` is enabled, saved in `LOCAL_BACKUP_DIR/logs/`. Otherwise, written to `/tmp/illumio-backup/logs/`.
2. **Syslog Integration**: Messages are sent to `/var/log/messages` via `logger`. If you forward syslog to a SIEM (e.g., Splunk, QRadar), you can use these events to monitor backup success or detect failures.

---

## 2. New Features (v2)

### 2.1 Mandatory Destination Selection
Local backup is **no longer the default**. You must explicitly choose at least one destination. If no destination flag is given, the script will exit with an error:

```
ERROR: 請至少指定一個備份目的地 (--local / --smb / --nfs / --scp)
```

When `--local` is **not** selected, the script uses a temporary directory (`mktemp -d`) to stage the backup file before transferring it. The temp directory is automatically removed when the script exits.

### 2.2 Configurable Backup Frequency
Instead of always running every execution, the script checks the modification time of the most recent backup file to determine whether a new backup is needed.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--db-interval <days>` | `1` | Run Policy DB backup every N days |
| `--traffic-interval <days>` | `7` | Run Traffic DB backup every N days |

If no previous backup file is found, the backup runs unconditionally (treating it as "never backed up").

### 2.3 Disk Space Guard
Before writing any backup file, the script checks available disk space on each enabled destination. If the free space is below the threshold, the script aborts with an error.

| Parameter | Default | Target |
|-----------|---------|--------|
| `--min-free-local <GB>` | `5` | Local backup directory |
| `--min-free-share <GB>` | `10` | SMB / NFS mount point |
| `--min-free-remote <GB>` | `10` | SCP remote host (checked via SSH) |

---

## 3. Installation

Deploy the script on **all** database nodes. Only the primary node will execute the backup tasks.

### 3.1 Download and Setup
1. Upload `illumio_backup.sh` to `/usr/local/bin/`.
2. Apply execution permissions:
   ```bash
   chmod +x /usr/local/bin/illumio_backup.sh
   ```

### 3.2 Configuration Variables
Open `illumio_backup.sh` and adjust the defaults in the `[SCRIPT CONFIGURATION]` section:

```bash
# 1. Local Backup Settings
LOCAL_BACKUP_DIR="/opt/illumio-backup"    # Local directory for backups and logs
RETENTION_DB_DAYS=7                       # Retention days for Policy DB / Runtime Env
RETENTION_TRAFFIC_DAYS=14                # Retention days for Traffic DB

# 2. SMB/NFS Settings (ignore if not used)
SMB_MOUNT_POINT="/mnt/smb/illumio-backup"
NFS_MOUNT_POINT="/mnt/nfs/illumio-backup"

# 3. SCP (DR Site) Settings (ignore if not used)
DR_USER="root"
DR_HOST="172.16.15.131"
DR_DEST_DIR="/opt/illumio-backup"
SCP_TIMEOUT=30

# 4. Disk Space Thresholds (GB)
MIN_FREE_GB_LOCAL=5
MIN_FREE_GB_SHARE=10
MIN_FREE_GB_REMOTE=10

# 5. Backup Frequency (days)
DB_INTERVAL=1        # Policy DB and runtime_env interval
TRAFFIC_INTERVAL=7   # Traffic DB interval
```

---

## 4. Remote Targets Setup (Optional)

### 4.1 SMB Mount
1. **Install CIFS utils**:
   ```bash
   dnf install cifs-utils -y
   ```
2. **Create credentials file**:
   ```bash
   vi /root/smb.cred
   ```
   ```ini
   username=YOUR_SMB_USER
   password=YOUR_SMB_PASSWORD
   domain=YOUR_DOMAIN
   ```
   ```bash
   chmod 600 /root/smb.cred
   ```
3. **Configure automatic mount (`/etc/fstab`)**:
   ```
   //YOUR_SMB_SERVER/SHARE /mnt/smb  cifs  credentials=/root/smb.cred  0 0
   ```
   ```bash
   mkdir -p /mnt/smb && sudo mount -a
   ```

### 4.2 NFS Mount
*(NFS v3/v4 uses IP-based access control via `/etc/exports`, not passwords.)*
1. **Install NFS tools**:
   ```bash
   dnf install nfs-utils -y
   ```
2. **Configure automatic mount (`/etc/fstab`)**:
   ```
   YOUR_NFS_SERVER:/SHARE /mnt/nfs  nfs  defaults  0 0
   ```
   ```bash
   mkdir -p /mnt/nfs && sudo mount -a
   ```

### 4.3 SCP Passwordless Login
1. **Generate SSH key pair** (no passphrase):
   ```bash
   ssh-keygen -t rsa -b 4096
   ```
2. **Copy public key to target host**:
   ```bash
   ssh-copy-id TARGET_USER@TARGET_IP
   ```
3. **Verify connection**:
   ```bash
   ssh TARGET_USER@TARGET_IP "ls -l"
   ```

---

## 5. Usage

### 5.1 Full Parameter Reference
```
Destination (at least one required):
  --local                  Backup to local directory
  --smb                    Copy to SMB/CIFS share
  --nfs                    Copy to NFS share
  --scp                    Transfer to DR host via SCP

Frequency:
  --db-interval <days>     Policy DB backup interval (default: 1)
  --traffic-interval <days> Traffic DB backup interval (default: 7)

Retention:
  --retention-db <days>    Retention for DB/Env files (default: 7)
  --retention-traffic <days> Retention for Traffic files (default: 14)

Disk Space Threshold:
  --min-free-local <GB>    Min free space for local dir (default: 5)
  --min-free-share <GB>    Min free space for SMB/NFS (default: 10)
  --min-free-remote <GB>   Min free space on remote host (default: 10)
```

### 5.2 Common Examples

```bash
# Local backup only
/usr/local/bin/illumio_backup.sh --local

# SMB only (no local copy retained)
/usr/local/bin/illumio_backup.sh --smb

# Local + SCP
/usr/local/bin/illumio_backup.sh --local --scp

# SMB + NFS, Policy DB every 3 days, Traffic every 14 days
/usr/local/bin/illumio_backup.sh --smb --nfs --db-interval 3 --traffic-interval 14

# Custom disk thresholds
/usr/local/bin/illumio_backup.sh --local --smb --min-free-local 20 --min-free-share 50
```

### 5.3 Crontab Setup
```bash
crontab -e
```
```bash
# Daily at 2:00 AM — backup to SMB and SCP
0 2 * * * /usr/local/bin/illumio_backup.sh --smb --scp >/dev/null 2>&1

# Daily at 2:00 AM — local + SMB, Traffic every 14 days
0 2 * * * /usr/local/bin/illumio_backup.sh --local --smb --traffic-interval 14 >/dev/null 2>&1
```

---

## 6. Operational Notes

- **Backup Content**:
  - `runtime_env.yml`: Backed up on every qualifying run (follows `--db-interval`).
  - **Policy Database**: Dumped on every qualifying run (follows `--db-interval`).
  - **Traffic Database**: Backed up according to `--traffic-interval` (default: every 7 days). The old Sunday-only hard-code has been removed.
- **Log Location**: Logs are written to `LOCAL_BACKUP_DIR/logs/` (if `--local` is active) or `/tmp/illumio-backup/logs/`, and forwarded to `/var/log/messages` via syslog.
- **Retention**: Old files are cleaned up automatically on each enabled destination after every run.
- **No destination selected**: The script exits immediately with a clear error message; no backup is attempted.

---

## 7. Illumio Database Restore Commands
For manual disaster recovery scenarios:

```bash
# Stop services
sudo -u ilo-pce illumio-pce-ctl stop
# Start in Runlevel 1
sudo -u ilo-pce illumio-pce-ctl start --runlevel 1
# Check cluster status
sudo -u ilo-pce illumio-pce-ctl cluster-status -w

# Restore databases
sudo -u ilo-pce illumio-pce-db-management restore --file /path/to/backup.dump
sudo -u ilo-pce illumio-pce-db-management traffic restore --file /path/to/traffic.tar.gz

# Migrate database
sudo -u ilo-pce illumio-pce-db-management migrate

# Set to Runlevel 5 and disable listen-only-mode
sudo -u ilo-pce illumio-pce-ctl set-runlevel 5
sudo -u ilo-pce illumio-pce-ctl listen-only-mode disable
```
