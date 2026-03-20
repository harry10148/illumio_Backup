# Illumio PCE 備份腳本架構與使用說明

**繁體中文** | [English](README.md)

## 1. 簡介與使用情境
此文件旨在說明 `illumio_backup.sh` 備份腳本的運作原理、決策邏輯以及如何自定義修改以符合您的環境。

此腳本可滿足在 Illumio PCE Cluster 架構下：
- 自動識別主要節點，避免雙重備份
- 執行備份並傳輸到一個或多個目的地 (Local/SMB/NFS/SCP)
- 依照設定的間隔天數決定是否執行備份（避免不必要的重複）
- 在寫入備份前先確認目標磁碟空間充足
- 自動執行檔案保留 (Retention) 清理

---

## 2. 決策邏輯：為什麼這樣設計？

### 2.1 決定備份節點 (Determine the Primary Database)
在 Illumio PCE 的高可用性 (HA) 架構中，**資料庫只有在主要 (Primary) 節點才可進行備份操作**。腳本使用 `illumio-pce-ctl cluster-status` 找出運行 `agent_traffic_redis_server` 的節點 IP，並比對自身 IP：
- **是**：本機是 Primary 節點 → 繼續執行備份
- **否**：本機是備用節點 → 記錄日誌並安全退出，不執行任何備份

這代表您可以在**所有**資料庫節點上設定相同的 Crontab，只有真正的 Primary 節點會執行備份。

### 2.2 錯誤處理與日誌記錄
腳本內建 `log` 函數，所有操作狀態都會：
1. **寫入本地日誌檔案**：啟用 `--local` 時儲存於 `LOCAL_BACKUP_DIR/logs/`，否則寫至 `/tmp/illumio-backup/logs/`
2. **傳送至 Syslog**：使用 `logger` 寫進 `/var/log/messages`，可整合至 SIEM (Splunk、QRadar 等)

---

## 3. 新功能說明 (v2)

### 3.1 本地備份不再是預設，必須選擇至少一個目的地
腳本現在要求執行時明確指定至少一個目的地。若未指定任何 flag，腳本將直接中止：

```
ERROR: 請至少指定一個備份目的地 (--local / --smb / --nfs / --scp)
```

若未選擇 `--local`，腳本會先將備份檔案寫入 `mktemp -d` 暫存目錄，傳輸完畢後自動清除，**本地不會留下任何備份複本**。

### 3.2 備份頻率可自行設定
腳本會根據目的地中**最後一個備份檔案的修改時間**，判斷是否需要執行備份：

| 參數 | 預設 | 說明 |
|------|------|------|
| `--db-interval <天>` | `1` | Policy DB 及 runtime_env 備份間隔（天）|
| `--traffic-interval <天>` | `7` | Traffic DB 備份間隔（天）|

若目的地中找不到任何先前的備份檔，視為「首次備份」，強制執行。

### 3.3 磁碟容量預先檢查
在每個目的地**寫入備份前**，腳本會確認剩餘空間是否高於門檻，若不足則立即中止並記錄錯誤。

| 參數 | 預設 | 適用目標 |
|------|------|---------|
| `--min-free-local <GB>` | `5` | 本地備份目錄 |
| `--min-free-share <GB>` | `10` | SMB / NFS 掛載點 |
| `--min-free-remote <GB>` | `10` | SCP 遠端主機（透過 SSH 查詢）|

---

## 4. 安裝與設定說明

### 4.1 準備 SMB 網路掛載 (若有需要)
1. **安裝 CIFS 套件**：
   ```bash
   dnf install cifs-utils -y
   ```
2. **建立 SMB 認證金鑰檔**：
   ```bash
   vi /root/smb.cred
   ```
   ```ini
   username=您的SMB帳號
   password=您的SMB密碼
   domain=您的網域名稱 (若無可省略)
   ```
   ```bash
   chmod 600 /root/smb.cred
   ```
3. **設定開機自動掛載 (`/etc/fstab`)**：
   ```
   //您的SMB伺服器/分享路徑 /mnt/smb  cifs  credentials=/root/smb.cred  0 0
   ```
   ```bash
   mkdir -p /mnt/smb && sudo mount -a
   ```

### 4.2 準備 NFS 網路掛載 (若有需要)
*(NFS v3/v4 不需帳號密碼，依賴 Server 端 `/etc/exports` 控制來源 IP)*
1. **安裝 NFS 工具**：
   ```bash
   dnf install nfs-utils -y
   ```
2. **設定開機自動掛載 (`/etc/fstab`)**：
   ```
   您的NFS伺服器IP:/分享路徑 /mnt/nfs  nfs  defaults  0 0
   ```
   ```bash
   mkdir -p /mnt/nfs && sudo mount -a
   ```

### 4.3 準備 SCP 免密碼登入 (若有需要)
1. **產生 SSH 金鑰對**（不要設定 passphrase）：
   ```bash
   ssh-keygen -t rsa -b 4096
   ```
2. **將公鑰傳送至遠端備份主機**：
   ```bash
   ssh-copy-id 目標使用者@遠端主機IP
   ```
3. **測試連線**：
   ```bash
   ssh 目標使用者@遠端主機IP "ls -l"
   ```

### 4.4 準備腳本
1. 上傳腳本至伺服器，例如 `/usr/local/bin/illumio_backup.sh`
2. 賦予執行權限：
   ```bash
   chmod +x /usr/local/bin/illumio_backup.sh
   ```

### 4.5 自定義變數 (Configuration Variables)
開啟腳本，在 `[SCRIPT CONFIGURATION]` 區段根據環境修改以下預設值：

```bash
# 1. 本地備份設定
LOCAL_BACKUP_DIR="/opt/illumio-backup"    # 備份檔案與日誌目錄
RETENTION_DB_DAYS=7                       # Policy DB / runtime_env 保留天數
RETENTION_TRAFFIC_DAYS=14                # Traffic DB 保留天數

# 2. SMB/NFS 設定 (不啟用可忽略)
SMB_MOUNT_POINT="/mnt/smb/illumio-backup"
NFS_MOUNT_POINT="/mnt/nfs/illumio-backup"

# 3. SCP 設定 (不啟用可忽略)
DR_USER="root"
DR_HOST="172.16.15.131"
DR_DEST_DIR="/opt/illumio-backup"
SCP_TIMEOUT=30

# 4. 磁碟空間門檻 (GB)
MIN_FREE_GB_LOCAL=5
MIN_FREE_GB_SHARE=10
MIN_FREE_GB_REMOTE=10

# 5. 備份頻率 (天)
DB_INTERVAL=1       # Policy DB / runtime_env 備份間隔
TRAFFIC_INTERVAL=7  # Traffic DB 備份間隔
```

---

## 5. 執行與參數說明

### 5.1 完整參數列表
```
目的地（至少選一）:
  --local                  備份至本地目錄
  --smb                    複製至 SMB/CIFS 共用資料夾
  --nfs                    複製至 NFS 共用目錄
  --scp                    透過 SCP 傳輸至遠端主機

頻率:
  --db-interval <天>       Policy DB 備份間隔（預設: 1）
  --traffic-interval <天>  Traffic DB 備份間隔（預設: 7）

保留期限:
  --retention-db <天>      DB/Env 保留天數（預設: 7）
  --retention-traffic <天> Traffic 保留天數（預設: 14）

磁碟空間門檻:
  --min-free-local <GB>    本地最低剩餘空間（預設: 5）
  --min-free-share <GB>    SMB/NFS 最低剩餘空間（預設: 10）
  --min-free-remote <GB>   遠端主機最低剩餘空間（預設: 10）
```

### 5.2 常用範例

```bash
# 只存本地
/usr/local/bin/illumio_backup.sh --local

# 只存 SMB，不保留本地複本
/usr/local/bin/illumio_backup.sh --smb

# 本地 + SCP 雙份
/usr/local/bin/illumio_backup.sh --local --scp

# 傳到 SMB + NFS，Policy DB 每 3 天、Traffic 每 14 天
/usr/local/bin/illumio_backup.sh --smb --nfs --db-interval 3 --traffic-interval 14

# 自訂磁碟門檻
/usr/local/bin/illumio_backup.sh --local --smb --min-free-local 20 --min-free-share 50
```

### 5.3 設定排程 (Crontab)
```bash
crontab -e
```
```bash
# 每天凌晨 2 點：備份到 SMB + SCP
0 2 * * * /usr/local/bin/illumio_backup.sh --smb --scp >/dev/null 2>&1

# 每天凌晨 2 點：本地 + SMB，Traffic 每 14 天備份一次
0 2 * * * /usr/local/bin/illumio_backup.sh --local --smb --traffic-interval 14 >/dev/null 2>&1
```

---

## 6. 備份內容與操作注意事項

- **`runtime_env.yml`**：每次符合頻率條件時備份（跟隨 `--db-interval`）
- **Policy Database**：每次符合頻率條件時 Dump（跟隨 `--db-interval`）
- **Traffic Database**：依 `--traffic-interval` 執行（預設每 7 天）；舊版的星期日硬編碼已移除
- **日誌位置**：啟用 `--local` 時位於 `LOCAL_BACKUP_DIR/logs/`；未啟用時位於 `/tmp/illumio-backup/logs/`，同時寫入 syslog
- **保留清理**：每次執行後，所有已啟用目的地都會自動清除超過保留天數的舊備份
- **沒有選目的地**：腳本立即印出錯誤並退出，不進行任何備份

---

## 7. 其他常用指令 (手動還原)

```bash
# 停止服務
sudo -u ilo-pce illumio-pce-ctl stop
# 以 Runlevel 1 啟動
sudo -u ilo-pce illumio-pce-ctl start --runlevel 1
# 等待集群狀態
sudo -u ilo-pce illumio-pce-ctl cluster-status -w

# 執行還原
sudo -u ilo-pce illumio-pce-db-management restore --file /path/to/backup.dump
sudo -u ilo-pce illumio-pce-db-management traffic restore --file /path/to/traffic.tar.gz

# Migrate Database
sudo -u ilo-pce illumio-pce-db-management migrate

# 恢復為 Runlevel 5 並關閉 Listen-only mode
sudo -u ilo-pce illumio-pce-ctl set-runlevel 5
sudo -u ilo-pce illumio-pce-ctl listen-only-mode disable
```
