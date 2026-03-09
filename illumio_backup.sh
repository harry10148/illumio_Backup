#!/bin/bash

# --- Set PATH environment ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- [SCRIPT CONFIGURATION] ---

# 1. Local Backup Settings
LOCAL_BACKUP_DIR="/opt/illumio-backup"
LOG_DIR="${LOCAL_BACKUP_DIR}/logs"
RETENTION_DB_DAYS=7
RETENTION_TRAFFIC_DAYS=14
LOG_FILE="${LOG_DIR}/backup_$(date +%Y%m%d_%H%M%S).log"

# 2. SMB/NFS Settings
SMB_MOUNT_POINT="/mnt/smb/illumio-backup"
NFS_MOUNT_POINT="/mnt/nfs/illumio-backup"

# 3. SCP (DR Site) Settings
DR_USER="root"
DR_HOST="172.16.15.131"
DR_DEST_DIR="/opt/illumio-backup"
SCP_TIMEOUT=30

# --- [DEFAULT SWITCHES] ---
ENABLE_SMB=false
ENABLE_NFS=false
ENABLE_SCP=false

# --- Parse Arguments ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --smb) ENABLE_SMB=true ;;
        --nfs) ENABLE_NFS=true ;;
        --scp) ENABLE_SCP=true ;;
        *) echo "Unknown parameter: $1" >&2; exit 1 ;;
    esac
    shift
done

# --- System Variables ---
TODAY=$(date +%Y%m%d)
DAY_OF_WEEK=$(date +%u) # 1=Mon ... 7=Sun
HOSTNAME=$(hostname)

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

# Custom logging function (Logs to file and syslog)
log() {
    local LEVEL="$1"
    local MSG="$2"
    local TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    
    # Check if log dir/file exists and is writable, fallback to echo if not yet setup
    if [[ -d "${LOG_DIR}" && -w "${LOG_DIR}" ]]; then
        echo "[${TIMESTAMP}] [${LEVEL}] ${MSG}" | tee -a "$LOG_FILE"
    else
        echo "[${TIMESTAMP}] [${LEVEL}] ${MSG}"
    fi

    # Write to syslog
    if [[ "$LEVEL" == "ERROR" ]]; then
        logger -p user.err -t "illumio-backup" "${MSG}"
    else
        logger -p user.info -t "illumio-backup" "${MSG}"
    fi
}

die() {
    log "ERROR" "$1"
    exit 1
}

setup_env() {
    mkdir -p "$LOCAL_BACKUP_DIR"
    mkdir -p "$LOG_DIR"
    chown -R ilo-pce:ilo-pce "$LOCAL_BACKUP_DIR"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# --- Function: File Transfer ---
process_file() {
    local FILE_PATH="$1"
    local FILE_NAME=$(basename "$FILE_PATH")

    # 1. Process SMB Transfer
    if [ "$ENABLE_SMB" = true ]; then
        if [ -d "$SMB_MOUNT_POINT" ] && df -T "$SMB_MOUNT_POINT" | grep -E "cifs|smb" > /dev/null; then
            cp -p "$FILE_PATH" "$SMB_MOUNT_POINT/" && log "INFO" "[SMB] Copy Success: $FILE_NAME" || log "ERROR" "[SMB] Copy Failed: $FILE_NAME"
        else
            log "WARN" "[SMB] Target is not a valid CIFS mount or directory is missing. Skipping."
        fi
    fi
    
    # 2. Process NFS Transfer
    if [ "$ENABLE_NFS" = true ]; then
        if [ -d "$NFS_MOUNT_POINT" ] && df -T "$NFS_MOUNT_POINT" | grep -q "nfs"; then
            cp -p "$FILE_PATH" "$NFS_MOUNT_POINT/" && log "INFO" "[NFS] Copy Success: $FILE_NAME" || log "ERROR" "[NFS] Copy Failed: $FILE_NAME"
        else
            log "WARN" "[NFS] Target is not a valid NFS mount or directory is missing. Skipping."
        fi
    fi

    # 3. Process SCP Transfer
    if [ "$ENABLE_SCP" = true ]; then
        ssh -o ConnectTimeout=5 "$DR_USER@$DR_HOST" "mkdir -p $DR_DEST_DIR" 2>/dev/null
        scp -o ConnectTimeout=${SCP_TIMEOUT} -p "$FILE_PATH" "$DR_USER@$DR_HOST:$DR_DEST_DIR/" && log "INFO" "[SCP] Transfer Success: $FILE_NAME" || log "ERROR" "[SCP] Transfer Failed: $FILE_NAME"
    fi
}

# ==============================================================================
# PHASE 1: Initialization & Role Detection
# ==============================================================================

setup_env
log "INFO" "========================================="
log "INFO" "Backup Process Initiated on $HOSTNAME"

log "INFO" "Checking cluster status to determine primary backup node..."

# According to Illumio Core 23.2 Administration manual:
# "determine which data node is running the agent_traffic_redis_server service... run the dump command from this node"
LEADER_IP=$(sudo -u ilo-pce illumio-pce-ctl cluster-status | grep "agent_traffic_redis_server" | awk '{print $2}')

if [ -z "$LEADER_IP" ]; then
    die "Could not detect 'agent_traffic_redis_server' IP. Ensure PCE is running and runlevel is 5."
fi

log "INFO" "Detected Backup Leader IP: $LEADER_IP"

# Check if the local machine owns this IP
if ! /usr/sbin/ip addr show | grep -q "$LEADER_IP"; then
    log "INFO" "[ROLE] This node is NOT the Backup Leader (Leader is $LEADER_IP)."
    log "INFO" ">>> Exiting script gracefully. No backup needed on this node."
    exit 0
else
    log "INFO" "[ROLE] This node ($LEADER_IP) IS the Backup Leader node. Proceeding with backup."
fi

# ==============================================================================
# PHASE 2: Backup Execution
# ==============================================================================

# --- 1. Backup Runtime Environment File ---
log "INFO" "[TASK] Backing up runtime_env.yml"
RUNTIME_FILE="runtime_env_${TODAY}.yml"
RUNTIME_FULL_PATH="$LOCAL_BACKUP_DIR/$RUNTIME_FILE"

if [ -f /etc/illumio-pce/runtime_env.yml ]; then
    cp /etc/illumio-pce/runtime_env.yml "$RUNTIME_FULL_PATH"
    log "INFO" "Runtime env backed up to $RUNTIME_FULL_PATH"
    process_file "$RUNTIME_FULL_PATH"
else
    log "ERROR" "runtime_env.yml not found at /etc/illumio-pce/runtime_env.yml!"
fi

# --- 2. Daily Policy Database Backup ---
log "INFO" "[TASK] Backing up Policy Database (illumio-pce-db-management dump)"
DB_FILE="ilo-db-bak-${TODAY}.dump"
FULL_DB_PATH="$LOCAL_BACKUP_DIR/$DB_FILE"

# Make sure to run the actual dump command
if sudo -u ilo-pce illumio-pce-db-management dump --file "$FULL_DB_PATH" >> "$LOG_FILE" 2>&1; then
    if [ -f "$FULL_DB_PATH" ]; then
        log "INFO" "[LOCAL] Policy DB generated successfully: $DB_FILE"
        process_file "$FULL_DB_PATH"
    else
        log "ERROR" "Policy DB generation completed, but file not found: $FULL_DB_PATH"
    fi
else
    log "ERROR" "Policy DB generation command failed!"
fi

# --- 3. Weekly Traffic Database Backup (Sundays Only) ---
if [ "$DAY_OF_WEEK" -eq 7 ]; then
    log "INFO" "[TASK] Backing up Traffic Database (Sunday Task)"
    TRAFFIC_FILE="ilo-traffic-bak-${TODAY}.tar.gz"
    FULL_TRAFFIC_PATH="$LOCAL_BACKUP_DIR/$TRAFFIC_FILE"

    if sudo -u ilo-pce illumio-pce-db-management traffic dump --file "$FULL_TRAFFIC_PATH" >> "$LOG_FILE" 2>&1; then
        if [ -f "$FULL_TRAFFIC_PATH" ]; then
            log "INFO" "[LOCAL] Traffic DB generated successfully: $TRAFFIC_FILE"
            process_file "$FULL_TRAFFIC_PATH"
        else
            log "ERROR" "Traffic DB generation completed, but file not found: $FULL_TRAFFIC_PATH"
        fi
    else
       log "ERROR" "Traffic DB generation command failed!"
    fi
else
    log "INFO" "Not Sunday (Today is day $DAY_OF_WEEK). Skipping Traffic DB backup."
fi

# ==============================================================================
# PHASE 3: Retention & Cleanup
# ==============================================================================

log "INFO" "[CLEANUP] Enforcing retention policy: DB/Env (${RETENTION_DB_DAYS}d), Traffic (${RETENTION_TRAFFIC_DAYS}d)"

CMD_CLEAN_DB="find . -maxdepth 1 -name 'ilo-db-bak-*.dump' -mtime +$RETENTION_DB_DAYS -delete"
CMD_CLEAN_TRAFFIC="find . -maxdepth 1 -name 'ilo-traffic-bak-*.tar.gz' -mtime +$RETENTION_TRAFFIC_DAYS -delete"
CMD_CLEAN_ENV="find . -maxdepth 1 -name 'runtime_env_*.yml' -mtime +$RETENTION_DB_DAYS -delete"

# 1. Local Cleanup
log "INFO" "Cleaning Local Backup Directory..."
(cd "$LOCAL_BACKUP_DIR" && eval "$CMD_CLEAN_DB" && eval "$CMD_CLEAN_TRAFFIC" && eval "$CMD_CLEAN_ENV")

# 2. SMB Cleanup
if [ "$ENABLE_SMB" = true ] && [ -d "$SMB_MOUNT_POINT" ] && df -T "$SMB_MOUNT_POINT" | grep -E "cifs|smb" > /dev/null; then
    log "INFO" "Cleaning SMB Directory..."
    (cd "$SMB_MOUNT_POINT" && eval "$CMD_CLEAN_DB" && eval "$CMD_CLEAN_TRAFFIC" && eval "$CMD_CLEAN_ENV")
fi

# 3. NFS Cleanup
if [ "$ENABLE_NFS" = true ] && [ -d "$NFS_MOUNT_POINT" ] && df -T "$NFS_MOUNT_POINT" | grep -q "nfs"; then
    log "INFO" "Cleaning NFS Directory..."
    (cd "$NFS_MOUNT_POINT" && eval "$CMD_CLEAN_DB" && eval "$CMD_CLEAN_TRAFFIC" && eval "$CMD_CLEAN_ENV")
fi

# 4. SCP (Remote) Cleanup
if [ "$ENABLE_SCP" = true ]; then
    log "INFO" "Cleaning Remote SCP Host Directory..."
    REMOTE_CMD="cd $DR_DEST_DIR && $CMD_CLEAN_DB && $CMD_CLEAN_TRAFFIC && $CMD_CLEAN_ENV"
    ssh -o ConnectTimeout=10 "$DR_USER@$DR_HOST" "$REMOTE_CMD"
fi

# Clean up old logs (Keep for 30 days)
log "INFO" "Cleaning old script logs..."
find "$LOG_DIR" -type f -name 'backup_*.log' -mtime +30 -delete

log "INFO" "Backup Process Completed Successfully."
log "INFO" "========================================="
exit 0
