# Illumio PCE 備份腳本架構與使用說明

**繁體中文** | [English](README.md)

## 1. 簡介與使用情境
此文件旨在說明 `illumio_backup.sh` 備份腳本的運作原理、決策邏輯以及如何自定義修改以符合您的環境。
此腳本可滿足在 Illumio PCE Cluster 架構下，自動識別主要節點、執行備份、轉移備份檔案至遠端 (SMB/NFS/SCP) 並實施檔案保留 (Retention) 策略。

## 2. 決策邏輯：為什麼這樣設計？
### 2.1 決定備份節點 (Determine the Primary Database)
在 Illumio PCE 的高可用性 (HA) 架構中，雖然所有核心節點都在運作，但**資料庫只有在主要 (Primary) 節點才可進行備份操作**。
根據官方手冊《Illumio Core 23.2 Administration.md》的指示，備份腳本必須從運行 `agent_traffic_redis_server` 服務的 Data Node 上執行。

**腳本中的實作方式：**
腳本會使用 `illumio-pce-ctl cluster-status` 指令，並過濾出運行 `agent_traffic_redis_server` 的節點 IP。
接著腳本將比對自身的 IP 是否為該 Leader IP：
- **是**：代表目前運行的這台伺服器是主要資料庫節點，腳本將繼續執行備份任務。
- **否**：代表這台伺服器只是備用或是非主要節點，腳本將會印出日誌並**安全退出**，不會執行任何備份。

這代表您可以將此腳本部署並設定排程 (Cronjob) 於所有的資料庫節點上。時間一到，所有節點都會被喚醒，但**只有真正的 Primary 節點會執行備份**，避免產生衝突與無效的備份檔案。

### 2.2 錯誤處理與日誌記錄 (Error Handling & Logging)
腳本內建 `log` 函數，所有的操作狀態都會：
1. **寫入本地日誌檔案**：儲存於 `/opt/illumio-backup/logs/` 內，方便未來除錯。
2. **傳送至 System log (Syslog)**：腳本會使用 `logger` 將日誌送進 `/var/log/messages`。如果您有設定 SIEM (如 Splunk, QRadar 等)，即可直接蒐集這些 syslog 作為備份成功與否的監控指標。

## 3. 安裝與設定說明
請在您想執行備份的 PCE 節點上執行以下步驟：

### 3.1 準備 SMB 網路作業系統掛載 (若有需要)
如果您打算將備份檔案傳送到 Windows SMB 分享資料夾，必須事先掛載 SMB 目錄。
請按以下步驟安裝相關套件與設定自動掛載：

1. **安裝 CIFS 套件**：
   ```bash
   dnf install cifs-utils -y
   ```

2. **建立 SMB 認證金鑰檔**：
   為了安全性，避免在設定檔中明文存放密碼，請建立憑證檔案：
   ```bash
   vi /root/smb.cred
   ```
   **內容如下：**
   ```ini
   username=您的SMB帳號
   password=您的SMB密碼
   domain=您的網域名稱 (若無可省略)
   ```
   設定金鑰檔權限：
   ```bash
   chmod 600 /root/smb.cred
   ```

3. **設定開機自動掛載 (`/etc/fstab`)**：
   新增以下內容到 `/etc/fstab`：
   ```bash
   //您的SMB伺服器IP或域名/分享資料夾路徑 /mnt/smb  cifs  credentials=/root/smb.cred  0 0
   ```
   *建立掛載目錄並載入：*
   ```bash
   mkdir -p /mnt/smb
   sudo mount -a
   systemctl daemon-reload
   ```

### 3.2 準備 NFS 網路掛載 (若有需要)
如果您打算將備份檔案傳送到 Linux/Unix 相容的 NFS 分享目錄，請進行以下掛載設定。
*(註：傳統的 NFS (v3/v4) **不需要**輸入帳號與密碼，而是依賴 NFS Server 端的 `/etc/exports` 設定來控制哪些 IP 或白名單來源可以存取與掛載。)*

1. **安裝 NFS 工具**：
   ```bash
   dnf install nfs-utils -y
   ```

2. **設定開機自動掛載 (`/etc/fstab`)**：
   新增以下內容到 `/etc/fstab`：
   ```bash
   您的NFS伺服器IP或域名:/分享資料夾路徑 /mnt/nfs  nfs  defaults  0 0
   ```
   *建立掛載目錄並載入：*
   ```bash
   mkdir -p /mnt/nfs
   sudo mount -a
   systemctl daemon-reload
   ```

### 3.3 準備 SCP 免密碼登入 (若有需要)
如果您打算將備份檔案傳輸到另一台遠端主機，必須設定 SSH 免密碼登入。

1. **產生 SSH 金鑰對 (若尚未產生)**：
   (過程中一路按 Enter 即可，**不要設定密碼 passphrase**) 
   ```bash
   ssh-keygen -t rsa -b 4096
   ```

2. **將公鑰傳送至遠端備份主機**：
   ```bash
   ssh-copy-id 目標使用者名稱@遠端主機IP
   ```

3. **測試連線**：
   嘗試登入，確認不需要輸入密碼即可成功連線：
   ```bash
   ssh 目標使用者名稱@遠端主機IP "ls -l"
   ```

### 3.4 準備腳本
1. 將腳本上傳至伺服器，例如放置於 `/usr/local/bin/illumio_backup.sh`。
2. 賦予執行權限：
   ```bash
   chmod +x /usr/local/bin/illumio_backup.sh
   ```

### 3.5 自定義變數 (Configuration Variables)
請使用文字編輯器打開腳本，並根據環境修改以下核心變數：


```bash
# 1. 本地備份設定
LOCAL_BACKUP_DIR="/opt/illumio-backup"    # 本地備份與日誌放置的目錄
RETENTION_DB_DAYS=7                       # Policy DB 與 Runtime Env 要保留的天數
RETENTION_TRAFFIC_DAYS=14                 # Traffic DB 要保留的天數

# 2. SMB/NFS 設定 (若不啟用可忽略)
SMB_MOUNT_POINT="/mnt/smb/illumio-backup" # SMB 網路磁碟機掛載點
NFS_MOUNT_POINT="/mnt/nfs/illumio-backup" # NFS 網路磁碟機掛載點

# 3. SCP (異地備援) 設定 (若不啟用可忽略)
DR_USER="root"                            # SCP 遠端登入帳號
DR_HOST="172.16.15.131"                   # SCP 遠端主機 IP
DR_DEST_DIR="/opt/illumio-backup"         # SCP 遠端主機儲存目錄
```

### 3.6 執行與參數
本腳本支援透過參數來決定備份要傳送到哪裡：

- **僅存放在本地：**
  ```bash
  /usr/local/bin/illumio_backup.sh
  ```
- **備份並傳送到 SMB 及 NFS：**
  ```bash
  /usr/local/bin/illumio_backup.sh --smb --nfs
  ```
- **備份並透過 SCP 傳送到遠端主機：**
  *(註：此功能需依賴 3.3 步驟完成免密碼設定)*
  ```bash
  /usr/local/bin/illumio_backup.sh --scp
  ```

### 3.7 設定排程 (Crontab)
為了自動化備份，請使用 `crontab -e` 加入以下排程 (舉例為每天凌晨 2 點執行，並傳送到 SCP 與 SMB)：

```bash
0 2 * * * /usr/local/bin/illumio_backup.sh --smb --scp >/dev/null 2>&1
```

## 4. 備份內容與頻率
本腳本涵蓋 Illumio PCE 的三大關鍵資料：
1. **`runtime_env.yml`**: PCE 運行環境設定檔 (每次備份皆會複製)。
2. **Policy Database**: 包含策略、物件、Workload 等設定 (每次備份皆會 Dump)。
3. **Traffic Database**: 包含流量紀錄 (Traffic Flow)。因為檔案通常極大，**腳本預設只有在星期日 (Sunday) 才會執行 Traffic 備份**。

## 5. 檔案保留策略 (Cleanup)
為了避免磁碟空間塞滿，腳本會在每個傳輸目標 (本地、SMB、NFS、SCP) 上執行清除動作。清除的條件依照 `RETENTION_DB_DAYS` 和 `RETENTION_TRAFFIC_DAYS` 設定。
只有超過這些天數的檔案兩端的備份點才會被刪除。腳本日誌預設保留 30 天。

## 6. 其他常用指令 (依據手冊)
如果需要手動還原，請參考以下流程：

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
