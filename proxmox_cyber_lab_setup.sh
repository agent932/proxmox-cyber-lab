#!/usr/bin/env bash
# ----------------------------------------------------------------------------------
# Proxmox Cyber Lab: Automatic Network & VM Setup (Draft)
# ----------------------------------------------------------------------------------
# Author: Your Name (GitHub: agent932)
# License: MIT
#
# Description:
#   This script sets up a VLAN-aware bridge on Proxmox and creates multiple VMs
#   with recommended defaults for a cybersecurity lab environment:
#     - pfSense
#     - Kali Linux
#     - Windows 10
#     - Windows 11
#     - Ubuntu (Docker/Portainer)
#     - Security Onion
#
#   The script now queries the Proxmox host for available network interfaces
#   (excluding loopback) and lets the user choose the physical NIC to use.
# ----------------------------------------------------------------------------------

###############################################################################
# 1. PRE-FLIGHT CHECKS
###############################################################################

function check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run this script as root (sudo ./scriptname.sh)."
    exit 1
  fi
}

function check_pve() {
  if ! command -v pveversion &>/dev/null; then
    echo "This script must be run on a Proxmox VE host."
    exit 1
  fi
}

function arch_check() {
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    echo "Non-amd64 architecture detected. This script may not work on PiMox or ARM."
    exit 1
  fi
}

function check_ifupdown2() {
  if ! dpkg -l | grep -q ifupdown2; then
    echo -e "WARNING: ifupdown2 is not installed.\n" \
            "You may need to manually edit /etc/network/interfaces for VLAN bridging.\n" \
            "Press Ctrl+C to cancel, or Enter to continue anyway."
    read -r
  fi
}

###############################################################################
# 2. NETWORK INTERFACE SELECTION
###############################################################################
# Query the system for available interfaces (excluding loopback) and let the
# user choose which one to use for the physical NIC.

function select_network_interface() {
  local interfaces=()
  for iface in $(ls /sys/class/net | grep -v "^lo$"); do
    interfaces+=("$iface" "")
  done

  if [[ ${#interfaces[@]} -eq 0 ]]; then
    echo "No network interfaces found!"
    exit 1
  fi

  local chosen_iface
  chosen_iface=$(whiptail --title "Select Physical NIC" \
    --menu "Choose a physical network interface for bridging:" 15 60 4 \
    "${interfaces[@]}" 3>&1 1>&2 2>&3)
    
  if [ $? -ne 0 ]; then
    echo "User cancelled."
    exit 1
  fi

  echo "$chosen_iface"
}

###############################################################################
# 3. NETWORK CONFIGURATION (VLAN-AWARE BRIDGE)
###############################################################################
# CAUTION: Editing network config can cause you to lose connectivity.
# Make sure to test on a non-production system or via a local console.

function configure_vlan_bridge() {
  local BRIDGE="vmbr0"
  
  if [ -z "$PHYS_NIC" ]; then
    echo "PHYS_NIC not set. Aborting."
    exit 1
  fi

  echo "Configuring VLAN-aware bridge ($BRIDGE) on interface $PHYS_NIC ..."
  echo "Backing up /etc/network/interfaces to /etc/network/interfaces.bak.$(date +%F_%T)"
  cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%F_%T)
  
  # Overwrite/create a basic config for vmbr0 as a VLAN-aware bridge.
  cat <<EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto $PHYS_NIC
iface $PHYS_NIC inet manual

auto $BRIDGE
iface $BRIDGE inet dhcp
    bridge-ports $PHYS_NIC
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
EOF

  # Attempt to apply the new network configuration
  if command -v ifreload &>/dev/null; then
    ifreload -a || {
      echo "ifreload failed. Check your network config!"
      exit 1
    }
  else
    echo "Applying network config with ifdown/ifup..."
    ifdown $BRIDGE || true
    ifup $BRIDGE || {
      echo "Failed to bring up $BRIDGE. Check your network config!"
      exit 1
    }
  fi
  echo "VLAN-aware bridge $BRIDGE configured. Continuing..."
}

###############################################################################
# 4. VM CREATION - RECOMMENDED DEFAULTS
###############################################################################
# Adjust these as needed. For Windows, ensure you have ISO and VirtIO drivers.

# Global defaults
STORAGE="local-lvm"             # Adjust to your storage
ISO_STORAGE="local"             # Where ISOs are stored
DEFAULT_BRIDGE="vmbr0"          # VLAN trunk bridge
DEFAULT_DISK_CACHE="none"       # or "writethrough"
DEFAULT_SCSI_HW="virtio-scsi-pci"
DEFAULT_BIOS="ovmf"             # For UEFI

# Helper to create a generic VM
# Usage: create_vm <vmid> <name> <cores> <memory> <diskGB> <iso_file> <vlan_tag>
function create_vm() {
  local VMID="$1"
  local NAME="$2"
  local CORES="$3"
  local MEM="$4"
  local DISK_GB="$5"
  local ISO="$6"
  local VLAN="$7"

  echo -e "\nCreating VM: $NAME (VMID: $VMID) on VLAN $VLAN"
  qm create "$VMID" \
    --name "$NAME" \
    --cores "$CORES" \
    --memory "$MEM" \
    --net0 "virtio,bridge=$DEFAULT_BRIDGE,tag=$VLAN" \
    --scsihw "$DEFAULT_SCSI_HW" \
    --bios "$DEFAULT_BIOS" \
    --boot order=scsi0

  # Attach storage disk
  qm set "$VMID" \
    --scsi0 "$STORAGE:0,cache=$DEFAULT_DISK_CACHE,size=${DISK_GB}G" &>/dev/null

  # Attach ISO (if provided)
  if [[ -n "$ISO" && "$ISO" != "none" ]]; then
    qm set "$VMID" \
      --ide2 "$ISO_STORAGE:iso/$ISO,media=cdrom" &>/dev/null
  fi
}

# pfSense recommended defaults
function create_pfsense() {
  local VMID=900
  local NAME="pfSense"
  local CORES=2
  local MEM=2048
  local DISK_GB=16
  local ISO="pfSense-2.6.0-RELEASE-amd64.iso"  # Example name

  echo -e "\nCreating pfSense VM..."
  qm create "$VMID" \
    --name "$NAME" \
    --cores "$CORES" \
    --memory "$MEM" \
    --bios "$DEFAULT_BIOS" \
    --scsihw "$DEFAULT_SCSI_HW" \
    --boot order=scsi0

  qm set "$VMID" \
    --scsi0 "$STORAGE:0,cache=$DEFAULT_DISK_CACHE,size=${DISK_GB}G" &>/dev/null

  # WAN NIC (no VLAN tag)
  qm set "$VMID" \
    --net0 "virtio,bridge=$DEFAULT_BRIDGE" &>/dev/null

  # LAN NIC (trunk with VLANs)
  qm set "$VMID" \
    --net1 "virtio,bridge=$DEFAULT_BRIDGE" &>/dev/null

  # Attach pfSense ISO
  qm set "$VMID" \
    --ide2 "$ISO_STORAGE:iso/$ISO,media=cdrom" &>/dev/null

  echo "pfSense VM (VMID $VMID) created. Manual configuration in pfSense UI is still required."
}

function create_kali() {
  local VMID=901
  local NAME="Kali-Linux"
  local CORES=2
  local MEM=2048
  local DISK_GB=32
  local ISO="kali-linux-2023.1.iso"  # Example
  local VLAN=30
  create_vm "$VMID" "$NAME" "$CORES" "$MEM" "$DISK_GB" "$ISO" "$VLAN"
  echo "Kali VM (VMID $VMID) created."
}

function create_windows10() {
  local VMID=902
  local NAME="Windows10"
  local CORES=2
  local MEM=4096
  local DISK_GB=60
  local ISO="Win10_21H2_English_x64.iso"  # Example
  local VLAN=20
  create_vm "$VMID" "$NAME" "$CORES" "$MEM" "$DISK_GB" "$ISO" "$VLAN"

  # Attach VirtIO drivers ISO if you have it
  qm set "$VMID" \
    --ide3 "$ISO_STORAGE:iso/virtio-win.iso,media=cdrom" &>/dev/null

  echo "Windows 10 VM (VMID $VMID) created. Remember to install VirtIO drivers."
}

function create_windows11() {
  local VMID=903
  local NAME="Windows11"
  local CORES=4
  local MEM=8192
  local DISK_GB=80
  local ISO="Win11_English_x64.iso"  # Example
  local VLAN=20
  create_vm "$VMID" "$NAME" "$CORES" "$MEM" "$DISK_GB" "$ISO" "$VLAN"

  # Attach VirtIO drivers ISO if you have it
  qm set "$VMID" \
    --ide3 "$ISO_STORAGE:iso/virtio-win.iso,media=cdrom" &>/dev/null

  echo "Windows 11 VM (VMID $VMID) created. Remember to install VirtIO drivers."
}

function create_ubuntu_docker() {
  local VMID=904
  local NAME="Ubuntu-Docker"
  local CORES=2
  local MEM=2048
  local DISK_GB=32
  local ISO="ubuntu-22.04.2-live-server-amd64.iso"  # Example
  local VLAN=10
  create_vm "$VMID" "$NAME" "$CORES" "$MEM" "$DISK_GB" "$ISO" "$VLAN"
  echo "Ubuntu Docker VM (VMID $VMID) created. You can install Docker & Portainer manually or via Cloud-Init."
}

function create_security_onion() {
  local VMID=905
  local NAME="SecurityOnion"
  local CORES=4
  local MEM=8192
  local DISK_GB=80
  local ISO="securityonion-2.3.200.iso"  # Example
  local VLAN=40
  create_vm "$VMID" "$NAME" "$CORES" "$MEM" "$DISK_GB" "$ISO" "$VLAN"

  # Additional NIC configuration can be added if needed.
  echo "Security Onion VM (VMID $VMID) created."
}

###############################################################################
# 5. MAIN EXECUTION
###############################################################################

function main() {
  echo "Proxmox Cyber Lab Setup - Recommended Defaults"
  echo "WARNING: This script modifies Proxmox network config and creates multiple VMs."
  echo "Press ENTER to continue or Ctrl+C to abort."
  read -r

  check_root
  check_pve
  arch_check
  check_ifupdown2

  # Let the user choose the physical NIC for the bridge.
  PHYS_NIC=$(select_network_interface)
  echo "Selected Physical NIC: $PHYS_NIC"

  # 1. Configure VLAN-aware bridge (vmbr0)
  configure_vlan_bridge

  # 2. Create pfSense (2 NICs: WAN + LAN trunk)
  create_pfsense

  # 3. Create Kali Linux (VLAN 30)
  create_kali

  # 4. Create Windows 10 (VLAN 20)
  create_windows10

  # 5. Create Windows 11 (VLAN 20)
  create_windows11

  # 6. Create Ubuntu Docker (VLAN 10)
  create_ubuntu_docker

  # 7. Create Security Onion (VLAN 40)
  create_security_onion

  echo -e "\nAll VMs have been created with recommended defaults."
  echo "Next Steps:"
  echo " - Configure pfSense (assign WAN/LAN, enable VLANs)."
  echo " - Install OS on each VM (Windows, Linux)."
  echo " - For Windows, mount VirtIO drivers and install them."
  echo " - For Linux, optionally use Cloud-Init or manual installation."
  echo " - Adjust VLAN tags or add more NICs as needed."
  echo " - Enjoy your new cybersecurity lab!"
}

main

