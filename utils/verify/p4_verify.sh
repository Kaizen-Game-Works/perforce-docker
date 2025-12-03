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

    # --- Check container is running ---
    if ! docker ps --format '{{.Names}}' | grep -q "^${P4D_DOCKER_INSTANCE}$"; then
        log_and_alert "FAILURE" "❌ Perforce Container $P4D_DOCKER_INSTANCE not running on $(hostname) at $(date)" "$LOGFILE" "CRITICAL"
        exit 1
    fi

     # --- Run verify inside container ---
    if docker exec "$P4D_DOCKER_INSTANCE" p4 verify -u -q //...; then
        log_and_alert "SUCCESS" "✅ Perforce Verification completed successfully on $(hostname) at $(date)" "$LOGFILE"
    else
        log_and_alert "FAILURE" "❌ Perforce Verification failed on $(hostname) at $(date)" "CRITICAL" "$LOGFILE"
        exit 1
    fi
} >> "$LOGFILE" 2>&1 || {
    ERROR_MSG="❌ Perforce verify FAILED on $(hostname) at $(date)"
    echo "$ERROR_MSG" >> "$LOGFILE"
    post_to_slack "$ERROR_MSG"
    post_to_newrelic "FAILURE" "CRITICAL"
    exit 1
}

