#!/bin/bash

# Log file (use system-wide log path)
LOG_FILE="$HOME/Library/Logs/remove_gui_user_admin.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting script to remove GUI user from admin group..."

# Get the GUI user via /dev/console
GUI_USER=$(stat -f%Su /dev/console)
log "Detected GUI user: $GUI_USER"

# List of admin users to keep
KEEP_ADMINS=("root" "LAPS_Admin" "_mbsetupuser" "_xcsbuildagent" "_installer" "_spotlight" "_sandbox" "_locationd" "_softwareupdate")

# Check if GUI user is in the keep list
if [[ " ${KEEP_ADMINS[*]} " =~ " ${GUI_USER} " ]]; then
    log "User '$GUI_USER' is in the protected keep list. Skipping removal."
    exit 0
fi

# Check if GUI user is in admin group
if dseditgroup -o checkmember -m "$GUI_USER" admin | grep -q "yes"; then
    log "User '$GUI_USER' is an admin. Proceeding to remove admin rights..."
    dseditgroup -o edit -d "$GUI_USER" -t user admin
    log "Admin rights removed from user '$GUI_USER'."
else
    log "User '$GUI_USER' is not an admin. No action needed."
fi

log "Script completed."
