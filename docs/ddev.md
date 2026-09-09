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

1. Asks for VM settings (ID, name, CPU, RAM, disk, storage, bridge, user).
   Defaults are shown in brackets; press Enter to accept them.
2. Downloads the Debian 13 `genericcloud` image to
   `/var/lib/vz/template/cache/` (reused on subsequent runs).
3. Writes a cloud-init user-data snippet to the snippets storage
   (`ddev-vm-<VMID>-user-data.yaml`).
4. Creates the VM (`virtio-scsi-single`, `cpu host`, QEMU guest agent enabled,
   serial console, DHCP networking) and imports the disk.
5. Starts the VM. On first boot, cloud-init:
   - creates your user (sudo without password, member of `docker`),
   - installs your host's SSH public keys,
   - upgrades packages and installs `qemu-guest-agent`,
   - installs Docker Engine and DDEV from their official APT repositories,
   - runs `ddev config global --router-bind-all-interfaces` so DDEV sites are
     reachable from other machines on your network (not just from inside the VM).
6. Waits for provisioning to finish and prints the VM's IP address.

First boot takes a few minutes (full `apt upgrade` + Docker + DDEV install).

## Configuration

Every prompt can be skipped by exporting the variable beforehand. With all
variables set (or stdin not attached to a terminal), the script runs
unattended using defaults for anything not provided.

| Variable | Default | Description |
| --- | --- | --- |
| `VMID` | next free ID | Proxmox VM ID |
| `VM_NAME` | `ddev` | VM name and hostname |
| `CORES` | `4` | CPU cores |
| `RAM` | `8192` | RAM in MiB |
| `DISK_SIZE` | `60` | Disk size in GiB |
| `STORAGE` | first active image storage | Storage for the VM disk |
| `BRIDGE` | `vmbr0` | Network bridge |
| `ONBOOT` | `1` | Start the VM when the host boots |
| `CI_USER` | `ddev` | Username inside the VM |
| `CI_PASSWORD` | `ddev` | Password for that user (console/SSH) |

Example (unattended):

```bash
VMID=200 VM_NAME=ddev-client1 DISK_SIZE=80 CI_PASSWORD='s3cret' \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)"
```

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
