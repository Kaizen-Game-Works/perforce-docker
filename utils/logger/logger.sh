#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load secrets file (assumes .env is in folders above dir holding this the script, adjust if needed)
. "$SCRIPT_DIR/../../.env"


# --- Logging helpers ---
post_to_slack() {
    local msg="$1"
    local log_file="$2"  # not used inside Slack but kept for uniformity
    if [[ "${SLACK_ENABLED:-false}" == "true" && -n "${SLACK_BOT_TOKEN:-}" ]]; then
        curl -s -X POST "https://slack.com/api/chat.postMessage" \
            -H "Authorization: Bearer $SLACK_BOT_TOKEN" \
            -H 'Content-type: application/json; charset=utf-8' \
            --data "{
                \"channel\": \"$SLACK_CHANNEL_ID\",
                \"text\": \"$msg\"
            }"
    fi
}

post_to_newrelic() {
    local status="$1"
    local priority="$2"
    local log_file="$3"  # again, not used but kept consistent
    if [[ "${NEWRELIC_ENABLED:-false}" == "true" && -n "${NEWRELIC_API_KEY:-}" && -n "${NEWRELIC_ACCOUNT_ID:-}" ]]; then
        payload=$(mktemp)
        cat > "$payload" <<EOF
[
  {
    "eventType": "PerforceBackup",
    "status": "$status",
    "host": "$(hostname)",
    "priority": "$priority"
  }
]
EOF
        gzip -c "$payload" | \
        curl -s -X POST \
             -H "Content-Type: application/json" \
             -H "Api-Key: $NEWRELIC_API_KEY" \
             -H "Content-Encoding: gzip" \
             $NEWRELIC_REGION_SERVER/v1/accounts/$NEWRELIC_ACCOUNT_ID/events \
             --data-binary @-
        rm -f "$payload"
    fi
}

log_and_alert() {
    local status="$1"
    local msg="$2"
    local log_file="$3"
    local priority="${4:-NORMAL}"
    
    # ensure new log starts on a new line
    echo "" >> "$log_file"
    echo "$(date) - $msg" >> "$log_file"

    post_to_slack "$msg" "$log_file"
    post_to_newrelic "$status" "$priority" "$log_file"
}
