#!/bin/bash
#
# Proxmox VM Deployment Script with Cloud-Init & TUI
#
# This script provides a 'dialog' based TUI for creating a new VM
# from a Cloud-Init template.
#
# Usage: ./pmx_deploy.sh
#
# Requires 'dialog' and 'jq' to be installed:
#   apt update && apt install dialog jq
#
# IMPORTANT:
# 1. Run this script ON YOUR PROXMOX PVE NODE.
# 2. You MUST have a prepared Cloud-Init VM template.
#    (e.g., Ubuntu 22.04 Cloud, Debian 12 Cloud, etc.)
# 3. This script assumes the template's disk is 'scsi0'.
#    If it's 'virtio0', change the 'qm resize' line below.
#

# --- Configuration ---
DEFAULT_STORAGE="PMX-SSD" # Default datastore as requested
DEFAULT_DOMAIN="local"    # Default search domain for DNS

# --- Dependency Checks ---
command -v dialog >/dev/null 2>'&'1 || {
  echo "Error: 'dialog' is not installed." >&'2'
  echo "Please install it first: apt update && apt install dialog" >&'2'
  exit 1
}

command -v qm >/dev/null 2>'&'1 || {
  echo "Error: 'qm' command not found." >&'2'
  echo "This script must be run on a Proxmox PVE node." >&'2'
  exit 1
}

# Check for pvesh (Proxmox Virtual Environment Shell)
command -v pvesh >/dev/null 2>'&'1 || {
  echo "Error: 'pvesh' command not found." >&'2'
  echo "This script must be run on a Proxmox PVE node." >&'2'
  exit 1
}

# Check for jq (JSON processor)
command -v jq >/dev/null 2>'&'1 || {
  echo "Error: 'jq' command not found." >&'2'
  echo "Please install it first: apt update && apt install jq" >&'2'
  exit 1
}

# --- Select Template ---
# Get list of templates and format for dialog (tag item)
# Uses pvesh with json output and jq for reliable parsing
TEMPLATE_LIST=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | jq -r '.[] | select(.template == 1) | "\(.vmid) \(.name)"')

if [ -z "$TEMPLATE_LIST" ]; then
    dialog --title "Error" --msgbox "No VM templates found in the cluster." 8 50
    clear
    exit 1
fi

MENU_OUTPUT_TEMPLATE=$(mktemp)
dialog --backtitle "Proxmox VM Deployer" \
       --title "Select Template" \
       --menu "\nChoose the Template VM to clone from:" \
20 60 15 \
$TEMPLATE_LIST \
2> "$MENU_OUTPUT_TEMPLATE"

exit_status=$?
SELECTED_TEMPLATE_ID=$(cat "$MENU_OUTPUT_TEMPLATE")
rm -f "$MENU_OUTPUT_TEMPLATE"

if [ $exit_status -ne 0 ]; then
  clear
  echo "VM creation cancelled."
  exit
fi

# --- Select SDN VNet ---
# Get list of VNets and format for dialog (tag item)
# Uses pvesh with json output and jq for reliable parsing
VNET_LIST=$(pvesh get /cluster/sdn/vnets --output-format json 2>/dev/null | jq -r '.[] | "\(.vnet) \(.vnet)"')

if [ -z "$VNET_LIST" ]; then
    dialog --title "Error" --msgbox "No SDN VNets found or SDN is not configured." 8 50
    clear
    exit 1
fi

MENU_OUTPUT_VNET=$(mktemp)
dialog --backtitle "Proxmox VM Deployer" \
       --title "Select Network" \
       --menu "\nChoose the SDN VNet for this VM:" \
20 60 15 \
$VNET_LIST \
2> "$MENU_OUTPUT_VNET"

exit_status=$?
SELECTED_VNET=$(cat "$MENU_OUTPUT_VNET")
rm -f "$MENU_OUTPUT_VNET"

if [ $exit_status -ne 0 ]; then
  clear
  echo "VM creation cancelled."
  exit
fi


# --- TUI Form ---
# We redirect stderr (where dialog sends output) to a temporary file
FORM_OUTPUT=$(mktemp)
dialog --backtitle "Proxmox VM Deployer" \
       --title "Create New Cloud-Init VM" \
       --form "\nFill in the details for the new VM (Template: $SELECTED_TEMPLATE_ID, VNet: $SELECTED_VNET):" \
25 70 16 \
  "New VM ID:"           1 1 "" 1 20 8 0 \
  "VM Name (Hostname):"  2 1 "" 2 20 40 0 \
  "vCPU Cores:"          3 1 "2" 3 20 8 0 \
  "Memory (GB):"         4 1 "4" 4 20 8 0 \
  "Disk Size (GB):"      5 1 "20" 5 20 8 0 \
  "Admin Username:"      7 1 "admin" 7 20 40 0 \
  "Admin Password:"      8 1 "" 8 20 40 0 \
  "SSH PubKey (Paste key OR path):" 9 1 "" 9 20 70 1024 \
  "IPv4 Address/CIDR:"   11 1 "192.168.1.100/24" 11 20 40 0 \
  "IPv4 Gateway:"        12 1 "192.168.1.1" 12 20 40 0 \
  "IPv6 Address/CIDR:"   13 1 "" 13 20 40 0 \
  "IPv6 Gateway:"        14 1 "" 14 20 40 0 \
  "DNS Server:"          15 1 "8.8.8.8" 15 20 40 0 \
2> "$FORM_OUTPUT"

# Get the exit status of dialog
exit_status=$?

# Read the form output from the temp file into an array
mapfile -t VALUES < "$FORM_OUTPUT"
rm -f "$FORM_OUTPUT" # Clean up the temp file

# Check if the user pressed "Cancel" or ESC
if [ $exit_status -ne 0 ]; then
  clear
  echo "VM creation cancelled."
  exit
fi

# --- Assign Form Values to Variables ---
VMID="${VALUES[0]}"
VMNAME="${VALUES[1]}"
VCPU="${VALUES[2]}"
MEM_GB="${VALUES[3]}"
DISK_GB="${VALUES[4]}"
USERNAME="${VALUES[5]}"
PASSWORD="${VALUES[6]}"
SSH_PUB_KEY_INPUT="${VALUES[7]}"
IPV4="${VALUES[8]}"
GWV4="${VALUES[9]}"
IPV6="${VALUES[10]}"
GWV6="${VALUES[11]}"
DNS="${VALUES[12]}"

# --- Validate Input ---
if [ -z "$VMID" ] || [ -z "$VMNAME" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$IPV4" ] || [ -z "$GWV4" ]; then
    dialog --title "Error" --msgbox "Missing required fields. Please fill out all fields (except optional SSH key)." 8 50
    clear
    exit 1
fi

# Convert Memory from GB to MB
MEM_MB=$((MEM_GB * 1024))

# Build ipconfig string
IPCONFIG="ip=$IPV4,gw=$GWV4"
if [ -n "$IPV6" ] && [ -n "$GWV6" ]; then
  IPCONFIG+=",ip6=$IPV6,gw6=$GWV6"
fi

# --- Confirmation Dialog ---
dialog --title "Confirm Deployment" \
       --yesno "\nReady to create VM $VMID ($VMNAME) with:\n
- Template: $SELECTED_TEMPLATE_ID
- Network:  $SELECTED_VNET
- vCPUs:    $VCPU
- Memory:   $MEM_GB GB ($MEM_MB MB)
- Disk:     $DISK_GB GB on $DEFAULT_STORAGE
- User:     $USERNAME
- IPv4:     $IPV4
\nWARNING: The password will be set via the command line.\n
Proceed with creation?" 20 60

# Check if user confirmed
if [ $? -ne 0 ]; then
  clear
  echo "VM creation cancelled."
  exit
fi

# --- Deployment Function ---
# This function will run in the MAIN shell, so it has
# direct access to all variables (VMID, KEY_FILE_PATH, etc.)
deploy_vm() {
  echo "Starting deployment of VM $VMID: $VMNAME..."
  echo "----------------------------------------------"
  sleep 1

  echo "Step 1: Cloning template $SELECTED_TEMPLATE_ID to $VMID..."
  qm clone "$SELECTED_TEMPLATE_ID" "$VMID" --name "$VMNAME" --full --storage "$DEFAULT_STORAGE"
  if [ $? -ne 0 ]; then echo "CLONE FAILED!"; exit 1; fi
  echo "Clone complete."
  echo ""

  echo "Waiting for VM lock to be released..."
  # Loop until 'qm config' succeeds, which means the clone lock is gone
  while ! qm config "$VMID" > /dev/null 2>&1; do
    echo -n "."
    sleep 1
  done
  echo "" # <-- ADDED: This prints a newline to finish the "...." line
  echo "VM lock released." # <-- MODIFIED: Removed the '\n'
  echo ""

  echo "Step 2: Configuring Hardware..."
  qm set "$VMID" --cores "$VCPU"
  qm set "$VMID" --memory "$MEM_MB"
  echo "Hardware configured."
  echo ""

  echo "Step 3: Resizing disk..."
  # IMPORTANT: Change 'scsi0' if your template uses a different disk type (e.g., 'virtio0')
  qm resize "$VMID" scsi0 "+${DISK_GB}G"
  if [ $? -ne 0 ]; then echo "DISK RESIZE FAILED! (Is 'scsi0' correct?)"; exit 1; fi
  echo "Disk resized."
  echo ""

  echo "Step 4: Configuring Network..."
  # This configures 'eth0' inside the VM
  qm set "$VMID" --net0 "virtio,bridge=$SELECTED_VNET"
  qm set "$VMID" --ipconfig0 "$IPCONFIG"
  qm set "$VMID" --nameserver "$DNS"
  qm set "$VMID" --searchdomain "$DEFAULT_DOMAIN"
  echo "Network configured."
  echo ""

  echo "Step 5: Configuring Cloud-Init User..."
  qm set "$VMID" --ciuser "$USERNAME"
  # This sets the password. Be aware it's visible in process lists briefly.
  qm set "$VMID" --cipassword "$PASSWORD"
  echo "User '$USERNAME' configured."
  echo ""

  # This logic is now guaranteed to work, as KEY_FILE_PATH is
  # set in the same shell.
  if [ -n "$KEY_FILE_PATH" ]; then
    echo "Step 6: Adding SSH Public Key from $KEY_FILE_PATH..."
    
    qm set "$VMID" --sshkeys "$KEY_FILE_PATH"
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then echo "ADDING SSH KEY FAILED! (Check key format)"; exit 1; fi
    echo "SSH key added."
  else
    echo "Step 6: Skipping SSH Key (not provided)."
  fi
  echo ""

  echo "Step 7: Starting VM $VMID..."
  qm start "$VMID"
  if [ $? -ne 0 ]; then echo "VM START FAILED!"; exit 1; fi
  echo "----------------------------------------------"
  echo "DEPLOYMENT COMPLETE!"
  echo ""
  echo "VM $VMID ($VMNAME) is starting."
  # Extract just the IP from the CIDR for the SSH example
  echo "You can connect via: ssh $USERNAME@${IPV4%/*}"
  sleep 5
}

# --- Execute Deployment ---

# Create a variable to hold the temp file path
KEY_FILE_PATH=""
SSH_KEY_TEMP_FILE="" # Hold the temp file name for cleanup

# --- SSH Key File Prep ---
# This logic runs in the MAIN script.
if [ -n "$SSH_PUB_KEY_INPUT" ]; then
    # No echo here, it would appear before the log box
    
    local key_string=""
    local key_path="$SSH_PUB_KEY_INPUT"
    
    # Handle tilde expansion
    if [[ "$key_path" == \~* ]]; then
        key_path="$HOME${key_path:1}"
    fi

    # Check if the input is a readable file path
    if [ -f "$key_path" ] && [ -r "$key_path" ]; then
      key_string=$(cat "$key_path")
    else
      key_string="$SSH_PUB_KEY_INPUT"
    fi
    
    # Create a temporary file to hold the key string
    SSH_KEY_TEMP_FILE=$(mktemp)
    if [ $? -ne 0 ]; then
        dialog --title "Error" --msgbox "Failed to create temp file for SSH key." 6 50
        clear
        exit 1
    fi
    
    # Use 'echo -n' to prevent a trailing newline
    # This is the fix for the "SSH public key validation error"
    echo -n "$key_string" > "$SSH_KEY_TEMP_FILE"
    
    # Set the variable for the deploy_vm function
    KEY_FILE_PATH="$SSH_KEY_TEMP_FILE"
fi

# --- Execute Deployment with Live Log (No Pipe) ---
LOG_FILE=$(mktemp)

# Start the log viewer in the background
dialog --title "Deployment Log" --tailbox "$LOG_FILE" 25 80 &
DIALOG_PID=$!

# Run the deployment, redirecting output to the log file
# This runs in the MAIN shell, so all variables are in scope!
deploy_vm > "$LOG_FILE" 2>&1

# Wait a brief moment for the last log lines to appear
sleep 1

# Stop the log viewer
kill $DIALOG_PID
wait $DIALOG_PID 2>/dev/null # Suppress "Terminated" message

# --- Cleanup ---
# Clean up the temp file AFTER the log box is closed
if [ -n "$KEY_FILE_PATH" ]; then
  rm -f "$KEY_FILE_PATH"
fi
rm -f "$LOG_FILE" # Clean up the log file

# Clean up the screen after dialog exits
clear
echo "VM $VMID ($VMNAME) deployment process finished."
echo "Check the log above for details."