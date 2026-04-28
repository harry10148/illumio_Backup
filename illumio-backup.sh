#!/bin/bash

# --- Set PATH environment ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# ==============================================================================
# [SCRIPT CONFIGURATION] — 可依環境調整以下預設值
# ==============================================================================

# 1. Local Backup Settings
LOCAL_BACKUP_DIR="/opt/illumio-backup"
RETENTION_DB_DAYS=7
RETENTION_TRAFFIC_DAYS=14

# 2. SMB/NFS Settings
SMB_MOUNT_POINT="/mnt/smb/illumio-backup"
NFS_MOUNT_POINT="/mnt/nfs/illumio-backup"

# 3. SCP (DR Site) Settings
DR_USER="root"
DR_HOST="172.16.15.131"
DR_DEST_DIR="/opt/illumio-backup"
SCP_TIMEOUT=30

# 4. Disk Space Guard (單位: GB)
#    備份前若目的地可用空間低於門檻，腳本拒絕寫入並中止
MIN_FREE_GB_LOCAL=5    # 本地備份最低剩餘空間
MIN_FREE_GB_SHARE=10   # SMB/NFS Fileshare 最低剩餘空間
MIN_FREE_GB_REMOTE=10  # SCP 遠端主機最低剩餘空間

# 5. Backup Frequency (單位: 天; 透過 --db-interval / --traffic-interval 覆寫)
#    腳本會依最後備份檔案的修改時間判斷是否需要執行
DB_INTERVAL=1         # Policy DB 備份間隔（預設每天）
TRAFFIC_INTERVAL=7    # Traffic DB 備份間隔（預設每週）

# ==============================================================================
# [DEFAULT SWITCHES]
# ==============================================================================
ENABLE_LOCAL=false
ENABLE_SMB=false
ENABLE_NFS=false
ENABLE_SCP=false

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

必須至少選擇一個備份目的地 (--local / --smb / --nfs / --scp)。

目的地選項:
  --local                  備份到本地目錄 (${LOCAL_BACKUP_DIR})
  --smb                    備份到 SMB/CIFS 共用資料夾 (${SMB_MOUNT_POINT})
  --nfs                    備份到 NFS 共用資料夾 (${NFS_MOUNT_POINT})
  --scp                    備份到遠端主機 (${DR_USER}@${DR_HOST}:${DR_DEST_DIR})

頻率設定:
  --db-interval <天>       Policy DB 備份間隔天數 (預設: ${DB_INTERVAL})
  --traffic-interval <天>  Traffic DB 備份間隔天數 (預設: ${TRAFFIC_INTERVAL})

保留期限:
  --retention-db <天>      DB/Env 檔案保留天數 (預設: ${RETENTION_DB_DAYS})
  --retention-traffic <天> Traffic 檔案保留天數 (預設: ${RETENTION_TRAFFIC_DAYS})

空間門檻:
  --min-free-local <GB>    本地最低剩餘空間 (預設: ${MIN_FREE_GB_LOCAL})
  --min-free-share <GB>    Fileshare 最低剩餘空間 (預設: ${MIN_FREE_GB_SHARE})
  --min-free-remote <GB>   遠端主機最低剩餘空間 (預設: ${MIN_FREE_GB_REMOTE})
EOF
}

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --local)   ENABLE_LOCAL=true ;;
        --smb)     ENABLE_SMB=true ;;
        --nfs)     ENABLE_NFS=true ;;
        --scp)     ENABLE_SCP=true ;;
        --db-interval)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --db-interval 需要一個正整數" >&2
                exit 1
            fi
            DB_INTERVAL="$2"; shift ;;
        --traffic-interval)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --traffic-interval 需要一個正整數" >&2
                exit 1
            fi
            TRAFFIC_INTERVAL="$2"; shift ;;
        --retention-db)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --retention-db 需要一個正整數" >&2
                exit 1
            fi
            RETENTION_DB_DAYS="$2"; shift ;;
        --retention-traffic)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --retention-traffic 需要一個正整數" >&2
                exit 1
            fi
            RETENTION_TRAFFIC_DAYS="$2"; shift ;;
        --min-free-local)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --min-free-local 需要一個正整數" >&2
                exit 1
            fi
            MIN_FREE_GB_LOCAL="$2"; shift ;;
        --min-free-share)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --min-free-share 需要一個正整數" >&2
                exit 1
            fi
            MIN_FREE_GB_SHARE="$2"; shift ;;
        --min-free-remote)
            if [[ -z "$2" ]] || ! is_positive_int "$2"; then
                echo "ERROR: --min-free-remote 需要一個正整數" >&2
                exit 1
            fi
            MIN_FREE_GB_REMOTE="$2"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "ERROR: 未知參數: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# --- 驗證：必須至少選擇一個備份目的地 ---
if [[ "$ENABLE_LOCAL" == false && "$ENABLE_SMB" == false && \
      "$ENABLE_NFS" == false  && "$ENABLE_SCP" == false ]]; then
    echo "ERROR: 請至少指定一個備份目的地 (--local / --smb / --nfs / --scp)" >&2
    echo "       執行 $(basename "$0") --help 查看完整說明" >&2
    exit 1
fi

# ==============================================================================
# SYSTEM VARIABLES
# ==============================================================================
TODAY=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u)   # 1=Mon ... 7=Sun
PCE_HOSTNAME=$(hostname)

# LOG_DIR: 本地備份啟用時使用正規路徑，否則使用 /tmp 暫存
if [[ "$ENABLE_LOCAL" == true ]]; then
    LOG_DIR="${LOCAL_BACKUP_DIR}/logs"
else
    LOG_DIR="/tmp/illumio-backup/logs"
fi
LOG_FILE="${LOG_DIR}/backup_$(date +%Y%m%d_%H%M%S).log"
HARD_FAILURE=false

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# log — 同時寫入 log 檔與 syslog
log() {
    local LEVEL="$1"
    local MSG="$2"
    local TIMESTAMP
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

    if [[ -d "${LOG_DIR}" && -w "${LOG_DIR}" ]]; then
        echo "[${TIMESTAMP}] [${LEVEL}] ${MSG}" | tee -a "$LOG_FILE"
    else
        echo "[${TIMESTAMP}] [${LEVEL}] ${MSG}"
    fi

    if [[ "$LEVEL" == "ERROR" ]]; then
        logger -p user.err  -t "illumio-backup" "${MSG}"
    else
        logger -p user.info -t "illumio-backup" "${MSG}"
    fi
}

die() {
    log "ERROR" "$1"
    exit 1
}

# setup_env — 建立必要目錄結構
setup_env() {
    # LOG_DIR 永遠需要
    mkdir -p "$LOG_DIR" || { echo "ERROR: 無法建立 LOG_DIR: $LOG_DIR" >&2; exit 1; }
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"

    # LOCAL_BACKUP_DIR 只在 --local 啟用時建立
    if [[ "$ENABLE_LOCAL" == true ]]; then
        mkdir -p "$LOCAL_BACKUP_DIR" || die "無法建立本地備份目錄: $LOCAL_BACKUP_DIR"
        if ! chown -R ilo-pce:ilo-pce "$LOCAL_BACKUP_DIR" 2>/dev/null; then
            log "WARN" "無法 chown $LOCAL_BACKUP_DIR (需要 root 權限)，請手動確認目錄擁有者"
        fi
    fi
}

is_smb_ready() {
    [[ -d "$SMB_MOUNT_POINT" ]] && df -T "$SMB_MOUNT_POINT" 2>/dev/null | grep -qE "cifs|smb"
}

is_nfs_ready() {
    [[ -d "$NFS_MOUNT_POINT" ]] && df -T "$NFS_MOUNT_POINT" 2>/dev/null | grep -q "nfs"
}

# ------------------------------------------------------------------------------
# check_disk_space — 檢查指定掛載點的剩餘空間
#   $1: 掛載點或路徑
#   $2: 最低門檻 (GB)
#   $3: 顯示標籤
# ------------------------------------------------------------------------------
check_disk_space() {
    local MOUNT="$1"
    local MIN_GB="$2"
    local LABEL="$3"

    local FREE_KB
    FREE_KB=$(df -k "$MOUNT" 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ -z "$FREE_KB" ]]; then
        die "[DISK] 無法取得 $LABEL ($MOUNT) 的磁碟資訊，備份中止"
    fi

    local FREE_GB=$(( FREE_KB / 1024 / 1024 ))

    if [[ "$FREE_GB" -lt "$MIN_GB" ]]; then
        die "[DISK] $LABEL 剩餘空間不足 (${FREE_GB} GB < 門檻 ${MIN_GB} GB)，備份中止！"
    fi

    log "INFO" "[DISK] $LABEL 剩餘空間充足: ${FREE_GB} GB (門檻: ${MIN_GB} GB)"
}

# check_remote_disk_space — 透過 SSH 檢查遠端主機剩餘空間
check_remote_disk_space() {
    local MIN_GB="$1"
    local FREE_KB

    FREE_KB=$(ssh -o ConnectTimeout=10 "$DR_USER@$DR_HOST" \
        "df -k $DR_DEST_DIR 2>/dev/null | awk 'NR==2 {print \$4}'" 2>/dev/null)

    if [[ -z "$FREE_KB" ]]; then
        die "[DISK] 無法取得遠端主機 ${DR_HOST}:${DR_DEST_DIR} 的磁碟資訊"
    fi

    local FREE_GB=$(( FREE_KB / 1024 / 1024 ))

    if [[ "$FREE_GB" -lt "$MIN_GB" ]]; then
        die "[DISK] 遠端主機 ${DR_HOST} 剩餘空間不足 (${FREE_GB} GB < 門檻 ${MIN_GB} GB)，備份中止！"
    fi

    log "INFO" "[DISK] 遠端主機 ${DR_HOST} 剩餘空間充足: ${FREE_GB} GB (門檻: ${MIN_GB} GB)"
}

# ------------------------------------------------------------------------------
# days_since_last_backup — 回傳指定目錄中最後一個符合 pattern 的檔案距今天數
#   $1: 搜尋目錄
#   $2: 檔案名稱 glob pattern
#   回傳: 天數 (整數)，若找不到任何檔案則回傳 9999
# ------------------------------------------------------------------------------
days_since_last_backup() {
    local SEARCH_DIR="$1"
    local PATTERN="$2"

    [[ -d "$SEARCH_DIR" ]] || { echo 9999; return; }

    local LAST_FILE
    LAST_FILE=$(find "$SEARCH_DIR" -maxdepth 1 -name "$PATTERN" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | tail -1 | cut -d' ' -f2-)

    if [[ -z "$LAST_FILE" ]]; then
        echo 9999
        return
    fi

    local LAST_MTIME NOW DIFF
    LAST_MTIME=$(stat -c %Y "$LAST_FILE" 2>/dev/null)
    NOW=$(date +%s)
    DIFF=$(( (NOW - LAST_MTIME) / 86400 ))
    echo "$DIFF"
}

remote_days_since_last_backup() {
    local PATTERN="$1"
    local LAST_MTIME

    LAST_MTIME=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$DR_USER@$DR_HOST" \
        "find '$DR_DEST_DIR' -maxdepth 1 -name '$PATTERN' -printf '%T@\n' 2>/dev/null | sort -n | tail -1" \
        2>/dev/null)

    if [[ -z "$LAST_MTIME" ]]; then
        echo 9999
        return
    fi

    LAST_MTIME=${LAST_MTIME%.*}
    [[ "$LAST_MTIME" =~ ^[0-9]+$ ]] || { echo 9999; return; }

    local NOW DIFF
    NOW=$(date +%s)
    DIFF=$(( (NOW - LAST_MTIME) / 86400 ))
    echo "$DIFF"
}

days_since_last_backup_enabled_destinations() {
    local PATTERN="$1"
    local MIN_DAYS=9999
    local DAYS

    if [[ "$ENABLE_LOCAL" == true ]]; then
        DAYS=$(days_since_last_backup "$LOCAL_BACKUP_DIR" "$PATTERN")
        [[ "$DAYS" -lt "$MIN_DAYS" ]] && MIN_DAYS="$DAYS"
    fi

    if [[ "$ENABLE_SMB" == true ]] && is_smb_ready; then
        DAYS=$(days_since_last_backup "$SMB_MOUNT_POINT" "$PATTERN")
        [[ "$DAYS" -lt "$MIN_DAYS" ]] && MIN_DAYS="$DAYS"
    fi

    if [[ "$ENABLE_NFS" == true ]] && is_nfs_ready; then
        DAYS=$(days_since_last_backup "$NFS_MOUNT_POINT" "$PATTERN")
        [[ "$DAYS" -lt "$MIN_DAYS" ]] && MIN_DAYS="$DAYS"
    fi

    if [[ "$ENABLE_SCP" == true ]]; then
        DAYS=$(remote_days_since_last_backup "$PATTERN")
        [[ "$DAYS" -lt "$MIN_DAYS" ]] && MIN_DAYS="$DAYS"
    fi

    echo "$MIN_DAYS"
}

# ------------------------------------------------------------------------------
# should_run_backup — 判斷此次是否應執行備份
#   $1: 備份類型描述
#   $2: 間隔天數
#   $3: 最後備份距今天數
#   回傳: 0=執行, 1=跳過
# ------------------------------------------------------------------------------
should_run_backup() {
    local LABEL="$1"
    local INTERVAL="$2"
    local DAYS_SINCE="$3"

    if [[ "$DAYS_SINCE" -lt "$INTERVAL" ]]; then
        log "INFO" "[FREQ] $LABEL 上次備份距今 ${DAYS_SINCE} 天 (間隔 ${INTERVAL} 天)，本次跳過"
        return 1
    fi

    log "INFO" "[FREQ] $LABEL 上次備份距今 ${DAYS_SINCE} 天 (間隔 ${INTERVAL} 天)，執行備份"
    return 0
}

# ------------------------------------------------------------------------------
# process_file — 將備份檔案送往各已啟用的目的地
#   $1: 完整檔案路徑（已在本地產生的原始備份檔）
# ------------------------------------------------------------------------------
process_file() {
    local FILE_PATH="$1"
    local FILE_NAME
    local STORED=false
    FILE_NAME=$(basename "$FILE_PATH")

    if [[ "$ENABLE_LOCAL" == true ]] && [[ -f "$FILE_PATH" ]]; then
        STORED=true
    fi

    # 1. SMB Transfer
    if [[ "$ENABLE_SMB" == true ]]; then
        if is_smb_ready; then
            if cp -p "$FILE_PATH" "$SMB_MOUNT_POINT/"; then
                log "INFO" "[SMB] Copy Success: $FILE_NAME"
                STORED=true
            else
                log "ERROR" "[SMB] Copy Failed: $FILE_NAME"
            fi
        else
            log "WARN" "[SMB] 目標不是有效的 CIFS 掛載點或目錄不存在，跳過"
        fi
    fi

    # 2. NFS Transfer
    if [[ "$ENABLE_NFS" == true ]]; then
        if is_nfs_ready; then
            if cp -p "$FILE_PATH" "$NFS_MOUNT_POINT/"; then
                log "INFO" "[NFS] Copy Success: $FILE_NAME"
                STORED=true
            else
                log "ERROR" "[NFS] Copy Failed: $FILE_NAME"
            fi
        else
            log "WARN" "[NFS] 目標不是有效的 NFS 掛載點或目錄不存在，跳過"
        fi
    fi

    # 3. SCP Transfer — 先確認 SSH 可連線再執行 scp
    if [[ "$ENABLE_SCP" == true ]]; then
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$DR_USER@$DR_HOST" "mkdir -p $DR_DEST_DIR" 2>/dev/null; then
            if scp -o ConnectTimeout="${SCP_TIMEOUT}" -p "$FILE_PATH" "$DR_USER@$DR_HOST:$DR_DEST_DIR/"; then
                log "INFO" "[SCP] Transfer Success: $FILE_NAME"
                STORED=true
            else
                log "ERROR" "[SCP] Transfer Failed: $FILE_NAME"
            fi
        else
            log "ERROR" "[SCP] 無法連線到遠端主機 ${DR_HOST}，跳過 $FILE_NAME"
        fi
    fi

    if [[ "$STORED" == false ]]; then
        log "ERROR" "[DEST] 所有目的地均未成功保存檔案: $FILE_NAME"
        return 1
    fi

    return 0
}

# ==============================================================================
# PHASE 1: Initialization & Role Detection
# ==============================================================================

setup_env
log "INFO" "========================================="
log "INFO" "Backup Process Initiated on $PCE_HOSTNAME"
log "INFO" "目的地設定 — LOCAL:${ENABLE_LOCAL} SMB:${ENABLE_SMB} NFS:${ENABLE_NFS} SCP:${ENABLE_SCP}"
log "INFO" "頻率設定 — DB: 每 ${DB_INTERVAL} 天 | Traffic: 每 ${TRAFFIC_INTERVAL} 天"

log "INFO" "正在檢查 cluster 狀態以確認備份主節點..."

# 確認 agent_traffic_redis_server 所在節點 IP
LEADER_IP=$(sudo -u ilo-pce illumio-pce-ctl cluster-status 2>/dev/null \
    | grep "agent_traffic_redis_server" | awk '{print $2}' | head -1)

if [[ -z "$LEADER_IP" ]]; then
    die "無法偵測 'agent_traffic_redis_server' IP。請確認 PCE 正在運行且 runlevel 為 5。"
fi

log "INFO" "偵測到備份主節點 IP: $LEADER_IP"

if ! /usr/sbin/ip addr show 2>/dev/null | grep -q "$LEADER_IP"; then
    log "INFO" "[ROLE] 本節點非備份主節點 (主節點為 $LEADER_IP)，正常退出"
    exit 0
else
    log "INFO" "[ROLE] 本節點 ($LEADER_IP) 為備份主節點，繼續執行備份"
fi

# ==============================================================================
# PHASE 1.5: Disk Space Pre-Check
# ==============================================================================

log "INFO" "--- 磁碟空間預先檢查 ---"

if [[ "$ENABLE_LOCAL" == true ]]; then
    check_disk_space "$LOCAL_BACKUP_DIR" "$MIN_FREE_GB_LOCAL" "本地備份目錄"
fi

if [[ "$ENABLE_SMB" == true ]] && is_smb_ready; then
    check_disk_space "$SMB_MOUNT_POINT" "$MIN_FREE_GB_SHARE" "SMB Fileshare"
fi

if [[ "$ENABLE_NFS" == true ]] && is_nfs_ready; then
    check_disk_space "$NFS_MOUNT_POINT" "$MIN_FREE_GB_SHARE" "NFS Fileshare"
fi

if [[ "$ENABLE_SCP" == true ]]; then
    check_remote_disk_space "$MIN_FREE_GB_REMOTE"
fi

# ==============================================================================
# PHASE 2: Backup Execution
# ==============================================================================

# --- 工作目錄：備份檔案暫存於本地，完成後再分送 ---
# 若 --local 未啟用，使用 /tmp 暫存後轉送，轉送完畢即刪除
if [[ "$ENABLE_LOCAL" == true ]]; then
    WORK_DIR="$LOCAL_BACKUP_DIR"
else
    PRESERVE_WORK_DIR=false
    WORK_DIR=$(mktemp -d /tmp/illumio-backup-XXXXXX)
    log "INFO" "本地備份未啟用，使用暫存目錄: $WORK_DIR"
    # 腳本結束時清除暫存目錄
    trap '[[ "$PRESERVE_WORK_DIR" == true ]] || rm -rf "$WORK_DIR"' EXIT
fi

# --- 2-1. Backup Runtime Environment File ---
log "INFO" "[TASK] 備份 runtime_env.yml"
RUNTIME_FILE="runtime_env_${TODAY}.yml"
RUNTIME_FULL_PATH="${WORK_DIR}/${RUNTIME_FILE}"

# 頻率檢查 (runtime_env 跟隨 DB 間隔)
DAYS_SINCE_ENV=$(days_since_last_backup_enabled_destinations "runtime_env_*.yml")
if should_run_backup "Runtime Env" "$DB_INTERVAL" "$DAYS_SINCE_ENV"; then
    if [[ -f /etc/illumio-pce/runtime_env.yml ]]; then
        if cp /etc/illumio-pce/runtime_env.yml "$RUNTIME_FULL_PATH"; then
            log "INFO" "Runtime env 備份至 $RUNTIME_FULL_PATH"
            if process_file "$RUNTIME_FULL_PATH"; then
                # 若本地未啟用，轉送完畢後刪除暫存檔
                [[ "$ENABLE_LOCAL" == false ]] && rm -f "$RUNTIME_FULL_PATH"
            else
                HARD_FAILURE=true
                if [[ "$ENABLE_LOCAL" == false ]]; then
                    PRESERVE_WORK_DIR=true
                    log "ERROR" "[DEST] 保留暫存檔供排查: $RUNTIME_FULL_PATH"
                fi
            fi
        else
            log "ERROR" "無法複製 runtime_env.yml 到工作目錄"
        fi
    else
        log "ERROR" "runtime_env.yml 不存在於 /etc/illumio-pce/runtime_env.yml"
    fi
fi

# --- 2-2. Policy Database Backup ---
log "INFO" "[TASK] 備份 Policy Database"
DB_FILE="ilo-db-bak-${TODAY}.dump"
FULL_DB_PATH="${WORK_DIR}/${DB_FILE}"

# 頻率檢查
DAYS_SINCE_DB=$(days_since_last_backup_enabled_destinations "ilo-db-bak-*.dump")
if should_run_backup "Policy DB" "$DB_INTERVAL" "$DAYS_SINCE_DB"; then
    if sudo -u ilo-pce illumio-pce-db-management dump --file "$FULL_DB_PATH" >> "$LOG_FILE" 2>&1; then
        if [[ -f "$FULL_DB_PATH" ]]; then
            log "INFO" "Policy DB 備份成功: $DB_FILE"
            if process_file "$FULL_DB_PATH"; then
                [[ "$ENABLE_LOCAL" == false ]] && rm -f "$FULL_DB_PATH"
            else
                HARD_FAILURE=true
                if [[ "$ENABLE_LOCAL" == false ]]; then
                    PRESERVE_WORK_DIR=true
                    log "ERROR" "[DEST] 保留暫存檔供排查: $FULL_DB_PATH"
                fi
            fi
        else
            log "ERROR" "Policy DB 命令完成，但找不到輸出檔案: $FULL_DB_PATH"
        fi
    else
        log "ERROR" "Policy DB 備份命令失敗！"
    fi
fi

# --- 2-3. Traffic Database Backup ---
log "INFO" "[TASK] 檢查 Traffic Database 備份頻率"
TRAFFIC_FILE="ilo-traffic-bak-${TODAY}.tar.gz"
FULL_TRAFFIC_PATH="${WORK_DIR}/${TRAFFIC_FILE}"

DAYS_SINCE_TRAFFIC=$(days_since_last_backup_enabled_destinations "ilo-traffic-bak-*.tar.gz")
if should_run_backup "Traffic DB" "$TRAFFIC_INTERVAL" "$DAYS_SINCE_TRAFFIC"; then
    if sudo -u ilo-pce illumio-pce-db-management traffic dump --file "$FULL_TRAFFIC_PATH" >> "$LOG_FILE" 2>&1; then
        if [[ -f "$FULL_TRAFFIC_PATH" ]]; then
            log "INFO" "Traffic DB 備份成功: $TRAFFIC_FILE"
            if process_file "$FULL_TRAFFIC_PATH"; then
                [[ "$ENABLE_LOCAL" == false ]] && rm -f "$FULL_TRAFFIC_PATH"
            else
                HARD_FAILURE=true
                if [[ "$ENABLE_LOCAL" == false ]]; then
                    PRESERVE_WORK_DIR=true
                    log "ERROR" "[DEST] 保留暫存檔供排查: $FULL_TRAFFIC_PATH"
                fi
            fi
        else
            log "ERROR" "Traffic DB 命令完成，但找不到輸出檔案: $FULL_TRAFFIC_PATH"
        fi
    else
        log "ERROR" "Traffic DB 備份命令失敗！"
    fi
fi

# ==============================================================================
# PHASE 3: Retention & Cleanup
# ==============================================================================

log "INFO" "[CLEANUP] 執行保留政策: DB/Env (${RETENTION_DB_DAYS}d), Traffic (${RETENTION_TRAFFIC_DAYS}d)"

# 清理指定目錄的舊備份 (不使用 eval，直接呼叫 find)
cleanup_dir() {
    local DIR="$1"
    local LABEL="$2"

    # 防護：目錄路徑不可為空
    if [[ -z "$DIR" || ! -d "$DIR" ]]; then
        log "WARN" "[CLEANUP] $LABEL 目錄不存在或路徑為空，跳過清理"
        return
    fi

    log "INFO" "[CLEANUP] 清理 $LABEL: $DIR"
    find "$DIR" -maxdepth 1 -name 'ilo-db-bak-*.dump'        -mtime +"$RETENTION_DB_DAYS"      -delete
    find "$DIR" -maxdepth 1 -name 'ilo-traffic-bak-*.tar.gz' -mtime +"$RETENTION_TRAFFIC_DAYS"  -delete
    find "$DIR" -maxdepth 1 -name 'runtime_env_*.yml'         -mtime +"$RETENTION_DB_DAYS"      -delete
}

# 1. Local Cleanup
if [[ "$ENABLE_LOCAL" == true ]]; then
    cleanup_dir "$LOCAL_BACKUP_DIR" "本地備份目錄"
fi

# 2. SMB Cleanup
if [[ "$ENABLE_SMB" == true ]] && \
   is_smb_ready; then
    cleanup_dir "$SMB_MOUNT_POINT" "SMB"
fi

# 3. NFS Cleanup
if [[ "$ENABLE_NFS" == true ]] && \
   is_nfs_ready; then
    cleanup_dir "$NFS_MOUNT_POINT" "NFS"
fi

# 4. SCP (Remote) Cleanup
if [[ "$ENABLE_SCP" == true ]]; then
    log "INFO" "[CLEANUP] 清理遠端主機 ${DR_HOST}:${DR_DEST_DIR}"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$DR_USER@$DR_HOST" \
        "find '$DR_DEST_DIR' -maxdepth 1 -name 'ilo-db-bak-*.dump'        -mtime +${RETENTION_DB_DAYS}      -delete; \
         find '$DR_DEST_DIR' -maxdepth 1 -name 'ilo-traffic-bak-*.tar.gz' -mtime +${RETENTION_TRAFFIC_DAYS}  -delete; \
         find '$DR_DEST_DIR' -maxdepth 1 -name 'runtime_env_*.yml'         -mtime +${RETENTION_DB_DAYS}      -delete" \
    || log "WARN" "[CLEANUP] 遠端清理失敗，請手動確認"
fi

# 5. Log Cleanup (保留 30 天)
log "INFO" "[CLEANUP] 清理舊 log 檔 (保留 30 天)..."
find "$LOG_DIR" -type f -name 'backup_*.log' -mtime +30 -delete

if [[ "$HARD_FAILURE" == true ]]; then
    log "ERROR" "Backup Process Completed With Errors."
    log "ERROR" "========================================="
    exit 1
fi

log "INFO" "Backup Process Completed Successfully."
log "INFO" "========================================="
exit 0
