#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets file (assumes .env is in folders above dir holding this the script, adjust if needed)
. "$SCRIPT_DIR/../../.env"

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_DIR="$P4_BACKUP_DIR_LOGS"
LOGFILE="$LOG_DIR/verify_$TIMESTAMP.log"

source $SCRIPT_DIR/../logger/logger.sh

{
    echo ""
    echo "$(date) - Starting Perforce verify..."

    log_and_alert "SUCCESS" "▶▶▶\n🕒 $(date)\n✔ Starting Perforce Verify on $(hostname)" "$LOGFILE"

    # --- Check container is running ---
    if ! docker ps --format '{{.Names}}' | grep -q "^${P4D_DOCKER_INSTANCE}$"; then
        log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Container $P4D_DOCKER_INSTANCE not running" "$LOGFILE" "CRITICAL"
        exit 1
    else
        log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Container $P4D_DOCKER_INSTANCE is running" "$LOGFILE"
    fi

     # --- Run verify inside container ---
    if docker exec "$P4D_DOCKER_INSTANCE" p4 verify -u -q //...; then
        log_and_alert "SUCCESS" "🕒 $(date)\n✔ Perforce Verification completed successfully" "$LOGFILE"
    else
        log_and_alert "FAILURE" "🕒 $(date)\n❌ Perforce Verification failed" "CRITICAL" "$LOGFILE"
        exit 1
    fi

    SUCCESS_MSG="✅✅✅\n🕒 $(date)\n Perforce verifiction SUCCESSFUL on $(hostname)\n✅✅✅"
    echo "$SUCCESS_MSG"
    post_to_slack "$SUCCESS_MSG" "$LOGFILE"
    post_to_newrelic "SUCCESS" "NORMAL"
    
} >> "$LOGFILE" 2>&1 || {
    ERROR_MSG="❌❌❌\n🕒 $(date)\n Perforce verify FAILED on $(hostname)\n❌❌❌"
    echo "$ERROR_MSG" >> "$LOGFILE"
    post_to_slack "$ERROR_MSG" "$LOGFILE"
    post_to_newrelic "FAILURE" "CRITICAL"
    exit 1
}

