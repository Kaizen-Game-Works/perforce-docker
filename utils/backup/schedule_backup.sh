#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets file (assumes .env is in folders above dir holding this the script, adjust if needed)
. "$SCRIPT_DIR/../../.env"

# Path to your backup script
BACKUP_SCRIPT="$SCRIPT_DIR/p4_backup.sh"
LOGFILE="$P4_BACKUP_DIR_LOGS/cron-backup.log"

# Make sure the script is executable
chmod +x "$BACKUP_SCRIPT"

# Get current crontab
CURRENT_CRON=$(crontab -l 2>/dev/null || true)

# Check for existing jobs
EXISTING_JOBS=$(echo "$CURRENT_CRON" | grep "$BACKUP_SCRIPT" || true)

if [[ -n "$EXISTING_JOBS" ]]; then
    echo "⚠️  Found existing cron jobs for $BACKUP_SCRIPT:"
    echo "----------------------------------------"
    echo "$EXISTING_JOBS"
    echo "----------------------------------------"
    read -rp "Do you want to remove these before adding a new one? (y/n): " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
        NEW_CRON=$(echo "$CURRENT_CRON" | grep -v "$BACKUP_SCRIPT")
        echo "$NEW_CRON" | crontab -
        echo "✅ Removed existing jobs."
    else
        echo "❌ Aborting. No changes made."
        exit 0
    fi
fi

# Ask user for time input
read -rp "Enter the time to run the backup (HH:MM, 24-hour): " RUN_TIME

# Parse input
HOUR=$(echo "$RUN_TIME" | cut -d: -f1)
MINUTE=$(echo "$RUN_TIME" | cut -d: -f2)

# Verify numeric values
if ! [[ "$HOUR" =~ ^[0-9]{1,2}$ && "$MINUTE" =~ ^[0-9]{1,2}$ ]]; then
  echo "❌ Invalid time format. Use HH:MM (e.g. 02:30)."
  exit 1
fi

if (( HOUR < 0 || HOUR > 23 || MINUTE < 0 || MINUTE > 59 )); then
  echo "❌ Invalid time values. Hour must be 0–23, minute 0–59."
  exit 1
fi

# Install new cron job
CRON_JOB="$MINUTE $HOUR * * * $BACKUP_SCRIPT >> $LOGFILE 2>&1"
( crontab -l 2>/dev/null ; echo "$CRON_JOB" ) | crontab -

echo "✅ Backup scheduled: $RUN_TIME every day"
echo "Logs will be written to: $LOGFILE"

