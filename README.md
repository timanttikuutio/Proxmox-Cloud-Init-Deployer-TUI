# **Proxmox Cloud-Init Deployer TUI**

A simple Bash script that uses dialog to provide a friendly Text-based User Interface (TUI) for deploying new Proxmox VMs from Cloud-Init templates.

It automates the entire process, including setting the hostname, user, password, SSH keys, network configuration, and hardware specs, all from one simple form.

## **Features**

* **User-Friendly TUI:** A simple form interface built with dialog.  
* **Auto-Discovery:** Automatically detects and lists your available VM templates.  
* **SDN Integration:** Automatically detects and lets you choose from your cluster's SDN VNets.  
* **Full Cloud-Init Config:** Configures all essential parameters:  
  * VM ID and Hostname  
  * vCPU and Memory  
  * Disk Resize (on scsi0 by default)  
  * Admin Username & Password  
  * SSH Public Key (accepts a pasted key or a file path)  
  * Static IPv4/IPv6 networking and DNS  
* **Live Log:** Shows the output of all qm commands in real-time during deployment.

## **Requirements**

1. **Proxmox Node:** This script must be run directly on a Proxmox VE node.  
2. **dialog:** apt update && apt install dialog  
3. **jq:** apt update && apt install jq  
4. **A Cloud-Init Template:** You must have at least one VM template prepared for Cloud-Init.

## **Crucial: Template Setup Guide**

This script will **only work** if your template is correctly prepared. Official cloud images (like those from Ubuntu or Debian) need extra steps.

1. **Download Image:** Get an official cloud image.  
   wget \[https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img\](https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img)

2. **Create the VM:**  
   \# Create a new VM (e.g., ID 9000\)  
   qm create 9000 \--name "ubuntu-2204-cloud-template" \--memory 2048 \--net0 virtio,bridge=vmbr0

   \# Import the downloaded disk to your target storage  
   qm importdisk 9000 jammy-server-cloudimg-amd64.img YOUR\_STORAGE

   \# Attach the disk to the VM as scsi0  
   qm set 9000 \--scsihw virtio-scsi-pci \--scsi0 YOUR\_STORAGE:vm-9000-disk-0

   \# Add the Cloud-Init CD-ROM drive  
   qm set 9000 \--ide2 YOUR\_STORAGE:cloudinit

   \# Make the imported disk the boot drive  
   qm set 9000 \--boot c \--bootdisk scsi0

3. Fix Guest Issues (The Most Important Step):  
   Official images often lack the QEMU guest agent and have SSH password/key auth disabled. You must fix this.  
   a. Temporarily set a user/pass to log in:  
   bash qm set 9000 \--ciuser temp-admin \--cipassword 'your-password'  
   b. Start the VM (ID 9000\) and log in via the Proxmox console as temp-admin.  
   c. Install guest agent and fix SSH:  
   \`\`\`bash  
   sudo apt update  
   sudo apt install qemu-guest-agent \-y  
   sudo systemctl enable \--now qemu-guest-agent  
   \# This is the fix for SSH keys  
   sudo nano /etc/ssh/sshd\_config  
   \# Find and uncomment the line: PubkeyAuthentication yes

   sudo systemctl restart sshd  
   \`\`\`

   d. Clean the VM for templating:  
   bash sudo cloud-init clean \-s \-l sudo rm /etc/machine-id sudo touch /etc/machine-id history \-c sudo shutdown \-h now  
4. Finalize Template:  
   a. In the Proxmox UI, wait for the VM to shut down.  
   b. Go to its Options and enable the QEMU Guest Agent.  
   c. Go to its Cloud-Init tab and remove the temporary user and password.  
   d. Right-click the VM and "Convert to template".

## **Usage**

1. Make the script executable:  
   chmod \+x pmx\_deploy.sh

2. Run the script:  
   ./pmx\_deploy.sh

3. Follow the on-screen TUI to select your template, VNet, and fill out the VM details.

## **Configuration**

You can change the following variables at the top of pmx\_deploy.sh to match your environment:

* DEFAULT\_STORAGE="YOUR\_STORAGE": The default storage pool to clone to and resize on.  
* DEFAULT\_DOMAIN="local": The default DNS search domain.

### **Troubleshooting**

* **"DISK RESIZE FAILED\!"**: This almost always means your template's disk is not scsi0. Open the deploy\_vm function in the script and change the line qm resize "$VMID" scsi0 ... to use the correct disk (e.g., virtio0).  
* **"SSH KEY FAILED\!"**: Ensure you have followed the **Template Setup Guide** (Step 3\) to install the qemu-guest-agent and fix sshd\_config.