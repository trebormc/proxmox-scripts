#!/usr/bin/env bash
# ddev.sh — Create a Debian 13 VM on Proxmox VE with Docker + DDEV preinstalled.
#
# Run on a Proxmox VE host, as root:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)"
#
# Every setting can be overridden with environment variables (skips the prompt):
#   VMID=200 DISK_SIZE=80 bash -c "$(curl -fsSL ...)"
#
# See docs/ddev.md for the full list of variables and details.

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

ask VMID "VM ID" "$DEFAULT_VMID"
ask VM_NAME "VM name" "ddev"
ask CORES "CPU cores" "4"
ask RAM "RAM (MiB)" "8192"
ask DISK_SIZE "Disk size (GiB)" "60"
ask STORAGE "Storage for the VM disk" "$DEFAULT_STORAGE"
ask BRIDGE "Network bridge" "vmbr0"
ask ONBOOT "Start VM on host boot (0/1)" "1"
ask CI_USER "VM username" "ddev"
ask CI_PASSWORD "VM user password (console/SSH)" "ddev"

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
msg_info "Summary: VMID=$VMID name=$VM_NAME cores=$CORES ram=${RAM}MiB disk=${DISK_SIZE}GiB storage=$STORAGE bridge=$BRIDGE user=$CI_USER"
if [[ -t 0 ]]; then
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

runcmd:
  - systemctl enable --now qemu-guest-agent
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
qm set "$VMID" --ipconfig0 ip=dhcp >/dev/null
qm set "$VMID" --cicustom "user=$SNIP_STORAGE:snippets/$SNIPPET_NAME" >/dev/null
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
if [[ $AGENT_UP -eq 1 ]]; then
  msg_ok "Guest agent is up. Waiting for cloud-init to finish (Docker + DDEV install)..."
  for _ in $(seq 1 180); do
    if qm guest exec "$VMID" -- test -f /var/lib/cloud/instance/ddev-provisioned >/dev/null 2>&1; then
      break
    fi
    sleep 10
  done
  VM_IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null |
    grep -oP '"ip-address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
    grep -v '^127\.' | head -n1 || true)
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
