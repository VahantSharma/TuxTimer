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
#
#   Enhancements:
#     - Advanced argument parsing via getopts.
#     - Modularized code with clear sections (dependency checks, configuration,
#       logging, task management, calendar integration, interactive menu).
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

#############################################
# Dependency Checks & Configuration Setup
#############################################
check_dependencies() {
    local deps=(date crontab)
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

#############################################
# Configuration Management
# shellcheck source=/dev/null
#############################################
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

#######################################
# Logging Functions with Levels
#######################################
log_debug() {
    if [[ "$DEBUG_MODE" -eq 1 ]]; then
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

#######################################
