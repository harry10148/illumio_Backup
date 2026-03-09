# Illumio PCE Smart Backup Script

[繁體中文](README_zh.md) | **English**

This script provides an automated, HA-aware backup solution for an Illumio PCE Cluster. It automatically detects the primary database node, executes the backup (Policy DB, Traffic DB, and run-time environment), and securely transfers the files to local or remote destinations (SMB, NFS, SCP) with a built-in retention policy.

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
1. **Local Log Files**: Saved in `/opt/illumio-backup/logs/` for easy troubleshooting.
2. **Syslog Integration**: Messages are sent to `/var/log/messages` via `logger`. If you forward syslog to a SIEM (e.g., Splunk, QRadar), you can use these events to monitor backup success or detect failures.

## 2. Installation

Deploy the script on **all** database nodes. Only the primary node will execute the backup tasks.

### 2.1 Download and Setup
1. Upload `illumio_backup.sh` to `/usr/local/bin/`.
2. Apply execution permissions:
   ```bash
   chmod +x /usr/local/bin/illumio_backup.sh
   ```

### 2.2 Configuration Variables
Open `illumio_backup.sh` and configure the following variables according to your environment:

```bash
# 1. Local Backup Settings
LOCAL_BACKUP_DIR="/opt/illumio-backup"    
RETENTION_DB_DAYS=7                       
RETENTION_TRAFFIC_DAYS=14                 

# 2. SMB/NFS Settings (Ignore if not used)
SMB_MOUNT_POINT="/mnt/smb/illumio-backup" 
NFS_MOUNT_POINT="/mnt/nfs/illumio-backup" 

# 3. SCP Settings (Ignore if not used)
DR_USER="root"                            
DR_HOST="172.16.15.131"                   
DR_DEST_DIR="/opt/illumio-backup"         
```

## 3. Remote Targets Setup (Optional)

### 3.1 SMB Mount
To transfer backups to a Windows SMB share:

1. **Install CIFS utils**:
   ```bash
   dnf install cifs-utils -y
   ```

2. **Create credentials file**:
   ```bash
   vi /root/smb.cred
   ```
   *Content:*
   ```ini
   username=YOUR_SMB_USER
   password=YOUR_SMB_PASSWORD
   domain=YOUR_DOMAIN (Optional)
   ```
   ```bash
   chmod 600 /root/smb.cred
   ```

3. **Configure automatic mount (`/etc/fstab`)**:
   ```bash
   //YOUR_SMB_SERVER/SHARE_PATH /mnt/smb  cifs  credentials=/root/smb.cred  0 0
   ```
   ```bash
   mkdir -p /mnt/smb
   sudo mount -a
   ```

### 3.2 NFS Mount
To transfer backups to an NFS share:
*(Note: NFS (v3/v4) uses IP-based access control via `/etc/exports`, not passwords.)*

1. **Install NFS tools**:
   ```bash
   dnf install nfs-utils -y
   ```

2. **Configure automatic mount (`/etc/fstab`)**:
   ```bash
   YOUR_NFS_SERVER_IP:/SHARE_PATH /mnt/nfs  nfs  defaults  0 0
   ```
   ```bash
   mkdir -p /mnt/nfs
   sudo mount -a
   ```

### 3.3 SCP Passwordless Login
To transfer backups securely to another Linux host via SCP:

1. **Generate SSH key pair** (Do not set a passphrase):
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

## 4. Usage & Scheduling

### 4.1 Execution Parameters
Pass parameters to define the target destinations:

- **Local backup only:**
  ```bash
  /usr/local/bin/illumio_backup.sh
  ```
- **Local + SMB + NFS backup:**
  ```bash
  /usr/local/bin/illumio_backup.sh --smb --nfs
  ```
- **Local + SCP backup (requires 3.3 setup):**
  ```bash
  /usr/local/bin/illumio_backup.sh --scp
  ```

### 4.2 Crontab Setup
To automate the script (e.g., daily at 2:00 AM transferring to SCP and SMB):

```bash
crontab -e
```
```bash
0 2 * * * /usr/local/bin/illumio_backup.sh --smb --scp >/dev/null 2>&1
```

## 5. Operational Notes

- **Backup Content**:
  - `runtime_env.yml`: Backed up during every run.
  - **Policy Database**: Dumped during every run.
  - **Traffic Database**: Due to its potential size, this is **only backed up on Sundays**.
- **Log Location**: Detailed logs are stored locally in `/opt/illumio-backup/logs/` and forwarded to `/var/log/messages`.
- **Retention**: Local and remote cleanup executions are handled automatically based on the retention variables configured in the script.

## 6. Illumio Database Restore Commands
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
