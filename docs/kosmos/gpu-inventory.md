# GPU inventory and NVIDIA driver choice

Surveyed 2026-09-29 from kosmos over ssh (`lspci -n`, `nvidia-smi`,
`nvidia-smi topo -m`, `dpkg`), before the clean reinstall on Ubuntu 26.04.
All nodes then ran Ubuntu 22.04 (kernel 5.15), Secure Boot off, the
proprietary (non-open) kernel modules from Ubuntu's `-server` packages, with
the driver, DCGM and container toolkit packages on `apt-mark hold`.

## Nodes

| Node | GPUs | PCI ID | Architecture (compute capability) | GPU interconnect | Driver on 22.04 |
|------|------|--------|-----------------------------------|------------------|-----------------|
| alanturing, hamilton | 8x GeForce RTX 2080 Ti, 11 GB | `10de:1e04` | Turing (7.5) | PCIe only | 550.54.15 |
| roentgen | 4x Quadro RTX 8000, 48 GB | `10de:1e30` | Turing (7.5) | PCIe only | 550.54.15 |
| aristarchus (6), galileo (8), ptolemaeus (8) | RTX A6000, 48 GB | `10de:2230` | Ampere (8.6) | NVLink bridges in pairs (NV4) | 580.173.02 |
| euctemon, eudoxus | 8x A100 80GB PCIe | `10de:20b5` | Ampere (8.0) | NVLink bridges in pairs (NV12) | 580.173.02 |
| herakles | 8x H100 80GB HBM3 SXM5 (HGX) | `10de:2330` | Hopper (9.0) | 4 NVSwitch (`10de:22a3`), all-to-all NV18; 2 InfiniBand NICs | 580.173.02 + `nvidia-fabricmanager-580` |
| gaia | none (CPU partition) | | | | |

mariecurie (4x Quadro P6000, Pascal, `10de:1b30`) was dropped with the
reinstall; its partition `p6000` is gone from the site config. It was the
only GPU the 590+ branches and the open kernel modules cannot drive.

The same data is in the `gpus` custom fact on every node
(`roles/facts/files/gpus.fact`): `count`, `pci_ids` and `nvswitch_count`,
read from the PCI bus so they are there before any driver is installed.
`topology.fact` uses the same class filter (`0300`/`0302`) for
`gpu_topology` (cpulistaffinity per GPU bus). Match GPUs on PCI IDs, not
names: Ubuntu 22.04's `lspci` shows the H100 as "Device [10de:2330]".

## Driver branch: 580 everywhere

Ubuntu 26.04's archive has two real server branches, 580 (580.178.04) and
595 (595.91.07). `nvidia-headless-{535,550,570}-server` are transitional
packages that install 580, and `590` installs 595. Checked against the
`Modaliases` of `nvidia-driver-{580,595}-server` in resolute-updates: both
list every GPU above; only 580 lists the P6000.

580 was chosen (2026-09-29): NVIDIA's long-term support branch, and CUDA
13.x applications run on drivers >= 580 under minor version compatibility
(CUDA toolkit release notes), so containers built on CUDA 13.2 (NGC 26.04)
run. 595 would be the native branch for CUDA 13.2. Switching is one line,
`nvidia_driver_branch` in `config/group_vars/all.yml`; the fabric manager
and DCGM package names follow it.

## What the playbooks do per node

- **Driver:** `playbooks/nvidia-software/nvidia-driver.yml` (role
  `nvidia.nvidia_driver`) installs `nvidia-headless-580-server` and friends
  on every node whose `gpus.count` is non-zero. Before that it refuses a
  node with a GPU missing from `nvidia_gpu_architectures`
  (`config/group_vars/all.yml`), or whose architecture is in
  `nvidia_gpu_legacy_architectures` while the branch is above 580 or the
  open kernel modules are on.
- **Fabric manager:** on nodes with `gpus.nvswitch_count > 0` (herakles),
  `tasks/nvidia-fabricmanager.yml` installs `nvidia-fabricmanager-580` at
  the driver's exact upstream version, enables the service and waits until
  `nvidia-smi -q` reports `Fabric State: Completed, Status: Success` for
  every GPU. Without it, CUDA on an NVSwitch system fails with "system not
  yet initialized". The PCIe A100 and A6000 nodes use NVLink bridges and
  need no fabric manager.
- **DCGM:** `datacenter-gpu-manager-4-cuda13` (DCGM 4 for a CUDA 13
  driver). The role's default `datacenter-gpu-manager` is DCGM 3, which
  NVIDIA's ubuntu2604 repository does not carry.
- **Open kernel modules:** off (`nvidia_driver_ubuntu_use_open_kernel_modules:
  false`), as on 22.04. Every GPU above supports them; NVIDIA makes them the
  default for Turing and newer, and Blackwell GPUs require them.

## Slurm GPU-CPU affinity (gres.conf)

Surveyed 2026-09-30 on all nine GPU nodes (Slurm 23.02.4). `gres.conf` tells
slurmd which device file each GPU is and which CPU cores sit on its socket.
The generated file used the topology fact's `local_cpulist` for `Cores=`:
Linux CPU **thread** ids, while Slurm expects its own **core** ids. With
hyperthreading every list contains ids beyond the core count, and Slurm
rejects the whole list ("invalid GRES core specification", `bit_unfmt` in
`src/common/bitstring.c`), so no GPU had CPU affinity. That shows as
`Gres=gpu:8` without `(S:...)` in `scontrol show node`.

| Nodes | Slurm cores | Generated `Cores=` (socket 0 GPU) | `/dev/nvidiaN` in PCI order |
|-------|-------------|-----------------------------------|-----------------------------|
| alanturing, hamilton, roentgen | 0-19 | `0-9,20-29` | yes |
| aristarchus, galileo, ptolemaeus, euctemon, eudoxus | 0-63 | `0-31,64-95` | no |
| herakles | 0-95 | `0-47,96-143` | no |

The fact also numbers GPUs in PCI order, while the driver's device minors
(`/proc/driver/nvidia/gpus/*/information`) differ on six nodes; the shuffle
stayed within a socket everywhere except aristarchus, whose hand-edited
`gres.conf` (eight lines, two commented out) put `nvidia2`/`nvidia3` on
socket 0 instead of 1. The `gpu_topology` lists in the host_vars of carlos,
plato and schrodinger were never read by any template.

From Slurm 24.11, `gres.conf` is a single `AutoDetect=nvidia` line
(`slurm_gres_autodetect` in `config/group_vars/slurm-cluster.yml`). slurmd
then reads the device minors itself and converts each GPU's CPU list to
Slurm core ids; no NVML build and no CUDA toolkit are needed. It does not
detect NVLinks (`AutoDetect=nvml` would, and could prefer bridged pairs on the
A6000/A100 nodes). `Gres=gpu:N` in slurm.conf stays untyped and still matches.
The driver must be loaded before slurmd starts, or the node reports fewer
GPUs than configured and is drained: `playbooks/slurm-cluster.yml` installs
the driver before Slurm. Check after the reinstall with
`scontrol show node <node>`: a socket suffix such as `Gres=gpu:8(S:0-1)`
means the affinity is known (`(S:0)` on alanturing and hamilton, whose GPUs
all hang off socket 0).

## Adding a GPU node

1. Put the node in `config/inventory` (see the README).
2. Look up its GPU's PCI ID (`lspci -nn -d 10de:`) and add it with its
   architecture to `nvidia_gpu_architectures`. The driver playbook refuses
   the node until it is there.
3. Run `nvidia-driver.yml` with `--check --diff --limit <node>` first.
