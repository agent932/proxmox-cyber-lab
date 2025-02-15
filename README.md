# Proxmox Cyber Lab

Scripts and configurations for setting up a comprehensive cybersecurity lab using Proxmox Virtual Environment. This lab is designed for network simulation, cybersecurity training, and testing in a controlled environment.

## Features

- **pfSense Firewall**: Configured as the central router for managing VLANs and isolated networks.
- **VLAN Networking**: Multiple VLANs for management, security tools, testing, and auxiliary services.
- **Proxmox VMs**: Virtual machines tailored for cybersecurity purposes.
- **Scalable Design**: Easily extendable for additional VMs, tools, or networking configurations.

### VLAN Configuration
| VLAN ID | Purpose                  | Subnet         |
|---------|--------------------------|----------------|
| 1       | Management Network       | 192.168.100.0/24 |
| 10      | Security Tools Network   | 10.10.10.0/24    |
| 20      | Testing Network          | 10.10.20.0/24    |
| 30      | Auxiliary Services Network | 10.10.30.0/24    |

## Requirements

- Proxmox VE installed.
- Root access to the Proxmox server.
- Internet access to download ISO files and updates.

## Usage

To set up the pfSense firewall, execute the following command in your Proxmox server shell:

```bash
bash -c "$(wget -qLO - https://github.com/<your-username>/proxmox-cyber-lab/blob/main/pfsense_setup.sh)"
