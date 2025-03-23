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
        id=$(select_task "$input")
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
    case "$action" in
        list)
            echo -e "${GREEN}Fetching upcoming events from calcurse...${NC}"
            calcurse -l
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

############################################################
# Usage Function
############################################################
usage() {
    cat <<EOF
Usage: $0 [OPTIONS] {command [arguments]}

Options:
  -h, --help           Display this help message and exit.

Commands:
  add-task             Add a new task.
                       Usage: $0 add-task "Task Description" "YYYY-MM-DD HH:MM" Priority Recurrence
  update-task          Update an existing task.
                       Usage: $0 update-task <task_id_or_query> Field NewValue
                       (Field: description, deadline, priority, recurrence, status)
  delete-task          Delete a task.
                       Usage: $0 delete-task <task_id_or_query>
  start-task           Start or resume a task.
                       Usage: $0 start-task <task_id_or_query>
  pause-task           Pause an active task.
                       Usage: $0 pause-task <task_id_or_query>
  end-task             End a task.
                       Usage: $0 end-task <task_id_or_query>
  list-tasks           List all tasks.
                       Usage: $0 list-tasks
  schedule-tasks       Schedule recurring tasks with cron.
                       Usage: $0 schedule-tasks
  export-csv           Export log data in CSV format.
                       Usage: $0 export-csv output_file.csv
  export-json          Export log data in JSON format.
                       Usage: $0 export-json output_file.json
  plot-report          Generate a task duration report using GNUplot.
                       Usage: $0 plot-report
  sync-calendar        Synchronize with calcurse.
                       Usage: $0 sync-calendar <action>
                       Supported actions: list, add

Examples:
  $0 add-task "Review paper" "2025-03-15 14:00" 1 daily
  $0 start-task "Review"
  $0 pause-task "Review"
  $0 resume-task "Review"
  $0 end-task "Review"
  $0 sync-calendar list
  $0 sync-calendar add

EOF
}

############################################################
# Advanced Argument Parsing with getopts
############################################################
while getopts ":h" opt; do
    case $opt in
        h)
            usage
            exit 0
            ;;
        \?)
            echo -e "${RED}Invalid option: -$OPTARG${NC}" >&2
            usage
            exit 1
            ;;
    esac
done
shift $((OPTIND - 1))

############################################################
# Interactive Menu
############################################################
interactive_menu() {
    local choice
    if [[ -n "$MENU_TOOL" ]]; then
        choice=$(whiptail --title "Advanced Scheduler Menu" \
            --menu "Choose an option:" 22 78 14 \
            "1" "Add Task" \
            "2" "Update Task" \
            "3" "Delete Task" \
            "4" "Start/Resume Task" \
            "5" "Pause Task" \
            "6" "End Task" \
            "7" "List Tasks" \
            "8" "Schedule Tasks" \
            "9" "Export Log to CSV" \
            "10" "Export Log to JSON" \
            "11" "Plot Report" \
            "12" "Sync Calendar" \
            "13" "Help" \
            "14" "Exit" 3>&1 1>&2 2>&3)
    else
        echo -e "${YELLOW}Please choose an option:${NC}"
        echo "1) Add Task"
        echo "2) Update Task"
        echo "3) Delete Task"
        echo "4) Start/Resume Task"
        echo "5) Pause Task"
        echo "6) End Task"
        echo "7) List Tasks"
        echo "8) Schedule Tasks"
        echo "9) Export Log to CSV"
        echo "10) Export Log to JSON"
        echo "11) Plot Report"
        echo "12) Sync Calendar"
        echo "13) Help"
        echo "14) Exit"
        read -e -rp "Enter your choice [1-14]: " choice
    fi

    case "$choice" in
        1)
            read -e -rp "Enter task description: " desc
            read -e -rp "Enter deadline (YYYY-MM-DD HH:MM): " deadline
            read -e -rp "Enter priority (numeric): " priority
            if ! [[ "$priority" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}Priority must be a number.${NC}"
                return
            fi
            read -e -rp "Enter recurrence (none, daily, weekly, monthly): " rec
            add_task "$desc" "$deadline" "$priority" "$rec"
            ;;
        2)
            read -e -rp "Enter task name (or part of it) to update: " query
            task_id=$(get_task_id "$query")
            read -e -rp "Enter field (description/deadline/priority/recurrence/status): " field
            read -e -rp "Enter new value: " value
            update_task "$task_id" "$field" "$value"
            ;;
        3)
            read -e -rp "Enter task name (or part of it) to delete: " query
            task_id=$(get_task_id "$query")
            delete_task "$task_id"
            ;;
        4)
            read -e -rp "Enter task name (or part of it) to start/resume: " query
            task_id=$(get_task_id "$query")
            start_task "$task_id"
            ;;
        5)
            read -e -rp "Enter task name (or part of it) to pause: " query
            task_id=$(get_task_id "$query")
            pause_task "$task_id"
            ;;
        6)
            read -e -rp "Enter task name (or part of it) to end: " query
            task_id=$(get_task_id "$query")
            end_task "$task_id"
            ;;
        7)
            list_tasks
            ;;
        8)
            schedule_tasks
            ;;
        9)
            read -e -rp "Enter output CSV file name: " csvfile
            export_csv "$csvfile"
            ;;
        10)
            read -e -rp "Enter output JSON file name: " jsonfile
            export_json "$jsonfile"
            ;;
        11)
            plot_report
            ;;
        12)
            echo -e "${GREEN}Calendar Synchronization Options:${NC}"
            echo "1) List upcoming events"
            echo "2) Add a new event"
            read -e -rp "Choose an action [1-2]: " cal_choice
            case "$cal_choice" in
                1) sync_calendar list ;;
                2) sync_calendar add ;;
                *) echo -e "${RED}Invalid calendar option.${NC}" ;;
            esac
            ;;
        13)
            usage
            ;;
        14)
            echo -e "${GREEN}Exiting...${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            ;;
    esac
    echo -e "${GREEN}Operation completed. Press Enter to continue...${NC}"
    read -r
    interactive_menu
}

################################################################################
# Core Task Management Functions
################################################################################

# validate_date: Verifies the provided date string.
validate_date() {
    if ! date -d "$1" >/dev/null 2>&1; then
        echo -e "${RED}Invalid date format: $1${NC}" >&2
        return 1
    fi
    return 0
}

# add_task: Adds a new task.
add_task() {
    local description="$1"
    local deadline="$2"
    local priority="$3"
    local recurrence="$4"

    validate_date "$deadline" || return 1

    local id
    id=$(date +%s)  # Use epoch time as unique ID

    echo "${id},\"${description}\",\"${deadline}\",${priority},${recurrence},pending" >> "$TASK_DB"
    echo -e "${GREEN}Task added with ID: ${id}${NC}"
    log_debug "Added task ${id}: ${description}, Deadline: ${deadline}, Priority: ${priority}, Recurrence: ${recurrence}"
}


# list_tasks: Displays all tasks.
list_tasks() {
    if [[ ! -s "$TASK_DB" ]]; then
        echo -e "${YELLOW}No tasks found.${NC}"
        return
    fi
    echo -e "${GREEN}ID, Description, Deadline, Priority, Recurrence, Status${NC}"
    cat "$TASK_DB"
}


# update_task: Updates a task field.
update_task() {
    local task_id="$1"
    local field="$2"
    local new_value="$3"
    local field_index

    case "$field" in
        description) field_index=2 ;;
        deadline)
            validate_date "$new_value" || return 1
            field_index=3 ;;
        priority) field_index=4 ;;
        recurrence) field_index=5 ;;
        status) field_index=6 ;;
        *)
            echo -e "${RED}Unknown field: $field${NC}"
            return 1
            ;;
    esac

    awk -F, -v id="$task_id" -v idx="$field_index" -v new="$new_value" 'BEGIN {OFS=","} {
        if ($1 == id) { $idx = new }
        print
    }' "$TASK_DB" > "${TASK_DB}.tmp" && mv "${TASK_DB}.tmp" "$TASK_DB"

    echo -e "${GREEN}Task ${task_id} updated: set $field to ${new_value}.${NC}"
    log_debug "Updated task ${task_id}: set $field to ${new_value}"
}


# delete_task: Deletes a task.
delete_task() {
    local task_id="$1"
    sed -i "/^${task_id},/d" "$TASK_DB"
    echo -e "${GREEN}Task ${task_id} deleted.${NC}"
    log_debug "Deleted task ${task_id}"
}

# start_task: Logs a start/resume event and sends a notification.
start_task() {
    local task_id="$1"
    local start_time
    start_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "${task_id},start,${start_time}" >> "$LOG_FILE"
    echo -e "${GREEN}Task ${task_id} started/resumed at ${start_time}.${NC}"
    log_debug "Started/resumed task ${task_id} at ${start_time}"
    send_notification "task_start" "Task Started" "Task ${task_id} started/resumed at ${start_time}."
}


# pause_task: Logs a pause event and sends a notification.
pause_task() {
    local task_id="$1"
    local pause_time
    pause_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "${task_id},pause,${pause_time}" >> "$LOG_FILE"
    echo -e "${GREEN}Task ${task_id} paused at ${pause_time}.${NC}"
    log_debug "Paused task ${task_id} at ${pause_time}"
    send_notification "task_pause" "Task Paused" "Task ${task_id} paused at ${pause_time}."
}


# resume_task: Alias for start_task.
resume_task() {
    start_task "$1"
    echo -e "${GREEN}Task ${1} resumed.${NC}"
    log_debug "Resumed task ${1}"
}

# end_task: Logs an end event, updates task status, and sends a notification.
end_task() {
    local task_id="$1"
    local end_time
    end_time=$(date +"%Y-%m-%d %H:%M:%S")
    echo "${task_id},end,${end_time}" >> "$LOG_FILE"
    sed -i "s/^\(${task_id},.*,\)pending[[:space:]]*\$/\1completed/" "$TASK_DB"
    echo -e "${GREEN}Task ${task_id} ended at ${end_time}.${NC}"
    log_debug "Ended task ${task_id} at ${end_time}"
    send_notification "task_end" "Task Ended" "Task ${task_id} ended at ${end_time}."
}

# calculate_task_duration: Computes total active time for a task.
calculate_task_duration() {
    local task_id="$1"
    local total_duration=0
    local last_start=""
    while IFS=',' read -r tid action timestamp; do
        if [ "$tid" == "$task_id" ]; then
            local epoch
            epoch=$(date -d "$timestamp" +%s 2>/dev/null)
            if [ "$action" == "start" ]; then
                last_start=$epoch
            elif [[ "$action" == "pause" || "$action" == "end" ]]; then
                if [ -n "$last_start" ]; then
                    local diff=$(( epoch - last_start ))
                    total_duration=$(( total_duration + diff ))
                    last_start=""
                fi
            fi
        fi
    done < "$LOG_FILE"
    if [ -n "$last_start" ]; then
        local now
        now=$(date +%s)
        total_duration=$(( total_duration + now - last_start ))
    fi
    echo "$total_duration"
}

# schedule_tasks: Generates cron entries for recurring tasks.
schedule_tasks() {
    crontab -l > "$CRON_TEMP" 2>/dev/null
    sed -i '/# advanced_scheduler/d' "$CRON_TEMP"
    declare -A scheduled_slots
    while IFS=',' read -r id description deadline priority recurrence _; do
        recurrence=$(echo "$recurrence" | tr -d ' ')
        if [[ "$recurrence" != "none" && "$recurrence" != "" ]]; then
            if ! cron_minute=$(date -d "$deadline" +"%M" 2>/dev/null) || \
               ! cron_hour=$(date -d "$deadline" +"%H" 2>/dev/null); then
                log_debug "Skipping task ${id}: invalid deadline format ($deadline)"
                continue
            fi
            local cron_day="*"
            local cron_month="*"
            local cron_weekday="*"
            case "$recurrence" in
                daily) ;;  
                weekly) cron_weekday=$(date -d "$deadline" +"%u") ;;
                monthly) cron_day=$(date -d "$deadline" +"%d") ;;
            esac
            local key="${cron_minute} ${cron_hour} ${cron_day} ${cron_month} ${cron_weekday}"
            local orig_key="$key"
            while [[ -n "${scheduled_slots[$key]}" && ${priority} -gt ${scheduled_slots[$key]} ]]; do
                cron_minute=$(( (10#$cron_minute + 1) % 60 ))
                key="${cron_minute} ${cron_hour} ${cron_day} ${cron_month} ${cron_weekday}"
            done
            scheduled_slots["$key"]=$priority
            local cmd
            cmd="$(pwd)/advanced_scheduler.sh start-task ${id}"
            local command="${cmd} # advanced_scheduler"
            echo "${cron_minute} ${cron_hour} ${cron_day} ${cron_month} ${cron_weekday} ${command}" >> "$CRON_TEMP"
            log_debug "Scheduled task ${id} (orig key: '${orig_key}', adjusted key: '${key}') with priority ${priority}"
        fi
    done < <(sort -t',' -k3 "$TASK_DB")
    if crontab "$CRON_TEMP"; then
        echo -e "${GREEN}Recurring tasks scheduled with cron.${NC}"
    else
        echo -e "${RED}Error installing cron jobs. Please check your cron configuration.${NC}"
    fi
}

# export_csv: Exports log data in CSV format.
export_csv() {
    local output_file="$1"
    if cp "$LOG_FILE" "$output_file"; then
        echo -e "${GREEN}Log data exported to ${output_file} in CSV format.${NC}"
        log_debug "Exported log data to CSV: ${output_file}"
    else
        echo -e "${RED}Error exporting CSV.${NC}"
    fi
}

# export_json: Exports log data in JSON format.
export_json() {
    local output_file="$1"
    {
        echo "["
        local first=1
        while IFS=',' read -r task_id action timestamp; do
            if [ $first -eq 0 ]; then
                echo ","
            fi
            first=0
            printf "  {\"task_id\": \"%s\", \"action\": \"%s\", \"timestamp\": \"%s\"}" "$task_id" "$action" "$timestamp"
        done < "$LOG_FILE"
        echo ""
        echo "]"
    } > "$output_file"
    echo -e "${GREEN}Log data exported to ${output_file} in JSON format.${NC}"
    log_debug "Exported log data to JSON: ${output_file}"
}