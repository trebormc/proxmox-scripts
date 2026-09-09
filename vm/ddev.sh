#!/usr/bin/env bash
# ddev.sh — Create a Debian 13 VM on Proxmox VE with Docker + DDEV preinstalled.
#
# Run on a Proxmox VE host, as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)"
#
# Settings can be passed as flags (skips the prompt):
#   bash -c "$(curl -fsSL ...)" -- --name ddev-myproject --ip 192.168.1.50/24
#
# ...or as environment variables:
#   VMID=200 DISK_SIZE=80 bash -c "$(curl -fsSL ...)"
#
# Anything not provided is asked interactively, with sensible defaults.
# See docs/ddev.md for the full list of options and details.

set -Eeuo pipefail

# --- output helpers ---------------------------------------------------------
RD=$'\033[01;31m' GN=$'\033[1;92m' YW=$'\033[33m' BL=$'\033[36m' CL=$'\033[m'
msg_info() { echo -e "${BL}[INFO]${CL} $1"; }
msg_ok() { echo -e "${GN}[ OK ]${CL} $1"; }
msg_warn() { echo -e "${YW}[WARN]${CL} $1"; }
msg_error() { echo -e "${RD}[FAIL]${CL} $1" >&2; }

trap 'msg_error "Script failed at line $LINENO while running: $BASH_COMMAND"' ERR

# Ask for a value unless the variable is already set via environment.
# Falls back to the default when stdin is not a terminal (non-interactive use).
ask() {
  local __var=$1 __prompt=$2 __default=$3 __value=""
  if [[ -n "${!__var:-}" ]]; then
    return 0
  fi
  if [[ -t 0 ]]; then
    read -rp "$__prompt [$__default]: " __value
  fi
  printf -v "$__var" '%s' "${__value:-$__default}"
}

# --- flags ------------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: ddev.sh [options]

  --name <name>       VM name/hostname (e.g. ddev-myproject)
  --ip <cidr|dhcp>    Static IP in CIDR notation (e.g. 10.42.0.201/24) or 'dhcp'
  --gateway <ip>      Gateway for static IP (default: .1 of the network)
  --bridge <bridge>   Network bridge (default: vmbr1)
  --vmid <id>         Proxmox VM ID (default: next free)
  --advanced          Ask for every setting instead of using defaults
  -h, --help          Show this help

The default installation only asks for the VM name and the IP; everything
else uses defaults. Use --advanced to review every setting. Environment
variables work too: VMID, VM_NAME, CORES, RAM, BALLOON, DISK_SIZE, STORAGE,
BRIDGE, IP_ADDR, GATEWAY, ONBOOT, TIMEZONE, CI_USER, CI_PASSWORD, ADVANCED.

When piping through bash -c, pass flags after '--':
  bash -c "$(curl -fsSL .../vm/ddev.sh)" -- --name ddev-myproject --ip 192.168.1.50/24
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) VM_NAME=${2:?--name needs a value}; shift 2 ;;
    --ip) IP_ADDR=${2:?--ip needs a value}; shift 2 ;;
    --gateway) GATEWAY=${2:?--gateway needs a value}; shift 2 ;;
    --bridge) BRIDGE=${2:?--bridge needs a value}; shift 2 ;;
    --vmid) VMID=${2:?--vmid needs a value}; shift 2 ;;
    --advanced) ADVANCED=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *)
      msg_error "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

# --- sanity checks ----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  msg_error "This script must run as root on a Proxmox VE host."
  exit 1
fi
if ! command -v qm >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
  msg_error "This does not look like a Proxmox VE host ('qm'/'pvesm' not found)."
  exit 1
fi

# Snippets-capable storage is required for the cloud-init user-data file.
SNIP_STORAGE=$(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}' || true)
if [[ -z $SNIP_STORAGE ]]; then
  msg_error "No active storage with 'Snippets' content found."
  msg_error "Enable it on 'local': Datacenter -> Storage -> local -> Edit -> Content -> add 'Snippets'."
  exit 1
fi
SNIP_PATH=$(pvesh get "/storage/$SNIP_STORAGE" --output-format json 2>/dev/null | grep -oP '"path"\s*:\s*"\K[^"]+' || true)
if [[ -z $SNIP_PATH ]]; then
  msg_error "Could not resolve the filesystem path of storage '$SNIP_STORAGE'."
  exit 1
fi
mkdir -p "$SNIP_PATH/snippets"

# --- configuration ----------------------------------------------------------
echo -e "\n${GN}DDEV VM for Proxmox VE${CL} — Debian 13 + Docker + DDEV\n"

DEFAULT_VMID=$(pvesh get /cluster/nextid)
DEFAULT_STORAGE=$(pvesm status --content images | awk 'NR>1 && $3=="active" {print $1; exit}')

# CPU is time-shared by KVM, so giving the VM every host core is safe and lets
# DDEV use whatever is idle. RAM is an elastic ceiling thanks to ballooning
# (16 GiB max / 1 GiB guaranteed by default): pages are only taken as the VM
# touches them, and under host memory pressure Proxmox reclaims down to the
# balloon minimum. The default is still capped to what the host can spare
# (total minus 10%, keeping at least 2 GiB for Proxmox itself).
HOST_CORES=$(nproc)
HOST_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_RESERVE=$((HOST_RAM_MB / 10))
((RAM_RESERVE < 2048)) && RAM_RESERVE=2048
RAM_AVAIL=$((HOST_RAM_MB - RAM_RESERVE))
DEFAULT_RAM=16384
((DEFAULT_RAM > RAM_AVAIL)) && DEFAULT_RAM=$RAM_AVAIL

# Installation type: default only asks VM name and IP; advanced asks everything.
# With name and IP already given (flags/env), run fully unattended: no
# installation-type question and no final confirmation.
PRESET=0
[[ -n ${VM_NAME:-} && -n ${IP_ADDR:-} ]] && PRESET=1

if [[ -z ${ADVANCED:-} ]]; then
  ADVANCED=0
  if [[ -t 0 && $PRESET -eq 0 ]]; then
    read -rp "Installation type — [d]efault (recommended) / [a]dvanced [d]: " INSTALL_MODE
    [[ ${INSTALL_MODE,,} == a* ]] && ADVANCED=1
  fi
fi

# VM name: 'ddev-xxx' is a placeholder — the user must replace 'xxx' with the
# real project name. Re-ask until they do (interactive mode only).
while [[ -z ${VM_NAME:-} || $VM_NAME == ddev-xxx ]]; do
  if [[ ${VM_NAME:-} == ddev-xxx ]]; then
    msg_warn "'ddev-xxx' is a placeholder — replace 'xxx' with your project name."
    VM_NAME=""
  fi
  if [[ -t 0 ]]; then
    read -rp "VM name (e.g. ddev-myproject) [ddev-xxx]: " VM_NAME
    VM_NAME=${VM_NAME:-ddev-xxx}
  else
    VM_NAME="ddev"
  fi
done
if [[ ! $VM_NAME =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
  msg_error "Invalid VM name '$VM_NAME' — use letters, digits and hyphens (it becomes the hostname)."
  exit 1
fi

# Static IP: '10.42.0.2xx/24' is a placeholder — replace 'xx' with the real
# host number. 'dhcp' is also accepted. Re-ask until valid (interactive only).
while :; do
  if [[ -z ${IP_ADDR:-} && -t 0 ]]; then
    read -rp "Static IP with CIDR, or 'dhcp' [10.42.0.2xx/24]: " IP_ADDR
    IP_ADDR=${IP_ADDR:-10.42.0.2xx/24}
  fi
  IP_ADDR=${IP_ADDR:-dhcp}
  if [[ ${IP_ADDR,,} == dhcp ]]; then
    IPCONFIG="ip=dhcp"
    break
  elif [[ $IP_ADDR == *xx* ]]; then
    msg_warn "'10.42.0.2xx/24' is a placeholder — replace 'xx' with the real host number (e.g. 10.42.0.201/24)."
  elif [[ $IP_ADDR =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    IP_BASE=${IP_ADDR%/*}
    if [[ $ADVANCED -eq 1 ]]; then
      ask GATEWAY "Gateway" "${IP_BASE%.*}.1"
    else
      GATEWAY=${GATEWAY:-${IP_BASE%.*}.1}
    fi
    IPCONFIG="ip=$IP_ADDR,gw=$GATEWAY"
    break
  else
    msg_warn "Invalid IP '$IP_ADDR' — expected CIDR notation like 10.42.0.201/24, or 'dhcp'."
  fi
  if [[ ! -t 0 ]]; then
    msg_error "Invalid IP_ADDR value in non-interactive mode."
    exit 1
  fi
  IP_ADDR=""
done

# RAM and disk are asked in both installation types (but not when running
# unattended with name and IP preset).
if [[ $PRESET -eq 1 && $ADVANCED -eq 0 ]]; then
  RAM=${RAM:-$DEFAULT_RAM}
  DISK_SIZE=${DISK_SIZE:-20}
else
  ask RAM "RAM (MiB)" "$DEFAULT_RAM"
  ask DISK_SIZE "Disk size (GiB)" "20"
fi

if [[ $ADVANCED -eq 1 ]]; then
  ask VMID "VM ID" "$DEFAULT_VMID"
  ask CORES "CPU cores" "$HOST_CORES"
  ask BALLOON "Minimum guaranteed RAM with ballooning (MiB)" "1024"
  ask STORAGE "Storage for the VM disk" "$DEFAULT_STORAGE"
  ask BRIDGE "Network bridge" "vmbr1"
  ask ONBOOT "Start VM on host boot (0/1)" "1"
  ask TIMEZONE "Timezone" "Europe/Madrid"
  ask CI_USER "VM username" "ddev"
  ask CI_PASSWORD "VM user password (console/SSH)" "ddev"
else
  VMID=${VMID:-$DEFAULT_VMID}
  CORES=${CORES:-$HOST_CORES}
  BALLOON=${BALLOON:-1024}
  STORAGE=${STORAGE:-$DEFAULT_STORAGE}
  BRIDGE=${BRIDGE:-vmbr1}
  ONBOOT=${ONBOOT:-1}
  TIMEZONE=${TIMEZONE:-Europe/Madrid}
  CI_USER=${CI_USER:-ddev}
  CI_PASSWORD=${CI_PASSWORD:-ddev}
fi

# The balloon minimum can never exceed the assigned RAM.
((BALLOON > RAM)) && BALLOON=$RAM

if qm status "$VMID" >/dev/null 2>&1; then
  msg_error "VMID $VMID is already in use."
  exit 1
fi
if ! pvesm status --content images | awk 'NR>1 {print $1}' | grep -qx "$STORAGE"; then
  msg_error "Storage '$STORAGE' does not exist or cannot store VM disks."
  exit 1
fi

# Collect SSH public keys from the host so you can log in without a password.
SSH_KEYS=""
for f in /root/.ssh/authorized_keys /root/.ssh/id_*.pub; do
  [[ -r $f ]] && SSH_KEYS+="$(grep -hE '^(ssh-|ecdsa-)' "$f" 2>/dev/null || true)"$'\n'
done
SSH_KEYS=$(echo "$SSH_KEYS" | sort -u | sed '/^$/d')
if [[ -z $SSH_KEYS ]]; then
  msg_warn "No SSH public keys found on the host; you will only have password access."
fi

echo
# shellcheck disable=SC2153 # variables are assigned indirectly by ask() via printf -v
msg_info "Summary: VMID=$VMID name=$VM_NAME cores=$CORES ram=${RAM}MiB disk=${DISK_SIZE}GiB storage=$STORAGE bridge=$BRIDGE net=$IPCONFIG user=$CI_USER"
if [[ -t 0 && $PRESET -eq 0 ]]; then
  read -rp "Proceed? [Y/n]: " CONFIRM
  if [[ ${CONFIRM,,} == n* ]]; then
    msg_warn "Aborted by user."
    exit 0
  fi
fi

# --- download cloud image ---------------------------------------------------
IMG_NAME="debian-13-genericcloud-amd64.qcow2"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/$IMG_NAME"
IMG_CACHE_DIR="/var/lib/vz/template/cache"
IMG_FILE="$IMG_CACHE_DIR/$IMG_NAME"

mkdir -p "$IMG_CACHE_DIR"
if [[ -f $IMG_FILE ]]; then
  msg_ok "Using cached cloud image: $IMG_FILE"
else
  msg_info "Downloading Debian 13 cloud image..."
  curl -fL --progress-bar -o "$IMG_FILE.tmp" "$IMG_URL"
  mv "$IMG_FILE.tmp" "$IMG_FILE"
  msg_ok "Image downloaded to $IMG_FILE"
fi

# --- cloud-init user-data ---------------------------------------------------
SNIPPET_NAME="ddev-vm-$VMID-user-data.yaml"
SNIPPET_FILE="$SNIP_PATH/snippets/$SNIPPET_NAME"

SSH_KEYS_YAML=""
while IFS= read -r key; do
  [[ -n $key ]] && SSH_KEYS_YAML+="      - $key"$'\n'
done <<<"$SSH_KEYS"

msg_info "Writing cloud-init user-data to $SNIPPET_FILE"
cat >"$SNIPPET_FILE" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
timezone: $TIMEZONE

users:
  - name: $CI_USER
    groups: [sudo, docker]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
$SSH_KEYS_YAML
chpasswd:
  expire: false
  users:
    - name: $CI_USER
      password: $CI_PASSWORD
      type: text
ssh_pwauth: true

package_update: true
package_upgrade: true
packages:
  - qemu-guest-agent
  - ca-certificates
  - curl
  - gnupg
  - git
  - htop
  - vim
  - tmux
  - zram-tools
  - unattended-upgrades

# write_files runs before package install, so Docker picks up daemon.json on
# its very first start.
write_files:
  # Rotate container logs so they cannot fill the disk.
  - path: /etc/docker/daemon.json
    content: |
      {
        "log-driver": "json-file",
        "log-opts": {
          "max-size": "10m",
          "max-file": "3"
        }
      }
  # Enable automatic security updates (Debian's standard periodic config).
  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
  # Compressed swap in RAM: absorbs memory pressure (e.g. when Proxmox
  # ballooning reclaims memory) instead of OOM-killing containers.
  - path: /etc/default/zramswap
    content: |
      ALGO=zstd
      PERCENT=50

runcmd:
  - systemctl enable --now qemu-guest-agent
  - systemctl restart zramswap
  - install -m 0755 -d /etc/apt/keyrings
  # Docker (official repository)
  - curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  - echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \$VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  # DDEV (official repository)
  - curl -fsSL https://pkg.ddev.com/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/ddev.gpg
  - echo "deb [signed-by=/etc/apt/keyrings/ddev.gpg] https://pkg.ddev.com/apt/ * *" > /etc/apt/sources.list.d/ddev.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ddev
  - usermod -aG docker $CI_USER
  # Keep the user's background processes (e.g. tmux sessions) alive after the
  # last SSH session closes, regardless of logind's KillUserProcesses setting.
  - loginctl enable-linger $CI_USER
  # Make DDEV sites reachable from other machines on the network (this is a VM, not localhost)
  - su - $CI_USER -c "ddev config global --router-bind-all-interfaces"
  - touch /var/lib/cloud/instance/ddev-provisioned
EOF
chmod 600 "$SNIPPET_FILE"

# --- create the VM ----------------------------------------------------------
msg_info "Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --ostype l26 \
  --cores "$CORES" \
  --memory "$RAM" \
  --balloon "$BALLOON" \
  --cpu host \
  --net0 "virtio,bridge=$BRIDGE" \
  --scsihw virtio-scsi-single \
  --agent enabled=1 \
  --serial0 socket \
  --onboot "$ONBOOT" >/dev/null

msg_info "Importing disk into storage '$STORAGE' (this can take a moment)..."
qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMG_FILE,discard=on" >/dev/null
qm set "$VMID" --ide2 "$STORAGE:cloudinit" >/dev/null
qm set "$VMID" --boot order=scsi0 >/dev/null
qm disk resize "$VMID" scsi0 "${DISK_SIZE}G" >/dev/null
qm set "$VMID" --ipconfig0 "$IPCONFIG" >/dev/null
qm set "$VMID" --cicustom "user=$SNIP_STORAGE:snippets/$SNIPPET_NAME" >/dev/null
qm set "$VMID" --description "# $VM_NAME

DDEV development VM (Debian 13 + Docker + DDEV)

- **Network:** $IPCONFIG
- **User:** $CI_USER
- **Created:** $(date '+%Y-%m-%d') by [proxmox-scripts](https://github.com/trebormc/proxmox-scripts)" >/dev/null
msg_ok "VM $VMID created."

msg_info "Starting VM..."
qm start "$VMID" >/dev/null

# --- wait for provisioning --------------------------------------------------
msg_info "Waiting for the guest agent (installed by cloud-init on first boot)..."
AGENT_UP=0
for _ in $(seq 1 120); do
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    AGENT_UP=1
    break
  fi
  sleep 5
done

VM_IP=""
[[ ${IP_ADDR,,} != dhcp ]] && VM_IP=${IP_ADDR%/*}
if [[ $AGENT_UP -eq 1 ]]; then
  msg_ok "Guest agent is up. Waiting for cloud-init to finish (Docker + DDEV install)..."
  for _ in $(seq 1 180); do
    if qm guest exec "$VMID" -- test -f /var/lib/cloud/instance/ddev-provisioned >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  if [[ -z $VM_IP ]]; then
    VM_IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null |
      grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
      grep -v '^127\.' | head -n1 || true)
  fi
else
  msg_warn "Guest agent did not come up in time; the VM may still be provisioning."
fi

# --- summary ----------------------------------------------------------------
echo
msg_ok "Done! VM $VMID ($VM_NAME) is ready."
echo
echo "  User:     $CI_USER"
if [[ -n $VM_IP ]]; then
  echo "  IP:       $VM_IP"
  echo "  SSH:      ssh $CI_USER@$VM_IP"
else
  echo "  IP:       not detected yet — check the VM console or your DHCP server"
fi
echo
echo "  Check provisioning status inside the VM:  cloud-init status"
echo "  Create your first project:                mkdir myproject && cd myproject && ddev config"
echo
