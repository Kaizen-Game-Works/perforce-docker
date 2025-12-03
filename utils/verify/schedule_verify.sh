#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets file (assumes .env is in folders above dir holding this the script, adjust if needed)
. "$SCRIPT_DIR/../../.env"

# Path to your Perforce verify script
VERIFY_SCRIPT="$SCRIPT_DIR/p4_verify.sh"
LOGFILE="$P4_BACKUP_DIR_LOGS/cron-verify.log"

# Make sure the script is executable
chmod +x "$VERIFY_SCRIPT"

# Get current crontab
CURRENT_CRON=$(crontab -l 2>/dev/null || true)

# Check for existing jobs
EXISTING_JOBS=$(echo "$CURRENT_CRON" | grep "$VERIFY_SCRIPT" || true)

if [[ -n "$EXISTING_JOBS" ]]; then
    echo "⚠️  Found existing cron jobs for $VERIFY_SCRIPT:"
    echo "----------------------------------------"
    echo "$EXISTING_JOBS"
    echo "----------------------------------------"
    read -rp "Do you want to remove these before adding a new one? (y/n): " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
        NEW_CRON=$(echo "$CURRENT_CRON" | grep -v "$VERIFY_SCRIPT")
        echo "$NEW_CRON" | crontab -
        echo "✅ Removed existing jobs."
    else
        echo "❌ Aborting. No changes made."
        exit 0
    fi
fi

# Ask user for time input
read -rp "Enter the time to run the verify (HH:MM, 24-hour): " RUN_TIME

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

# Ask user for day of the week
echo "Enter the day of the week as an integer (0=Sunday, 1=Monday, ..., 6=Saturday):"
read -rp "> " DAY_NUM

# Validate day number
if ! [[ "$DAY_NUM" =~ ^[0-6]$ ]]; then
    echo "❌ Invalid day. Must be an integer between 0 and 6."
    exit 1
fi

# Install new cron job
CRON_JOB="$MINUTE $HOUR * * $DAY_NUM $VERIFY_SCRIPT >> $LOGFILE 2>&1"
( crontab -l 2>/dev/null ; echo "$CRON_JOB" ) | crontab -

echo "✅ Verify scheduled: $RUN_TIME on day number $DAY_NUM"
echo "Logs will be written to: $LOGFILE"
