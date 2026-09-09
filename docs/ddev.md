# DDEV VM

Creates a Debian 13 virtual machine on a Proxmox VE host with
[Docker Engine](https://docs.docker.com/engine/) (official repository) and
[DDEV](https://ddev.com) (official repository) preinstalled, ready to host
local web development environments.

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)"
```

## Requirements

- Proxmox VE 7.2 or newer (uses `import-from` for disk import).
- Run as **root** on the PVE host shell.
- A storage with **Snippets** content enabled (usually `local`). The script
  needs it to store the cloud-init user-data file. If missing, enable it in
  *Datacenter → Storage → local → Edit → Content → Snippets*.
- Internet access from the host (downloads the Debian cloud image) and from the
  VM (installs packages on first boot).

## What it does

1. Asks for the installation type:
   - **Default** (recommended): asks for the VM name (`ddev-xxx`, where you
     replace `xxx` with your project name), the static IP (`10.42.0.2xx/24`
     placeholder, or `dhcp`), the RAM (default 16 GiB) and the disk size
     (default 20 GiB). Everything else uses the defaults from the table below.
   - **Advanced**: additionally asks for VM ID, CPU, storage, bridge,
     gateway, autostart, username and password.
2. Downloads the Debian 13 `genericcloud` image to
   `/var/lib/vz/template/cache/` (reused on subsequent runs).
3. Writes a cloud-init user-data snippet to the snippets storage
   (`ddev-vm-<VMID>-user-data.yaml`).
4. Creates the VM (`virtio-scsi-single`, `cpu host`, QEMU guest agent enabled,
   serial console, DHCP networking) and imports the disk.
5. Starts the VM. On first boot, cloud-init:
   - creates your user (sudo without password, member of `docker`),
   - installs your host's SSH public keys,
   - sets the timezone (`Europe/Madrid` by default),
   - upgrades packages and installs `qemu-guest-agent`, `git`, `htop`, `vim`
     and `tmux` (with lingering enabled, so detached sessions survive after
     the last SSH connection closes),
   - enables compressed swap in RAM (zram, zstd, 50% of RAM) so memory
     pressure degrades performance instead of OOM-killing containers,
   - enables automatic security updates (`unattended-upgrades`),
   - installs Docker Engine and DDEV from their official APT repositories,
   - configures Docker log rotation (`max-size: 10m`, `max-file: 3` per
     container) so logs cannot fill the disk,
   - enables auto-login on the Proxmox console (noVNC and xterm.js),
     LXC-style — opening the console drops you into a shell as your user,
     while SSH still requires key or password,
   - runs `ddev config global --router-bind-all-interfaces` so DDEV sites are
     reachable from other machines on your network (not just from inside the VM).
6. Sets a Proxmox description on the VM (name, network, user, creation date)
   so it is easy to identify in the web UI.
7. Waits for provisioning to finish and prints the VM's IP address.

First boot takes a few minutes (full `apt upgrade` + Docker + DDEV install).

## Configuration

The most common settings can be passed as flags — note the `--` separating
them from the `bash -c` command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)" \
  -- --name ddev-myproject --ip 10.42.0.201/24
```

When both `--name` and `--ip` are given, nothing is asked at all — the VM is
created straight away with the default settings.

| Flag | Description |
| --- | --- |
| `--name <name>` | VM name/hostname |
| `--ip <cidr\|dhcp>` | Static IP in CIDR notation, or `dhcp` |
| `--gateway <ip>` | Gateway for static IP |
| `--bridge <bridge>` | Network bridge |
| `--vmid <id>` | Proxmox VM ID |
| `--advanced` | Ask for every setting instead of using defaults |
| `-h`, `--help` | Show help |

Every setting (these and more) can also be provided as an environment
variable, which skips its prompt. The name and IP prompts show placeholders
(`ddev-xxx`, `10.42.0.2xx/24`) and insist until you replace them with real
values. With stdin not attached to a terminal the script runs unattended
using defaults.

| Variable | Default | Description |
| --- | --- | --- |
| `VMID` | next free ID | Proxmox VM ID |
| `VM_NAME` | `ddev` | VM name and hostname |
| `CORES` | all host cores | CPU cores (KVM time-shares CPU, so this is safe) |
| `RAM` | `16384` | Maximum RAM in MiB, capped to host RAM minus a reserve (10%, min 2 GiB) |
| `BALLOON` | `1024` | Minimum guaranteed RAM in MiB (ballooning; see below) |
| `DISK_SIZE` | `20` | Disk size in GiB |
| `STORAGE` | first active image storage | Storage for the VM disk |
| `BRIDGE` | `vmbr1` | Network bridge |
| `IP_ADDR` | `dhcp` | Static IP in CIDR notation (e.g. `192.168.1.50/24`), or `dhcp` |
| `GATEWAY` | `x.x.x.1` of `IP_ADDR` | Gateway (only asked when `IP_ADDR` is static) |
| `ONBOOT` | `1` | Start the VM when the host boots |
| `TIMEZONE` | `Europe/Madrid` | Timezone inside the VM |
| `CI_USER` | `ddev` | Username inside the VM |
| `CI_PASSWORD` | `ddev` | Password for that user (console/SSH) |

Example (unattended, static IP):

```bash
VMID=200 VM_NAME=ddev-client1 DISK_SIZE=80 CI_PASSWORD='s3cret' \
  IP_ADDR=192.168.1.50/24 GATEWAY=192.168.1.1 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)"
```

## Memory behavior (ballooning)

The VM is created with `memory=16384` and `balloon=1024` (defaults): it can
use up to 16 GiB, with 1 GiB guaranteed. QEMU does not pre-reserve the full
16 GiB — host pages are allocated as the guest touches them. Without
ballooning they would never be returned; with it, when the **host** memory
usage goes above ~80%, Proxmox automatically reclaims memory from VMs (down
to their `balloon` minimum, proportionally — not all VMs drop to the minimum
at once) and redistributes it. While the host has plenty of free RAM, VMs
keep whatever they have touched. CPU needs no such mechanism: idle vCPUs cost
nothing, cores are time-shared.

The ceiling is elastic but not free: several VMs *actively* using lots of
memory at the same time can still exhaust the host — ballooning cannot
reclaim memory that is genuinely in use. If containers inside a VM get
OOM-killed under host pressure, raise its floor: `qm set <vmid> --balloon 2048`.
Set `BALLOON` equal to `RAM` to disable ballooning (fixed allocation), e.g.
for databases that react badly to memory being reclaimed.

## After installation

```bash
ssh ddev@<VM_IP>
mkdir mysite && cd mysite
ddev config          # pick your project type (drupal, wordpress, php...)
ddev start
```

Sites are served on the VM's IP. To use `*.ddev.site` names from your
workstation, point them at the VM's IP in your DNS or `/etc/hosts`, or use
`ddev start` output URLs directly. To avoid HTTPS warnings, install DDEV's CA
on your workstation (see [DDEV docs on `mkcert`](https://ddev.readthedocs.io/en/stable/users/install/)).

## Security notes

- The default password is `ddev` — change it (`CI_PASSWORD`) if the VM is
  reachable beyond your LAN. SSH keys found on the host
  (`/root/.ssh/authorized_keys`, `/root/.ssh/id_*.pub`) are installed
  automatically.
- The cloud-init snippet on the host contains the password in plain text and
  is created with mode `600` (root only).

## Removing the VM

```bash
qm stop <VMID> && qm destroy <VMID> --purge
rm /var/lib/vz/snippets/ddev-vm-<VMID>-user-data.yaml
```

The cached cloud image in `/var/lib/vz/template/cache/` can be kept for future
runs or deleted freely.
