#!/bin/bash
################################################################################
# advanced_scheduler.sh
#
# Description:
#   An advanced component of a time and work session manager.
#   Features include:
#     - Task scheduling with deadlines, priorities, and recurring tasks.
#     - Integration with the system’s cron daemon for recurring events.
#     - Detailed time tracking with support for pause/resume and multi-interval
#       sessions.
#     - Export functionality for logs in CSV and JSON formats.
#     - Generation of analytical reports using GNUplot.
#     - Synchronization with external calendar services using Calcurse.
#     - Enhanced real-time notifications via desktop, email, and messaging.
#
#   Enhancements:
#     - Advanced argument parsing via getopts.
#     - Modularized code with clear sections (dependency checks, configuration,
#       logging, notification system, task management, calendar integration,
#       interactive menu).
#     - Robust input validation, error handling, and caching.
#     - Dynamic task selection using fzf (if available) with a CLI fallback.
#
# Usage:
#   ./advanced_scheduler.sh [OPTIONS] {command [arguments]}
#
# Options:
#   -h, --help       Display this help message and exit.
#
# Commands:
#   add-task         Add a new task.
#   update-task      Update an existing task (select by task description).
#   delete-task      Delete a task (select by task description).
#   start-task       Start or resume a task (select by task description).
#   pause-task       Pause an active task (select by task description).
#   end-task         End a task (select by task description).
#   list-tasks       List all tasks.
#   schedule-tasks   Schedule recurring tasks with cron.
#   export-csv       Export log data in CSV format.
#   export-json      Export log data in JSON format.
#   plot-report      Generate a task duration report using GNUplot.
#   sync-calendar    Synchronize with Calcurse (list/add events).
#
# Examples:
#   ./advanced_scheduler.sh add-task "Review paper" "2025-03-15 14:00" 1 daily
#   ./advanced_scheduler.sh start-task "Review"
#   ./advanced_scheduler.sh pause-task "Review"
#   ./advanced_scheduler.sh resume-task "Review"
#   ./advanced_scheduler.sh end-task "Review"
#   ./advanced_scheduler.sh sync-calendar list
#   ./advanced_scheduler.sh sync-calendar add
#
# Note:
#   For calendar synchronization, Calcurse must be installed.
#
################################################################################

# Enable strict error handling
set -o errexit
set -o nounset
set -o pipefail
trap 'echo -e "${RED}Error occurred at line $LINENO. Exiting.${NC}"' ERR

###############################################
# ANSI Color Codes for Messages
###############################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

#############################################################
# Global Cache for Task Duration (simple caching mechanism)
#############################################################
CACHE_FILE="/tmp/advanced_scheduler_duration.cache"
CACHE_TIMESTAMP=""

#############################################################
# Notification Configuration Defaults
# These can be overridden via the external configuration file.
#############################################################
: ${NOTIFY_DESKTOP:=1}      # Enable desktop notifications via notify-send
: ${NOTIFY_EMAIL:=0}        # Enable email notifications (requires mail command)
: ${EMAIL_RECIPIENT:=""}     # Recipient email address for notifications
: ${NOTIFY_MESSAGING:=0}    # Enable messaging notifications (e.g., Slack)
: ${MESSAGING_API_URL:=""}   # API endpoint for messaging notifications
: ${ALERT_THRESHOLD:=30}     # Minimum seconds between notifications of same event
: ${QUIET_HOURS_START:="22:00"}  # Start time for quiet hours (HH:MM)
: ${QUIET_HOURS_END:="06:00"}    # End time for quiet hours (HH:MM)

# Global associative array to track last notification times
declare -A LAST_NOTIFICATION

###############################################
# Dependency Checks & Configuration Setup
###############################################
check_dependencies() {
    local deps=(date crontab sed awk mktemp)
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${RED}Error: Required command '$dep' is not installed.${NC}"
            exit 1
        fi
    done

    if ! command -v gnuplot >/dev/null 2>&1; then
        echo -e "${YELLOW}Warning: GNUplot is not installed. 'plot-report' will not work.${NC}"
    fi

    if command -v whiptail >/dev/null 2>&1; then
        MENU_TOOL="whiptail"
    elif command -v dialog >/dev/null 2>&1; then
        MENU_TOOL="dialog"
    else
        MENU_TOOL=""
    fi

    if command -v fzf >/dev/null 2>&1; then
        FZF_AVAILABLE=1
    else
        FZF_AVAILABLE=0
    fi

    if command -v calcurse >/dev/null 2>&1; then
        CALCURSE_AVAILABLE=1
    else
        CALCURSE_AVAILABLE=0
    fi
}
check_dependencies

###############################################
# Configuration Management
# shellcheck source=/dev/null
###############################################
CONFIG_FILE="./advanced_scheduler.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    TASK_DB="tasks.db"
    LOG_FILE="tasks.log"
    CRON_TEMP="cron_temp.txt"
    DEBUG_LOG="debug.log"
    DEBUG_MODE=0
fi
touch "$TASK_DB" "$LOG_FILE" "$DEBUG_LOG"
first_line=$(head -n 1 "$TASK_DB")
column_count=$(echo "$first_line" | awk -F, '{print NF}')

if [ "$column_count" -lt 7 ]; then
    echo "Updating TASK_DB format..."
    awk -F, '{print $0",0"}' "$TASK_DB" > "${TASK_DB}.tmp"
    mv "${TASK_DB}.tmp" "$TASK_DB"
    echo "TASK_DB updated successfully!"
fi


#######################################
# Logging Functions with Levels
#######################################
log_debug() {
    if [[ "${DEBUG_MODE:-0}" -eq 1 ]]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") [DEBUG] - $*" >> "$DEBUG_LOG"
    fi
}
log_info() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") [INFO] - $*" >> "$DEBUG_LOG"
}
log_warn() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") [WARN] - $*" >> "$DEBUG_LOG"
}
log_error() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") [ERROR] - $*" >> "$DEBUG_LOG"
}

############################################################
# Notification Functions
############################################################

# Check if current time is within user-defined quiet hours.
is_within_quiet_hours() {
    local current_minutes quiet_start_minutes quiet_end_minutes
    current_minutes=$((10#$(date +"%H") * 60 + 10#$(date +"%M")))
    IFS=: read start_hour start_min <<< "$QUIET_HOURS_START"
    IFS=: read end_hour end_min <<< "$QUIET_HOURS_END"
    quiet_start_minutes=$((10#$start_hour * 60 + 10#$start_min))
    quiet_end_minutes=$((10#$end_hour * 60 + 10#$end_min))
    if (( quiet_start_minutes < quiet_end_minutes )); then
        if (( current_minutes >= quiet_start_minutes && current_minutes < quiet_end_minutes )); then
            return 0
        fi
    else
        if (( current_minutes >= quiet_start_minutes || current_minutes < quiet_end_minutes )); then
            return 0
        fi
    fi
    return 1
}

# Send a desktop notification using notify-send.
send_desktop_notification() {
    local title="$1"
    local message="$2"
    if [[ "$NOTIFY_DESKTOP" -eq 1 ]]; then
        if command -v notify-send >/dev/null 2>&1; then
            notify-send "$title" "$message"
        else
            log_warn "notify-send not found; desktop notification not sent."
        fi
    fi
}

# Send an email notification (requires a configured mail command).
send_email_notification() {
    local title="$1"
    local message="$2"
    if [[ "$NOTIFY_EMAIL" -eq 1 && -n "$EMAIL_RECIPIENT" ]]; then
        if command -v mail >/dev/null 2>&1; then
            echo "$message" | mail -s "$title" "$EMAIL_RECIPIENT"
        else
            log_warn "mail command not found; email notification not sent."
        fi
    fi
}

block_websites() {
    local sites_file="blocked_sites.txt"

    # Ensure blocked_sites.txt exists
    echo -e "${RED}Blocking distracting websites"
    if [[ ! -f "$sites_file" ]]; then
        echo -e "${YELLOW}Warning: $sites_file not found. Creating default list...${NC}"
        cat <<EOF > "$sites_file"
facebook.com
www.facebook.com
instagram.com
www.instagram.com
cdn.instagram.com
twitter.com
www.twitter.com
tiktok.com
www.tiktok.com
reddit.com
www.reddit.com
discord.com
www.discord.com
netflix.com
www.netflix.com
twitch.tv
www.twitch.tv
open.spotify.com

EOF
    fi

    
    while IFS= read -r site || [[ -n "$site" ]]; do
        site=$(echo "$site" | tr -d ' ')  # Remove spaces
        [[ -z "$site" || "$site" == \#* ]] && continue  # Skip empty or commented lines

        # Block via /etc/hosts
        if ! grep -q "$site" /etc/hosts; then
            echo "127.0.0.1 $site" | sudo tee -a /etc/hosts > /dev/null
            echo "::1 $site" | sudo tee -a /etc/hosts > /dev/null
        fi

        # Resolve IPv4
        ipv4=$(dig +short A "$site" | head -n1)
        if [[ -z "$ipv4" ]]; then
            ipv4=$(nslookup "$site" | awk '/^Address: / { print $2 }' | grep -v ':' | head -n1)
        fi

        # Resolve IPv6
        ipv6=$(dig +short AAAA "$site" | head -n1)
        if [[ -z "$ipv6" ]]; then
            ipv6=$(nslookup -type=AAAA "$site" | awk '/^Address: / { print $2 }' | grep ':' | head -n1)
        fi

        # Block IPv4
        if [[ -n "$ipv4" && "$ipv4" != "127.0.0.1" ]]; then
            sudo iptables -A OUTPUT -d "$ipv4" -j DROP
        fi

        # Block IPv6
        if [[ -n "$ipv6" && "$ipv6" != "::1" ]]; then
            sudo ip6tables -A OUTPUT -d "$ipv6" -j DROP
        fi
    done < "$sites_file"

    # Flush DNS Cache (ensure changes take effect)
    sudo systemctl restart NetworkManager 2>/dev/null || sudo systemctl restart nscd 2>/dev/null
}

unblock_websites() {
    local sites_file="blocked_sites.txt"
    echo -e "${GREEN}Unblocking websites"
    if [[ ! -f "$sites_file" ]]; then
        echo -e "${YELLOW}Warning: $sites_file not found. Nothing to unblock.${NC}"
        return
    fi


    while IFS= read -r site || [[ -n "$site" ]]; do
        site=$(echo "$site" | tr -d ' ')  # Remove spaces
        [[ -z "$site" || "$site" == \#* ]] && continue  # Skip empty or commented lines

        # Unblock from /etc/hosts
        sudo sed -i "/$site/d" /etc/hosts

        # Resolve IPv4
        ipv4=$(dig +short A "$site" | head -n1)
        if [[ -z "$ipv4" ]]; then
            ipv4=$(nslookup "$site" | awk '/^Address: / { print $2 }' | grep -v ':' | head -n1)
        fi

        # Resolve IPv6
        ipv6=$(dig +short AAAA "$site" | head -n1)
        if [[ -z "$ipv6" ]]; then
            ipv6=$(nslookup -type=AAAA "$site" | awk '/^Address: / { print $2 }' | grep ':' | head -n1)
        fi

        # Unblock IPv4
        if [[ -n "$ipv4" && "$ipv4" != "127.0.0.1" ]]; then
            sudo iptables -D OUTPUT -d "$ipv4" -j DROP 2>/dev/null
        fi

        # Unblock IPv6
        if [[ -n "$ipv6" && "$ipv6" != "::1" ]]; then
            sudo ip6tables -D OUTPUT -d "$ipv6" -j DROP 2>/dev/null
        fi
    done < "$sites_file"

    # Flush DNS Cache (ensure changes take effect)
    sudo systemctl restart NetworkManager 2>/dev/null || sudo systemctl restart nscd 2>/dev/null
}

# Send a messaging notification using a specified API.
send_messaging_notification() {
    local title="$1"
    local message="$2"
    if [[ "$NOTIFY_MESSAGING" -eq 1 && -n "$MESSAGING_API_URL" ]]; then
        curl -s -X POST -H "Content-Type: application/json" \
            -d "{\"title\": \"$title\", \"message\": \"$message\"}" \
            "$MESSAGING_API_URL" >/dev/null
    fi
}

# Generic notification function that checks alert thresholds and quiet hours.
send_notification() {
    local event_type="$1"
    local title="$2"
    local message="$3"
    local now
    now=$(date +%s)
    if [[ -n "${LAST_NOTIFICATION[$event_type]:-}" ]]; then
        local diff=$(( now - LAST_NOTIFICATION[$event_type] ))
        if (( diff < ALERT_THRESHOLD )); then
            log_info "Notification for event '$event_type' suppressed (only $diff seconds since last alert)."
            return
        fi
    fi
    LAST_NOTIFICATION[$event_type]=$now
    if is_within_quiet_hours; then
        log_info "Notification for event '$event_type' suppressed due to quiet hours."
        return
    fi
    send_desktop_notification "$title" "$message"
    send_email_notification "$title" "$message"
    send_messaging_notification "$title" "$message"
}

############################################################
# Caching Function for Task Duration
############################################################
get_cached_duration() {
    local task_id="$1"
    local log_mtime
    log_mtime=$(stat -c %Y "$LOG_FILE")
    if [[ -f "$CACHE_FILE" && "$log_mtime" -eq "$CACHE_TIMESTAMP" ]]; then
        local cached
        cached=$(grep "^${task_id}," "$CACHE_FILE" | cut -d',' -f2)
        if [[ -n "$cached" ]]; then
            echo "$cached"
            return
        fi
    fi
    CACHE_TIMESTAMP="$log_mtime"
    > "$CACHE_FILE"
    while IFS=',' read -r tid _; do
        local dur
        dur=$(calculate_task_duration "$tid")
        echo "${tid},${dur}" >> "$CACHE_FILE"
    done < <(awk -F, 'NF{print $1}' "$LOG_FILE" | sort | uniq)
    grep "^${task_id}," "$CACHE_FILE" | cut -d',' -f2
}

############################################################
# Task Selection Functions
############################################################
select_task() {
    local query="$1"
    local tasks
    tasks=$(awk -F, '{gsub(/"/, "", $2); print $1": "$2}' "$TASK_DB")
    if [[ -n "$query" ]]; then
        tasks=$(echo "$tasks" | grep -i "$query")
    fi
    if [[ -z "$tasks" ]]; then
        echo -e "${RED}No tasks found matching query: $query${NC}" >&2
        return 1
    fi
    local selected
    if [[ "$FZF_AVAILABLE" -eq 1 ]]; then
        selected=$(echo "$tasks" | fzf --prompt="Select task: ")
    else
        echo -e "${YELLOW}Multiple tasks found. Please choose one by entering the task ID:${NC}"
        echo "$tasks"
        read -rp "Task ID: " selected
    fi
    local id
    id=$(echo "$selected" | cut -d: -f1)
    echo "$id"
}

get_task_id() {
    local input="$1"
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        local id
        id=$(awk -F, -v query="$input" '$2 ~ query {print $1}' "$TASK_DB" | head -n 1)
        if [[ -z "$id" ]]; then
            echo -e "${RED}Task selection failed. Exiting.${NC}" >&2
            exit 1
        fi
        echo "$id"
    fi
}


############################################################
# Calendar Integration Functions using Calcurse
############################################################
sync_calendar() {
    if [[ "$CALCURSE_AVAILABLE" -ne 1 ]]; then
        echo -e "${RED}Calcurse is not installed. Please install calcurse to use calendar synchronization.${NC}"
        exit 1
    fi
    local action="$1"
    shift
    #code edited
        case "$action" in
        interactive)
            echo -e "${GREEN}Launching Calcurse interactive mode...${NC}"
            calcurse
            ;;
        list)
            echo -e "${GREEN}Fetching upcoming events from calcurse...${NC}"
            calcurse -Q --from today --days 7
            ;;
        add)
            read -e -rp "Enter event title: " title
            read -e -rp "Enter start time (YYYY-MM-DD HH:MM): " start_time
            read -e -rp "Enter duration in minutes: " duration
            read -e -rp "Enter event description (optional): " description
            local end_time
            end_time=$(date -d "$start_time $duration minutes" +"%H:%M")
            local event_date
            event_date=$(date -d "$start_time" +"%Y-%m-%d")
            local temp_file
            temp_file=$(mktemp)
            echo "%% appointments %%" > "$temp_file"
            echo "${event_date} ${start_time##* }-${end_time} ${title}: ${description}" >> "$temp_file"
            echo -e "${GREEN}Adding event to calcurse...${NC}"
            calcurse -i "$temp_file"
            rm -f "$temp_file"
            ;;
        *)
            echo -e "${RED}Unsupported calendar action. Supported actions: list, add.${NC}"
            ;;
    esac
}

