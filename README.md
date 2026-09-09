# Proxmox VE Scripts

One-command scripts to create ready-to-use virtual machines (and, in the future,
containers) on a [Proxmox VE](https://www.proxmox.com/en/proxmox-virtual-environment/overview)
host. Inspired by the excellent [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE)
project.

Run the command on your Proxmox VE host shell, as root. Each script is
interactive with sensible defaults, and every setting can be overridden with
environment variables for unattended use.

## Virtual machines (`vm/`)

| Script | Description | Command |
| --- | --- | --- |
| [DDEV VM](docs/ddev.md) | Debian 13 VM with Docker + [DDEV](https://ddev.com) preinstalled, for local web development environments | `bash -c "$(curl -fsSL https://raw.githubusercontent.com/trebormc/proxmox-scripts/main/vm/ddev.sh)"` |

## Containers (`ct/`)

Nothing here yet.

## Repository layout

- `vm/` — scripts that create QEMU/KVM virtual machines (cloud image + cloud-init).
- `ct/` — scripts that create LXC containers (future).
- `docs/` — one document per script with requirements, options and internals.

## License

[MIT](LICENSE)
