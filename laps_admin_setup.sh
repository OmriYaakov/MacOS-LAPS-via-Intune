#!/bin/bash

# Log File location
LOG_FILE="$HOME/Library/Logs/hidden_admin_setup.log"
LOG_DIR="$HOME/Library/Logs/"

# Log Function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log "Starting LAPS script."

# Variables
USERNAME="LAPS_Admin"
KEYVAULT_NAME="LAPSMacOS"
AZURE_TENANT_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
AZURE_CLIENT_ID="11111111-2222-3333-4444-555555555555"
AZURE_CLIENT_SECRET="*** keep secure ***"
PASSWORD_LENGTH=20

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    log "jq not found. Installing jq..."
    curl -Lo /usr/local/bin/jq https://github.com/stedolan/jq/releases/download/jq-1.6/jq-osx-amd64
    chmod +x /usr/local/bin/jq
    log "jq installed."
else
    log "jq already installed."
fi

# Generate a compliant password: 14+ chars, upper, lower, number, special
PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()_+-=' </dev/urandom | head -c$PASSWORD_LENGTH)

# Check if user exists
if id "$USERNAME" &>/dev/null; then
    log "User '$USERNAME' exists. Rotating password."
    dscl . -passwd /Users/$USERNAME "$PASSWORD"
    log "Password rotated for '$USERNAME'."
else
    log "User '$USERNAME' does not exist. Creating..."

    # Generate unique UID
    NEW_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1 | awk '{print $1+42}')
    log "Generated UniqueID $NEW_UID."

    dscl . -create /Users/$USERNAME
    dscl . -create /Users/$USERNAME UserShell /bin/bash
    dscl . -create /Users/$USERNAME RealName "LAPS Admin"
    dscl . -create /Users/$USERNAME UniqueID "$NEW_UID"
    dscl . -create /Users/$USERNAME PrimaryGroupID 80
    dscl . -create /Users/$USERNAME NFSHomeDirectory /Users/$USERNAME
    dscl . -append /Groups/admin GroupMembership $USERNAME
    defaults write /Library/Preferences/com.apple.loginwindow HiddenUsersList -array-add $USERNAME

    # Set password
    dscl . -passwd /Users/$USERNAME "$PASSWORD"

    log "User '$USERNAME' created and hidden."
fi

# Access toke to Azure
log "Retrieving Azure access token."
ACCESS_TOKEN=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=client_credentials&client_id=$AZURE_CLIENT_ID&client_secret=$AZURE_CLIENT_SECRET&resource=https://vault.azure.net" "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/token" | jq -r '.access_token')

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
    log "Error: Token obtain error"
    exit 1
fi

log "Azure token has successfully been obtained."

# Check if password is stored in KeyVault
VAULT_URL="https://$KEYVAULT_NAME.vault.azure.net"
COMPUTER_NAME=$(scutil --get ComputerName | tr " ’'()" '-')

log "Check if password is stored in keyvault for $COMPUTER_NAME."
EXISTING_SECRET=$(curl -s -X GET -H "Authorization: Bearer $ACCESS_TOKEN" "$VAULT_URL/secrets/$COMPUTER_NAME?api-version=7.3" | jq -r '.value')

if [[ -n "$EXISTING_SECRET" && "$EXISTING_SECRET" != "null" ]]; then
    log "A password found in the keyvault $COMPUTER_NAME. This will be overwritten."
else
    log "No password found in the keyvault $COMPUTER_NAME. A new secret will be created."
fi

# Save password in keyvault
RESPONSE=$(curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" -d "{\"value\": \"$PASSWORD\", \"attributes\": {\"enabled\": true}}" "$VAULT_URL/secrets/$COMPUTER_NAME?api-version=7.3")

if echo "$RESPONSE" | jq -e '.id' &>/dev/null; then
    log "Password sucessfully saved for '$COMPUTER_NAME'."
else
    log "Error: saving password Response: $RESPONSE"
    exit 1
fi



log "Scripts succesfully ended. Hidden admin-account '$USERNAME' has been created with password stored in KeyVault."

