# Kosmos porting notes: DeepOps 26.07 branch

Branch `deepops-26.07` rebuilds this fork as **NVIDIA DeepOps tag 26.07 plus a
small set of overlay commits**. The overlay ports what is on `master` (fork
point: DeepOps 23.08, commit d248b658). Contents:

- **Before the first run**: the test recipe.
- **Check-run results**: what each `--check --diff` run showed, per date and node.
- **Running playbooks from teuwen-ansible**: how ssh authentication works
  (Kerberos, not keys), which hosts are the exception, ticket expiry.
- **1. Conscious deviations from master**: every place where the branch
  deliberately differs from `master`, why, and the commit. Other admins can
  review each row and flip it back if they disagree.
- **2. Things to address after the port**: problems and oddities found while
  porting that were left as they are on master, by priority.

Rule used while porting: port `master` as is. Deviate only with a stated
reason, and record it here. Design changes that nobody has asked for are
not applied; they go into section 2.

**Status (2026-09-08):** port complete. env-26.07 built, syntax checks
pass, `--check --diff` done on all compute nodes except gaia for the
non-Slurm playbooks (see "Check-run results"), rendered slurm.conf matches
the live one. **Admin login to kosmos works again (2026-09-08, fixed by
IT), with Kerberos**, so `slurm.yml` is no longer blocked; atlas still
needs `-k` (no host principal in the realm, see "Running playbooks from
teuwen-ansible"). gaia's open-files problem is bypassed by gathering only
the `min` fact subset (096cc2ec). Decided: docker pinned to 28.3
(deviation 13), motd landscape task removed, nvtop pinned to 3.3.2
(deviation 15). Still pending with the admins: herakles driver
metapackages/reboot, apptainer pin, podman-docker on herakles, joining
atlas to the realm. Everything on
`master` up to e812a659 has been ported, dropped with a row below, or
superseded upstream.

## Before the first run

Do these in order, on teuwen-ansible. Steps 1 and 2 are done (2026-09-04).

1. Build the 26.07 environment next to the shared one, without touching
   `/opt/kosmos-cluster/env` (ansible-core 2.16, in use by the other admins):
   `VENV_DIR=/opt/kosmos-cluster/env-26.07 bash scripts/setup.sh`. This gives
   ansible 10.7 / core 2.17 and installs the 26.07 Galaxy roles and
   collections into `roles/galaxy` and `collections` (both gitignored; the
   old `roles/galaxy` from 23.08 is not compatible). Roles and collections
   both come from `roles/requirements.yml`; there is no
   `collections/requirements.yml` in 26.07. Use `bash scripts/setup.sh`, not
   `./scripts/setup.sh`: the shebang is `bash --init-file`, so executing it
   directly leaves you in a new interactive shell. Two harmless messages:
   "Package(s) not found: ansible" (the version check on an empty venv) and
   the fact-cache warning below. The script also appends a `source .../activate`
   line to your `.bashrc`.
2. `source /opt/kosmos-cluster/env-26.07/bin/activate` for everything below.
   Every other admin: follow the setup block at the top of the README (own
   clone, activate this venv, `ansible-galaxy install -r roles/requirements.yml`,
   which installs both roles and collections into the paths from
   `ansible.cfg`). Nobody runs `scripts/setup.sh` on teuwen-ansible except to
   deliberately rebuild the shared venv: it pip-installs into that venv, needs
   sudo for apt, and re-downloads the Galaxy content with `--force`.
3. Fix the default partition (section 2, "Urgent"). Done: `rtx2080ti`.
4. herakles: included in the tests as a normal node (decided 2026-09-04;
   see section 2, "Site config" for what a real run would change on it).
5. `ansible-playbook playbooks/slurm-cluster.yml --syntax-check`.
6. `ansible-playbook -kK --check --diff --limit atlas,kosmos,herakles playbooks/slurm-cluster/slurm.yml`
   (`-k` for atlas: the first play gathers facts from every inventory host,
   so the password is needed even with a limit). Was blocked 2026-09-04
   because kosmos refused admin accounts; **unblocked 2026-09-08**, see
   "Running playbooks from teuwen-ansible". Include atlas: with
   `slurm_conf_symlink: true` slurm.conf is rendered only there, into
   `/sw/.slurm`; compute nodes get a symlink, so a compute-only run shows
   the other role-managed files but not slurm.conf. While it was blocked,
   `docs/kosmos/render-slurm-conf.yml` (done 2026-09-04) rendered the
   template locally from the compute nodes' custom facts (Kerberos only, no
   atlas/kosmos) for a diff against `/sw/.slurm/slurm.conf`; it remains
   useful for checking a config change before a run. See "Check-run
   results".
6b. While slurm.yml is blocked, `--check --diff` the playbooks the top-level
   playbook imports that do not need atlas or kosmos, limited to compute
   nodes (`--limit gaia,herakles` first, then all of `slurm-node`):
   `nvidia-software/nvidia-driver.yml` (must report no change with the
   per-host pins), `generic/software.yml`, `generic/chrony-client.yml`,
   `slurm-cluster/nhc.yml`, `nvidia-software/nvidia-dcgm.yml`,
   `generic/rsyslog-client.yml`, `slurm-cluster/prometheus-node-exporter.yml`,
   `slurm-cluster/nvidia-dcgm-exporter.yml`. These are where the 26.07 roles
   differ most from 23.08. Pass all playbooks to one `ansible-playbook`
   invocation so `-K` asks once. gaia may fail at fact gathering (section 2,
   "Fact gathering fails ..."); use herakles and eudoxus first.
7. Only then consider a real run, playbook by playbook, starting with the
   ones that are idempotent on the current nodes (motd, nvtop, create_mounts).

## Running playbooks from teuwen-ansible

Checked on 2026-09-04 from kosmas-ans's account; other admins should see the
same, but verify with `klist` and `ssh -v <node> true` if in doubt.

**ssh to the nodes uses Kerberos, not keys.** teuwen-ansible and the nodes
are joined to the `RHPC.NKI.NL` realm (sssd). Logging in gives you a ticket
(`klist`), and ssh authenticates with it over GSSAPI (`ssh -v gaia true`
shows `Authenticated to gaia using "gssapi-with-mic"`). Ansible runs the
same ssh, so it connects the same way: an ad-hoc `ansible gaia,herakles -m
ping` succeeds with no key file and no `-k`. Nobody needs to generate or
distribute ssh keys for the compute nodes, and every admin keeps their own
identity for free.

- **Tickets expire after about a day** (see the `krbtgt` line in `klist`).
  Interactive ssh then silently falls back to a password prompt; Ansible
  cannot answer one and fails with "Permission denied (publickey,gssapi...)"
  on every host. Run `kinit` and retry.
- **No `~/.ssh` needed on teuwen-ansible.** Upstream's `ansible.cfg` put
  the ssh control sockets in `~/.ssh/ansible-...`, which does not exist on a
  fresh account (homes on teuwen-ansible are local, not the NFS home the
  nodes share, and Ansible never writes `known_hosts` there). Plain ssh
  worked, the playbook did not. Likely cause of the "ssh works but the
  playbook cannot connect" seen on 2026-09-03 (not confirmed from the error
  text; the directory appeared when an `ssh-keygen` created it). Fixed on
  this branch by dropping the override (deviation 0c): sockets now go to
  `~/.ansible/cp`, which Ansible creates itself. No key pair is needed either
  (the one upstream play that wanted a `.pub` file is off, see below).
- **atlas is the exception: it has no host principal in the realm.** Its
  sshd offers GSSAPI, but the KDC has no key for it, so no service ticket
  can be issued and ssh falls through to password. Verified 2026-09-08:
  `kvno host/atlas.rhpc.nki.nl` answers "Server
  host/atlas.rhpc.nki.nl@RHPC.NKI.NL not found in Kerberos database", while
  the same request for kosmos and every compute node returns a ticket. DNS
  is fine (atlas resolves in `rhpc.nki.nl` like the others). Runs that
  touch atlas need `-k`. `--limit gaia` no longer SSHes atlas for facts;
  the slurm.conf gatherer still SSHes every `slurm-node`, and any play
  that includes atlas (controller, full `slurm.yml`) still needs `-k`.
  The fix is to join atlas to the realm (host principal plus keytab, as
  sssd did on the compute nodes); needs root on atlas and possibly IT.
  Fallback: a key in your `authorized_keys` on atlas.
- **kosmos: fixed 2026-09-08.** From 2026-09-04 until then kosmos refused
  admin `-ans` accounts altogether (PAM denied the account with password
  and Kerberos alike; regular users got in), which blocked `slurm.yml`
  because that playbook used to gather facts from every inventory host.
  Central IT restored access; Kerberos ssh to kosmos now works like on
  the compute nodes (`ssh -o PreferredAuthentications=gssapi-with-mic
  kosmos true` authenticates, and `klist` shows a
  `host/kosmos.rhpc.nki.nl` ticket). The earlier note that kosmos
  "rejects the ticket" was this same outage, not a Kerberos problem:
  kosmos does not need `-k`. Fact gathering no longer targets kosmos.
- **Sudo on the nodes needs a password**: always `-K`. Same password as for
  `-k`.
- Node home directories are NFS from rhea, shared by all nodes; an
  `authorized_keys` entry made on one node applies to all of them. Your home
  on teuwen-ansible is separate.

**Two upstream places that assume keys; both need a decision:**

- `playbooks/slurm-cluster/slurm.yml`, second play, "Add SSH public key to
  root user authorized keys": upstream puts the running admin's public key
  (default `~/.ssh/id_rsa.pub`) into root's `authorized_keys` on every
  compute node, so every admin who runs the Slurm playbook gets passwordless
  root ssh everywhere, and the play fails when the file does not exist.
  **Off on this branch** (deviation 12, `slurm_add_root_ssh_key: false`).
  Nothing needs it: no playbook logs in as root, and pam_slurm_adopt does not
  block admins because their groups are in `/etc/localgroups`.
- `playbooks/bootstrap/bootstrap-ssh.yml` installs the admin's key on all
  hosts so that `-k` is not needed. With Kerberos that is redundant for the
  compute nodes; keep it disabled (it is, see section 2). If atlas cannot be
  joined to the realm, a key on that one host is the fallback.

**Environments on teuwen-ansible (until the branch is merged):**
`/opt/kosmos-cluster/env` (ansible-core 2.16, master, other admins) and
`/opt/kosmos-cluster/env-26.07` (ansible-core 2.17, this branch). Both stay
until the merge; then the old one goes. The root disk of teuwen-ansible was
95 % full (1.6 GB free) on 2026-09-04.

**Setup decision (2026-09-08):** only the venv is shared. There is no shared
checkout; each admin works from a private clone, pulls before running
playbooks, and submits changes as pull requests. Galaxy roles and collections
stay out of git (vendoring the 44 MB was considered and rejected);
`roles/requirements.yml` pins every version and is the lock file, and each
clone installs them once with the command in the README. Verified
2026-09-08: README steps, `kinit`, ad-hoc ping of all compute nodes, and
`prometheus-node-exporter.yml` in check mode on eudoxus with
`-e '{"docker_install": false}'` (facts served from the per-user cache on
the second run).

## Check-run results

### 2026-09-04, herakles and eudoxus, `--check --diff`, env-26.07

Nine playbooks in one invocation (nvtop, motd, mount_scratch_disks,
nvidia-driver, software, chrony-client, rsyslog-client, nhc, nvidia-dcgm);
the run stopped at nvidia-dcgm on herakles, so prometheus-node-exporter and
nvidia-dcgm-exporter are still untested. Log: `~kosmas-ans/check-all.log`.
No playbook failed for a reason related to the port. What a real run would
change:

- **No change (good):** rsyslog-client on both; nvidia-driver, chrony and
  nvidia-dcgm on eudoxus (the per-host driver pins do what deviation 11
  says). mount_scratch_disks reported no change, but its `exportfs`/`mount -a`
  command tasks are skipped in check mode, so that says nothing yet.
- **nvtop, both nodes:** the git clone reports a change (unpinned HEAD,
  section 2). Build steps skipped in check mode.
- **motd, both nodes:** the role would overwrite Ubuntu's current
  `50-landscape-sysinfo` (a symlink to the caching wrapper) with its own
  older copy. Same on gaia (section 2). Recommendation: drop that task from
  `roles/motd`; only `00-header` is site content.
- **nvidia-driver, herakles: would reboot the node.** herakles was
  hand-driven with the `nvidia-driver-580-server` metapackage (a
  `nvidia-driver-570-server` metapackage is still installed next to it);
  the role's package list is `nvidia-headless-580-server`,
  `nvidia-headless-no-dkms-580-server`, `nvidia-utils-580-server`,
  `nvidia-kernel-source-580-server`. The two headless metapackages are
  missing ("0 upgraded, 2 newly installed", no driver change), the role
  would also create an empty `/etc/modprobe.d/nvidia.conf`, and because
  packages changed it triggers its reboot task
  (`nvidia_driver_skip_reboot: no`). Before the first real driver run on
  herakles either install the two metapackages by hand or run with
  `-e nvidia_driver_skip_reboot=yes`, then verify with a check run that the
  role is idle.
- **software, both nodes:** `dcmtk` (in `software_extra_packages`) is not
  installed on either node; herakles also lacks `linux-tools-generic`. So
  software.yml has not run since dcmtk was added. Harmless to apply.
- **chrony-client, herakles:** still on Ubuntu's stock `chrony.conf`
  (`ntp.ubuntu.com` pools); the role would switch it to the site template
  (`0-3.pool.ntp.org` from `chrony_config_server`, `makestep 10 3`) and
  restart chrony, which is what eudoxus already runs. Fine, unless the
  admins prefer an NKI-internal NTP server, in which case set
  `chrony_config_server` first.
- **nhc, herakles:** full first install (deepops.nhc checks, nhc.conf,
  sysconfig with `NHC_RM=slurm`), which is the intended state (section 2).
  **nhc, eudoxus:** `nhc.conf` changes by 1 MB in the `check_hw_physmem`
  bounds (26.07 template rounding) and the commented-out `check_hw_eth`
  lines are reordered and gain the docker bridge. Cosmetic.
- **nvidia-dcgm, herakles: check-mode artifact, not a bug.** The role
  "installs" the CUDA keyring .deb (check mode does not really add the apt
  source), so the following `apt install datacenter-gpu-manager` finds no
  such package. A real run installs `datacenter-gpu-manager` 1:3.3.9, the
  same as on gaia (checked with `apt-cache policy` there). To get past it in
  check mode, install the keyring on herakles by hand first, or accept the
  failure and run the exporter playbooks separately.

### 2026-09-04, herakles and eudoxus, exporters (`--check --diff`)

`prometheus-node-exporter.yml` and `nvidia-dcgm-exporter.yml` both start by
importing `container/docker.yml` (kubespray's docker role), and both nodes
failed there, so the exporter roles themselves are still untested in check
mode. To skip docker, pass a real boolean: `-e '{"docker_install": false}'`.
`-e docker_install=no` does NOT work: it arrives as the string "no", which
the playbook's `when: docker_install | default('yes')` treats as true
(verified locally). Log:
`~kosmas-ans/check-exporters.log`.

- **herakles:** check-mode artifact, same pattern as DCGM: the docker apt
  source is only virtually added, so `containerd.io` is "not available".
- **eudoxus, and every other docker node: a real run upgrades docker.**
  All nine docker nodes run `docker-ce 5:26.1.2` and `containerd.io 1.6.28-2`,
  held with `apt-mark hold` (the kubespray role holds them after install).
  Site config does not pin a version (neither did master), so the 26.07
  kubespray default applies: `docker_version: '28.3'` (28.3.3) and
  `containerd.io 1.6.32`. In check mode apt refuses to touch held packages;
  in a real run the role removes the hold first and the upgrade goes
  through, restarting docker and with it the exporter containers on the
  nodes that run them. Jobs do not use docker (enroot/apptainer), so the
  impact is the monitoring restart, but it is a version change on every
  node. **Decided 2026-09-08: pin to 28.3** (deviation 13). Site config now
  sets `docker_version: '28.3'` and `docker_containerd_version: '1.6.32'`,
  so the version follows site config instead of whatever the next kubespray
  bump defaults to. Two corrections to the earlier note: the variable the
  docker role reads is `docker_containerd_version` (default 1.6.32), not
  `containerd_version`, which belongs to the containerd-as-runtime path and
  would have done nothing; and `1.6.28` *is* still in kubespray 2.31's table
  (`container-engine/docker/vars/ubuntu.yml`), so pinning the running
  versions was available. 28.3 was chosen deliberately, to sit on a
  supported release rather than to minimise the diff.
- Side observation from the same survey: on the A6000, A100 and RTX nodes
  the whole CUDA, driver and DCGM stack is on `apt-mark hold` (dozens of
  packages), on gaia only docker, on herakles only leftover 550-series
  packages. Whoever holds packages by hand should know the driver role
  installs with apt and would fail or be blocked by holds on a branch change.

### 2026-09-04, slurm.conf rendered locally vs the live `/sw/.slurm/slurm.conf`

`docs/kosmos/render-slurm-conf.yml` with env-26.07, facts from all ten
compute nodes. The live file was rendered by master on 2025-12-08. Every
difference is expected:

- `KillWait=30` -> `120` (deviation 3).
- carlos, plato, schrodinger, mariecurie node lines gone; partitions
  `rtx2080ti_sm` and `p6000` gone; `rtx2080ti` becomes `Default=YES`
  (phase-out commit e812a659 plus the default-partition fix, section 2).
- `RealMemory` for aristarchus 980306 -> 980304 and gaia 489970 -> 489957:
  the custom memory fact reports the current `MemTotal`, which moves by a
  few MB across kernel updates. Harmless (lower than before, so slurmd
  still accepts it).
- gaia gains `Procs=128`: the topology fact now reports it, the 2025 render
  predates that.
- Trailing whitespace on the blank line after the node list.

Everything else, including `ClusterName=kosmos`, every other node line,
the prolog/epilog, cgroup and health-check settings, is byte-identical.
This is the strongest evidence so far that the ported Slurm role and site
config reproduce the running cluster.

### 2026-09-04, all compute nodes except gaia, `--check --diff`

Nine nodes (`--limit 'slurm-node:!gaia'`), twelve playbooks requested; the
invocation stopped after nvidia-dcgm because of the herakles check-mode
artifact, so prometheus-node-exporter, nvidia-dcgm-exporter and apptainer
did not run on any node. (When one host fails in a playbook,
`ansible-playbook a.yml b.yml ...` does not start the following playbooks
for anyone. Keep nvidia-dcgm out of a combined check run until herakles has
the CUDA keyring.) Log: `~kosmas-ans/check-allnodes.log`. Findings, beyond
what the two-node run already showed:

- **Only herakles differs.** On the other eight nodes the driver, chrony,
  rsyslog, DCGM and mount playbooks are idle. In particular the 550 pins on
  alanturing, hamilton, roentgen and the 580 branch elsewhere produce no
  driver change anywhere (deviation 11 confirmed on every node).
- **Same on every node:** nvtop clone (unpinned), motd overwriting
  `50-landscape-sysinfo`, `dcmtk` missing (software.yml never ran with it),
  `nhc.conf` cosmetic changes (2 to 9 lines: `check_hw_physmem` rounding
  and reordered/added commented `check_hw_eth` lines).
- herakles: as in the two-node run (driver metapackages + reboot, first
  chrony, first NHC, DCGM artifact, also `linux-tools-generic`).

Still untested in check mode: the exporter roles, apptainer.yml, and
everything that needs atlas or kosmos. Command for the exporters and
apptainer:

```
ansible-playbook -K --check --diff --limit 'slurm-node:!gaia' \
  -e '{"docker_install": false}' \
  playbooks/slurm-cluster/prometheus-node-exporter.yml \
  playbooks/slurm-cluster/nvidia-dcgm-exporter.yml \
  playbooks/container/apptainer.yml
```

### 2026-09-08, atlas, kosmos and herakles, `slurm.yml` (`--check --diff`)

First run of the Slurm playbook from the branch (recipe step 6), after
kosmos access was restored. `ansible-playbook -kK --check --diff --limit
atlas,kosmos,herakles playbooks/slurm-cluster/slurm.yml`. No failures, no
unreachable hosts; 13 minutes, 32k log lines. Log:
`~kosmas-ans/check-slurm.log`. Findings, most important first:

- **A real run would replace the munge key, and only on the hosts in the
  run. Do not run `slurm.yml` for real on this branch before the vault
  change (`docs/kosmos/slurm-secrets-vault.md`) is rolled out on all
  twelve hosts in one run, on 2026-10-05.** The key is
  `slurm_password | password_hash('sha512', slurm_cluster_name)`. With the
  old env (ansible-core 2.16, no passlib) that gives the Python `crypt`
  form, 5000 rounds, `$6$kosmos$...`, which is the key on the nodes today
  (reproduced locally, byte for byte, from the placeholder password).
  env-26.07 has passlib 1.7.4 (upstream added it to `scripts/setup.sh` in
  February 2026, 7f3c71c6) and ansible-core 2.17 prefers it, so the same
  password now hashes to `$6$rounds=656000$kosmos$...`: a different key.
  The check shows the change on all three hosts. A limited real run would
  restart munge with the new key on those hosts and cut them off from the
  rest. Consequences for the vault rollout: every host in one run, all
  from env-26.07 (two envs would produce two keys from the same password).
  Side findings: the current key derives from the public upstream
  placeholder, so anyone with the DeepOps repo can compute it (another
  reason for the vault); `playbooks/utilities/user-password.yml` uses the
  same filter and will produce different hashes from the new env too
  (harmless: a password hash only has to verify, not match an old one).
  Not fixed: `rounds=5000` in the template would reproduce today's key,
  but the key changes with the vault password anyway (decided 2026-09-08).
- **A real run would reboot every compute node.** `roles/slurm/tasks/compute.yml`
  adds `GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} cgroup_enable=memory swapaccount=1"`
  to `/etc/default/grub` with `lineinfile` (no regexp: the exact line must
  exist), then runs `update-grub` and `reboot` when the line was added.
  All ten compute nodes instead carry the expanded form,
  `GRUB_CMDLINE_LINUX="pci=realloc=off cgroup_enable=memory swapaccount=1"`,
  twice, and not the role's line (checked on every node 2026-09-08). The
  kernel already runs with these options, so the reboot would change
  nothing, but it would hit nodes with running jobs. Task unchanged since
  23.08 and on master; someone rewrote the file by hand after
  provisioning. Fix deferred to the maintenance day, see "Maintenance day
  2026-10-05" in section 2.
- **Check-mode artifacts, not real changes:** thirty thousand of the log
  lines are the role "uninstalling" and preparing to rebuild hwloc, pmix
  and Slurm on all three hosts (remove build trees under
  `/opt/kosmos-cluster/build`, remove `/usr/local/lib/slurm`, stop all
  Slurm services). The version-check commands (`slurmd --version`,
  `hwloc-info --version`, ...) are skipped in check mode, so the "already
  installed" shortcut never fires; same mechanism as in the NHC role. All
  three hosts run Slurm 23.02.4 with hwloc and pmix built under
  `/opt/kosmos-cluster` (verified on kosmos and herakles), so a real run
  builds nothing. What a real run does do, by upstream design and on
  master too: the "configure slurm.conf on all nodes" play runs the
  misc-node tasks on every host, which stop and disable slurmctld, slurmd
  and slurmdbd; the controller and compute plays then restart and re-enable
  them. So a full `slurm.yml` run always restarts slurmctld and slurmdbd on
  atlas and slurmd on every node in the run.
- **slurm.conf** (rendered on atlas into `/sw/.slurm`, and the same diff on
  `/etc/slurm/slurm.conf` of all three hosts): `KillWait` 30 to 120
  (deviation 3); the four phased-out NodeName lines gone; partition table
  in the order of `partition_settings` (deviation 14); aristarchus
  RealMemory 980306 to 980304 and gaia 489970 to 489957 (custom memory
  fact, 95 % of MemTotal, drifts a few MB across boots); gaia's line gains
  `Procs=128`, which the 2025-12 render lacked. Nothing else.
- **herakles, first-run changes:** `pam_systemd.so` commented out in
  `/etc/pam.d/common-session` (pam_slurm_adopt requirement, done on the
  other nodes long ago); `/etc/localusers` and its backup rewritten;
  `epilog.d/50-exclusive-gpu` updated to the 26.07 version (`nvidia-smi
  pmon` parsing); `linux-tools-5.15.0-191-generic` installed.
- **kosmos:** the distro `libhwloc-dev` and `libpmix-dev` would be removed
  (the role removes them before using its own builds; unconditional on
  Ubuntu). Header packages only.
- **All three:** recursive `chmod 0755` of `/opt/kosmos-cluster` ("fix
  deepops dir permissions", upstream, always reports changed in check
  mode).
- `/etc/localusers` is templated from `SUDO_USER`, so it names whoever
  ran the playbook last (joren-ans today, kosmas-ans after a run). It is
  the pam_listfile of users allowed to ssh without a job; admins are
  covered by `/etc/localgroups` regardless, so this is cosmetic.
- Why 13 minutes for three hosts: check mode diffs every file of the build
  trees it pretends to delete, and the recursive chmod walks the same
  trees; both on three hosts. Expect a full twelve-host check run to take
  proportionally longer; a real run has neither.

## 1. Conscious deviations from master

| # | Where | Branch does | Master does | Why | Commit |
|---|-------|-------------|-------------|-----|--------|
| 0a | `ansible.cfg` | `pipelining = True` (upstream) | `pipelining = False` (EricMarcus-ai, 2024-06-03, "Disable ansible pipelining", no reason given) | Pipelining halves the SSH round-trips per task. It only fails when sudo enforces `requiretty`, which the nodes do not (checked on gaia). Flip: set `pipelining = False` | (not applied, branch keeps upstream) |
| 0b | `ansible.cfg` | no `[galaxy]` section (upstream) | `[galaxy] server = https://old-galaxy.ansible.com/` (Musab, 2023-11-02) | Temporary workaround from the late-2023 Galaxy migration; the host no longer serves content and 26.07 requirements resolve on galaxy.ansible.com. Flip: re-add the section | (not applied, branch keeps upstream) |
| 0d | `ansible.cfg` | `fact_caching_connection = ~/.ansible/fact_cache` (per user; Ansible expands `~` and creates the directory) | upstream and master: `/var/tmp/ansible_cache` | On teuwen-ansible that directory is `root:teu-ansible` mode 0700, so every admin got "error in 'jsonfile' cache ... disabling plugin" and facts were gathered on every run. A per-user path needs no shared directory or group. Flip: restore the path and `chmod` / `chgrp` the directory for the admin group | 2026-09-08 |
| 0c | `ansible.cfg` | no `control_path` override: ssh control sockets go to Ansible's default `~/.ansible/cp`, which Ansible creates itself | upstream (since the 2018 initial commit, no reason given): `control_path = ~/.ssh/ansible-%%r@%%h:%%p` | With the upstream setting Ansible fails on a fresh account until `~/.ssh` exists, and nothing creates it (`UserKnownHostsFile=/dev/null` in the same file means ssh never writes `known_hosts` there either). Bit kosmas-ans on 2026-09-03. Where the sockets live makes no functional difference. Flip: restore the line and `mkdir -m 700 ~/.ssh` | chunk 7 |
| 0e | `ansible.cfg` | `interpreter_python = /usr/bin/python3` | upstream (Adam Tetelman, 2021-12-10) and master: `ansible_python_interpreter = /usr/bin/python3` under `[defaults]` | The upstream line is a no-op: `ansible_python_interpreter` is an inventory variable, not an ansible.cfg key, so Ansible ignored it (`ansible-config dump` showed `INTERPRETER_PYTHON` at its default `auto`) and fell back to discovery, printing the "discovered Python interpreter at /usr/bin/python3.10 ... future installation of another Python interpreter could change the meaning of that path" warning for every host. `interpreter_python` is the real key. Verified 2026-09-08: all ten compute nodes resolve `/usr/bin/python3` to python3.10, and an ad-hoc ping of hamilton no longer warns. Flip: restore the old line (and the warning) | 2026-09-08 |
| 1 | `scripts/setup.sh` | venv default `/opt/kosmos-cluster/env` | venv in `./env` (upstream default) | Shared venv on teuwen-ansible, one Ansible for all admins; clones are per admin (decided 2026-09-08, see "Setup decision") | b084b7f1 |
| 1b | `.github/workflows/setup.yml` | activates `/opt/kosmos-cluster/env` | upstream activates `/opt/deepops/env` (master still has the 23.08 workflows) | Follows deviation 1; the CI job failed on every push until the path matched. Flip together with deviation 1 | chunk 6 |
| 2 | `roles/{slurm,nhc,nvidia-dcgm-exporter,nginx-docker-registry-cache,standalone-container-registry,pyxis}/defaults/main.yml` | untouched upstream files | overrides build/config paths to `/opt/kosmos-cluster/...`, `slurm_cluster_name: kosmos`, `standalone_container_registry_name: kosmos-registry`, `slurm_pyxis_version: 0.19.0` | Site values belong in `config/group_vars`, not in vendored roles. All of them are now set in `config/group_vars/{all,slurm-cluster}.yml`, derived from `deepops_dir` | c9d86ffc, chunk 5b |
| 3 | `roles/slurm/templates/etc/slurm/slurm.conf` | `KillWait=120` (upstream 26.07 value) | `KillWait=30` | 30 was the 23.08 default, not a site choice. Upstream raised it in Sept 2024 for more graceful job termination. Behavior change: jobs get 120 s instead of 30 s between SIGTERM and SIGKILL. Flip: set `KillWait=30` in the template | c9d86ffc |
| 4 | `playbooks/slurm-cluster/slurm.yml` | keeps `roles: [facts]` in the first play, in addition to the fact-gathering pre_task | removed the role, keeps only the pre_task | The role installs the custom fact scripts (`topology`, `memory`, `gpus`) that slurm.conf needs. Master relies on other playbooks having installed them. On existing nodes the role is a no-op (scripts unchanged since 23.08). Flip: delete the `roles:` block | 00ae45d2 |
| 5 | `roles/spack.environment`, `playbooks/slurm-cluster/spack-modules.yml`, `roles/spack/defaults/main.yml` | untouched upstream (no spack.environment role, upstream spack-modules.yml, upstream spack pin v1.2.0) | adds a role that installs Spack profile scripts on all hosts plus zsh support, a play for it in spack-modules.yml, and pins spack v0.20.2 with gcc/gfortran deps (EricMarcus-ai and joren, June 2024) | Spack was never rolled out: `/sw` (shared NFS) has no spack directory, no node has `/etc/profile.d/z00_spack.*`, `spack` is not on the path, and `slurm_install_spack` is `false` in config so the play never runs. Confirmed with the admin that nobody uses Spack. Flip: `git checkout master -- roles/spack.environment playbooks/slurm-cluster/spack-modules.yml` and set `spack_version`/`spack_ubuntu_deps` in group_vars (upstream already has gcc/gfortran) | (not applied, chunk 4d) |
| 6 | `config/group_vars/slurm-cluster.yml` | `slurm_cluster_install_singularity: no` | `yes` | Apptainer replaced Singularity on the nodes (chunk 4c) and upstream's singularity playbook is broken in 26.07 (`abims_sbr.singularity` dropped from requirements). Flip: set `yes` (and expect the playbook to fail) | chunk 5b |
| 7 | `config/group_vars/slurm-cluster.yml` | `slurm_version: "23.02.4"` pinned | no pin in config (master pinned it in `roles/slurm/defaults`) | Upstream 26.07 defaults to 26.05.1. Slurm supports upgrading at most two major versions at once, so 23.02 -> 26.05 must be stepped; a Slurm upgrade is a separate project. Flip: remove the pin | chunk 5b |
| 8 | `config/group_vars/slurm-cluster.yml` | `slurm_default_group`, `slurm_organization_name`, `slurm_install_spack` removed | defines them | No role or playbook on either branch reads the first two; the third follows from deviation 5. Flip: re-add the lines | chunk 5b |
| 9 | `config/group_vars/all.yml` | rebuilt from the 26.07 `config.example` with the four site values (DNS, timezone, extra packages, `deepops_dir`) | 23.08 example with the same four values | Master's file was otherwise untouched 23.08 example text; the 26.07 example adds the driver branch and open-kernel-module knobs and updates MAAS/NGC defaults. Flip: `git checkout master -- config/group_vars/all.yml` | chunk 5b |
| 10 | `config/group_vars/all.yml` | `users: []` | example `users:` block defining an `nvidia` sudo user with a published password hash | Nothing in the Slurm flow runs the users role and no node has that user, but a sudo account with a public hash should not sit in site config. Flip: restore the block | chunk 5b |
| 11 | `roles/requirements.yml`, `config/group_vars/all.yml`, `config/host_vars/{alanturing,hamilton,roentgen}` | upstream `nvidia.nvidia_driver v2.3.1`; `nvidia_driver_branch: "580"` in all.yml, `"550"` in host_vars of the three older nodes | `https://github.com/NKI-AI/ansible-role-nvidia-driver` (master), which is upstream v2.3.1 code with only the default branch changed from 515 to 550 | The fork adds nothing but a default. Live drivers (2026-09-04, all Ubuntu `-server` packages, which is what the role installs): 580 on aristarchus, ptolemaeus, galileo, eudoxus, euctemon, herakles; 550 on alanturing, hamilton, roentgen. Per-host pins are the only setting under which a driver run changes no node; master's single 550 would downgrade six nodes. Flip: set one branch in all.yml and delete the host_vars lines | chunk 5b |

| 12 | `playbooks/slurm-cluster/slurm.yml`, `config/group_vars/slurm-cluster.yml` | the "Add SSH public key to root user authorized keys" task runs only when `slurm_add_root_ssh_key` is true (site config: false) | upstream: unconditional (since 2020) | The play puts the running admin's `~/.ssh/id_rsa.pub` into root's `authorized_keys` on every compute node, and fails when that file does not exist. Neither is wanted here: no playbook logs in as root (Ansible connects as the admin over Kerberos and uses sudo), and the play's purpose, getting past pam_slurm_adopt, does not apply because the admin groups are in `/etc/localgroups`. Flip: set the variable to true and provide a key | chunk 7 |
| 13 | `config/group_vars/all.yml` | pins `docker_version: '28.3'` and `docker_containerd_version: '1.6.32'` | no pin (the `docker_version` line is commented out), so whatever kubespray defaults to applies | The nine docker nodes run `docker-ce 5:26.1.2` and `containerd.io 1.6.28-2`, installed when the old kubespray defaulted to 26.1; without a pin the version silently follows every submodule bump. 28.3 / 1.6.32 are the 26.07 (kubespray 2.31) defaults. Chosen 2026-09-08 over pinning the running versions (26.1 and 1.6.28 are both still in kubespray's table) so the cluster sits on a supported release rather than the smallest diff. Consequence: the first real run upgrades docker-ce 26.1.2 -> 28.3.3 and containerd.io 1.6.28-2 -> 1.6.32-1 on nine nodes, restarting docker and the exporter containers, so it must run in a scheduled patch window, not on the live cluster. herakles needs `podman-docker` removed first. Note the docker role reads `docker_containerd_version`, not `containerd_version`. Flip: comment both lines out | (this change) |
| 14 | `config/inventory`, `config/host_vars/*`, `config/group_vars/slurm-cluster.yml`, `roles/slurm/templates/etc/slurm/slurm.conf` | partition membership is an inventory group per partition (`partition_a100` etc.); the template loops over `partition_settings` and takes each partition's nodes from `groups`; the `MaxTime` guard tests the partition value it prints; eight host_vars files that only named a partition are deleted and the dead keys removed from the other six; the unused top-level `slurm_max_job_timelimit` is gone | master: `slurm_partition_name` in every host's host_vars, next to `slurm_def_mem_per_cpu` and (five hosts) `slurm_max_job_timelimit`, which nothing reads; the template builds the partition-to-node map with Jinja dict tricks under `# TODO create this as a fact`; the `MaxTime` guard tested the top-level variable, so deleting that line would have made every partition `MaxTime=INFINITE` | The per-host memory and time-limit values were the first draft of the site config (f81872c5, 2024-06-03), superseded the same day by `partition_settings` (a99cfa0d) and never read since; Slurm has no per-node form of either setting, so they could not have been honoured. Membership as inventory groups shows the whole layout in one file and removes the template TODO. Rendered slurm.conf before and after (2026-09-08, `docs/kosmos/render-slurm-conf.yml`): every `PartitionName` line identical apart from partition order (now the order of `partition_settings`) and node order within a6000 (now alphabetical). Flip: `git checkout master -- config/host_vars roles/slurm/templates/etc/slurm/slurm.conf`, delete the `partition_*` groups and re-add the dead keys | 2026-09-08 |
| 15 | `roles/nvtop`, `playbooks/slurm-cluster/nvtop.yml` | `nvtop_version: "3.3.2"` (role default) checked out as a git tag; the build runs only when `nvtop --version` does not already report that version (the version command has `check_mode: false`, so check runs are accurate); the playbook includes the role only on nodes whose `gpus` custom fact is non-zero | master: clones and builds whatever GitHub HEAD is that day on every run, on every slurm-node including gaia; cmake / make install report "changed" each time | Unpinned HEAD gave different checkouts per node (all 3.1.0-based in 2026-09) and a non-idempotent role. 3.3.2 (2026-02-08) is the newest release; nvtop is a monitoring tool outside the job path, so the version bump is low risk, and Ubuntu 22.04's 1.2.2 is why the role exists. Decided 2026-09-08. Flip: set `nvtop_version` to `3.1.0` in group_vars to stay on the current release, or `git checkout master -- roles/nvtop playbooks/slurm-cluster/nvtop.yml` | 2026-09-08 |
| 16 | `config/group_vars/slurm-cluster.yml`, `roles/slurm/templates/etc/slurm/slurm.conf` | emits `SlurmctldParameters=reconfig_on_restart` when `slurm_version` is 25.11 or newer; the site variable can be overridden to false | upstream omits the parameter | With the shared slurm.conf, a controller restart after a configuration change must also make every slurmd reread the file. Slurm added `reconfig_on_restart` in 25.11. The version guard leaves the current 23.02 configuration unchanged and the override supports disabling it during a rolling upgrade. It is transitional: once every Kosmos daemon is permanently on 26.05 or newer and support for older versions is dropped, set the site variable unconditionally to true and remove the version check. Flip: set `slurm_enable_reconfig_on_restart: false` | (this change) |

### Master changes not carried over (superseded upstream)

These master changes were not carried over because 26.07 already contains the
same fix or removed the code in question.

- `include:` in playbooks and roles. Removed in ansible-core 2.16; 26.07 uses
  `import_playbook` / `include_tasks` everywhere. Master's top-level
  `playbooks/slurm-cluster.yml` still uses `include:` and no longer runs on
  current Ansible.
- RHEL 7 `yum` tasks in the slurm role, old molecule images, older
  `50-exclusive-gpu` epilog: master is simply older than 26.07 here.
- `playbooks/container/docker.yml`: master fixed the kubespray-defaults path
  (`kubespray-defaults/defaults/main/main.yml`); 26.07 ships its own fix for
  the newer kubespray (`kubespray_defaults/...`, underscore). Master's path
  does not exist in the kubespray version the branch carries.
- `playbooks/slurm-cluster.yml`: master commented out the nfs-server line.
  Upstream guards it with `slurm_enable_nfs_server`, which site config sets
  to `false`, so the line is left as upstream has it. Same effect.
- `playbooks/slurm-cluster.yml`: master adds `spack-modules.yml` guarded by
  `slurm_install_spack`. Not added, follows from deviation 5.
- `.gitmodules` / `submodules/`: master removed `packer-maas` and bumped
  kubespray; 26.07 carries its own submodule set (kubespray 2.31).
- `config/nvidia-mig-config.yml`: master deleted the `all-7g.80gb` profile
  from the example. Taken from the 26.07 example as is; `mig_manager_profile`
  is `all-disabled` so no profile is applied.
- Deleted upstream directories (k8s, DGX, PXE, virtual, ~8000 lines) are not
  deleted on this branch. Keeping the tree identical to the tag makes future
  upgrades a clean rebase.

### Behavior differences vs the running cluster

Changes the upgrade brings that we accept rather than pin back. Also listed
in the table above where a flip is possible.

- `KillWait` 30 -> 120 (see deviation 3).
- `nvidia-dcgm-exporter` container image: `2.1.8-2.4.0-rc.2-ubuntu20.04` ->
  `4.5.3-4.8.2-distroless` (role default; monitoring is enabled).
- `standalone-container-registry` image `registry:2.8` -> `3.1.1` and
  nginx cache proxy `0.6.4` -> `0.6.5`: both features are off in site config.
- Galaxy roles/collections move to the 26.07 pins (`ansible.posix`,
  `community.general`, `community.docker`, `devsec.hardening` replaces the
  old `dev-sec` roles). Run `ansible-galaxy install -r roles/requirements.yml`
  in your clone before the first run (README setup block).

## 2. Things to address after the port

Found while porting, deliberately left as on master. Not fixed because the
port should not change how things are done without consulting the other
admins.

Every item below was re-checked on 2026-09-08 against the branch and all
ten compute nodes (two independent passes). Items that turned out not to be
issues were removed; corrections are marked "corrected 2026-09-08".

**By priority:**

- **Blocking a real run of `slurm.yml`: the munge key.** env-26.07 hashes
  `slurm_password` differently from the old env, so any real run rewrites
  the munge key on the hosts it touches and cuts them off from the rest
  (see "Check-run results", 2026-09-08). Resolved by the vault rollout on
  the maintenance day, below. Check runs are unaffected. (Earlier blocker,
  admin login to kosmos, was restored by IT on 2026-09-08; step 6 of
  "Before the first run" is done.)
- **Ansible node access, not blocking:** atlas has no Kerberos host
  principal, so any `slurm.yml` run that includes atlas still needs `-k`.
  Join it to the realm
  (see "Running playbooks from teuwen-ansible").

### Maintenance day 2026-10-05

Decided 2026-09-08: no playbook run or hand edit that changes live node
configuration before the maintenance day, on which the branch goes live
and Slurm is upgraded. Everything below waits for that day; until then only
`--check --diff` runs and branch/doc work. Order matters.

1. **Fix `/etc/default/grub` on all ten compute nodes so the Slurm role
   finds its line and stops rebooting nodes.** Today each node has
   `GRUB_CMDLINE_LINUX="pci=realloc=off cgroup_enable=memory swapaccount=1"`
   twice (hand-written, expanded form). Replace both lines with
   ```
   GRUB_CMDLINE_LINUX="pci=realloc=off"
   GRUB_CMDLINE_LINUX="${GRUB_CMDLINE_LINUX} cgroup_enable=memory swapaccount=1"
   ```
   (second line verbatim: it is the `lineinfile` string in
   `roles/slurm/tasks/compute.yml`), then `update-grub`. The effective
   kernel command line is unchanged, so no reboot is needed for this step
   itself; the nodes reboot anyway that day. Before editing, confirm the
   exact current lines on every node (`grep GRUB_CMDLINE_LINUX
   /etc/default/grub`; only the cgroup option count was checked so far)
   and that `/proc/cmdline` shows the same options. Verify afterwards with
   `ansible-playbook -kK --check --diff --limit slurm-node
   playbooks/slurm-cluster/slurm.yml`: the "add cgroups to grub options"
   task must report ok on every node. Plan: a one-off play in
   `docs/kosmos/` (replace the two lines, `update-grub`, show the grub.cfg
   diff), run in check mode first. Alternative rejected: a site variable
   that skips the grub tasks would also skip them on future new nodes.
2. **Vault password and munge key rollout** per
   `docs/kosmos/slurm-secrets-vault.md`: all twelve hosts in one
   `slurm.yml` run from env-26.07, check run first, then `sinfo` and a
   munge round trip from atlas. This is the first real run of `slurm.yml`
   from the branch; expect the changes listed under "Check-run results",
   2026-09-08 (herakles first-run items, kosmos dev packages, slurmctld,
   slurmdbd and slurmd restarts).
3. **Slurm upgrade** (23.02 -> stepped; branch `slurm-upgrade-26.04` on
   origin), after the branch is live.
4. Other items that touch live nodes and are waiting for this day:
   herakles driver metapackages and reboot (Check-run results,
   2026-09-04); podman-docker vs docker-ce on herakles and the docker
   upgrade on gaia and eudoxus (5b); apptainer pin and version drift (4c);
   nofile limit on gaia (facts gathering); the first real run of
   `nvtop.yml`, which rebuilds nvtop 3.3.2 on the nine GPU nodes
   (deviation 15); the first full run of `playbooks/slurm-cluster.yml`.
- **Ansible node access, not blocking:** atlas has no Kerberos host
  principal, so any `slurm.yml` run that includes atlas still needs `-k`.
  Join it to the realm
  (see "Running playbooks from teuwen-ansible").
- **Decide before the first full run of `playbooks/slurm-cluster.yml`:**
  the monitoring section installs docker-ce on every host, which fails on
  herakles (podman-docker) and upgrades docker on gaia and eudoxus (5b);
  the inline `hostlist=` on three `import_playbook` lines is ignored, so
  NHC and DCGM also targeted atlas and kosmos (4e, fixed); the apptainer role fails
  on gaia and aristarchus, which run newer versions than the pin (4c).
- **Should be fixed soon:** Slurm passwords are the upstream placeholders (5b);
  (Fixed on this branch: the dead per-host overrides in host_vars, 5a,
  deviation 14; the unpinned nvtop build, 4b, deviation 15; fact
  gathering from `groups['all']`, see Facts gathering.)
- **Cleanup when convenient:** everything else below.

### Slurm role (commit c9d86ffc)

- Fixed 2026-09-08 (deviation 14): the `# TODO create this as a fact` block
  (joren, 2024-06-04) that built the partition-to-nodes map with Jinja dict
  tricks is gone; the template reads the `partition_<name>` inventory groups.
- `roles/slurm/templates/etc/localgroups` (admin groups `sudo`,
  `teuwen-sudoers`) and `prolog.d/50-create-scratch` (`/processing` path)
  hardcode site values inside the role, as on master. Candidates for
  variables in `config/group_vars`.

### Facts gathering (commit 00ae45d2)

- `playbooks/slurm-cluster/slurm.yml` used to start with `hosts: all` and a
  pre_task that `setup`s every member of `groups['all']` when
  `ansible_default_ipv4` was missing (so `--limit` still SSHes to atlas and
  kosmos, and a bare `setup:` still ran the mount collector on gaia).
  **Fixed:** first play is `hosts: slurm-node` with implicit `min` gather
  and `roles: [facts]`. Before rendering slurm.conf, the play that owns the
  template then runs `setup`/`local` over `groups['slurm-node']`
  (`roles/facts/tasks/gather-slurm-nodes.yml`) because the template walks
  every compute node. With `slurm_conf_symlink: true`, that is the controller
  play: only the controller renders the shared file, while login and compute
  nodes link to it. Without the shared file, the configure play gathers the
  facts before misc nodes render their local copy. The gather is tagged
  `config`, including the dynamically included task, so it also runs with
  `--tags config`. A `--limit gaia` run in symlink mode neither gathers the
  whole cluster nor renders slurm.conf. Login is not a facts target.
  `docs/kosmos/render-slurm-conf.yml` stays a helper and is not part of
  deploy.
- Implicit gather `min` is `ansible_gather_subset` in
  `config/group_vars/slurm-cluster.yml`. Site facts stay in `ansible_local`
  via `roles/facts` (always refresh on the slurm.conf path, not the 24 h
  cache). Hardware/network only if a play needs them. NHC `nhc.conf.j2`
  uses `ansible_local.memory` and no longer loops `ansible_interfaces`.
  `create_mounts.yml` still does its own explicit `min` `setup`; optional
  cleanup later.

### NFS mounts (chunk 4a)

- `roles/create-mounts/tasks/main.yml` hardcodes the kronos and rhea export
  list and mount options inside the role. Upstream's `nfs` role takes the same
  information from `nfs_mounts` in `config/group_vars`; moving it there would
  keep site data out of role code. If that happens, `nfs-client.yml`
  (currently off, `slurm_enable_nfs_client_nodes: false`) replaces both this
  role and `playbooks/generic/nfs-general.yml`, which today is the only thing
  that installs `nfs-common`. Until then both stay.
- `playbooks/slurm-cluster/create_mounts.yml` lists an `outside` group that
  is commented out in `config/inventory`. Harmless: Ansible warns "Could not
  match supplied host pattern, ignoring: outside" and the play still runs on
  slurm-master, slurm-login and slurm-node (corrected 2026-09-08; an earlier
  note claimed the play was skipped). Drop the word to silence the warning.
- `playbooks/slurm-cluster/mount_scratch_disks.yml` runs `exportfs -a` and
  `mount -a` unconditionally on every run (always reports "changed").

### nvtop and motd (chunk 4b)

- **Fixed 2026-09-08 (deviation 15).** `roles/nvtop` cloned the Syllo/nvtop
  GitHub repository with `update: yes` and built whatever HEAD was that
  day; nodes ended up on different checkouts (gaia `3.1.0-100-gf901275`,
  all others `3.1.0-9-g0316ce1`, all reporting 3.1.0) and the cmake / make
  install tasks reported "changed" on every run. Now: `nvtop_version`
  (role default `3.3.2`, the newest release, 2026-02-08; builds with the
  nodes' cmake 3.22) is checked out as a tag, and the whole build is
  skipped when `nvtop --version` already reports that version, so the role
  is idempotent and check mode shows the truth. Reason the role exists:
  Ubuntu 22.04's packaged nvtop is 1.2.2, too old for current GPUs. The
  first real run of `nvtop.yml` rebuilds nvtop on the nine GPU nodes
  (maintenance day).
- Fixed 2026-09-08 (deviation 15): `playbooks/slurm-cluster/nvtop.yml`
  set a `has_gpus` fact that nothing read, so nvtop was also built on
  gaia. The role is now included only when the fact is set; gaia keeps
  the 3.1.0 binary it has and is otherwise left alone.
- `roles/motd/templates/50-landscape-sysinfo.yml.j2` is a verbatim copy of
  Ubuntu's old, pre-caching `50-landscape-sysinfo` script with no site
  content. On all ten nodes that path is now a symlink to
  `/usr/share/landscape/landscape-sysinfo.wrapper`, the newer caching
  version (LP #1893716). The role replaced the symlink with the older
  script on every run. **Fixed 2026-09-08:** the sysinfo task and template
  are gone, the role only installs the header. The "disable current motd"
  task chmods regular files only, so the symlink keeps working; on a node
  where the file is still a regular file (pre-2026 landscape-common) it
  gets disabled until the package updates.

### Apptainer (chunk 4c)

Ported as on master because nothing in 26.07 has the same name, but this
area has several leftovers that need a decision (update or remove).

- **Version drift, and the role fails on the drifted nodes.**
  `roles/apptainer/defaults/main.yml` pins 1.3.3, and eight of ten nodes
  run exactly that. gaia runs 1.4.0 and aristarchus 1.5.3 (the current
  upstream release), both from a .deb installed by hand or with a
  different pin. The role installs with `apt: deb:` without
  `allow_downgrade`, so on those two nodes the task fails with "A later
  version is already installed" instead of downgrading (corrected
  2026-09-08). Decide the pin (1.5.3 is the obvious choice), and move it to
  `config/group_vars` rather than the role's defaults.
- **Two container runtimes on the nodes.** Besides apptainer, every node
  (not only gaia) still has Singularity 3.7.1 in
  `/usr/local/bin/singularity` (config under `/usr/local/etc/singularity`)
  and Go 1.20.6 under `/opt/go`, both left by DeepOps' `singularity_wrapper`
  role before apptainer arrived. Apptainer ships its own `singularity`
  alias, so the old binary is shadowed only if `/usr/bin` wins in `PATH`.
  Candidate for removal once nobody depends on it.
- **Not wired into the top-level playbook.** `playbooks/container/apptainer.yml`
  is run by hand, on master and here. Adding it to `playbooks/slurm-cluster.yml`
  behind a variable would make apptainer part of a normal node build.
  (Singularity install is off since deviation 6; upstream's singularity
  playbook is broken in 26.07 anyway.)

### Spack and modules (chunk 4d, not ported)

- Fixed 2026-09-08 (8cd3fc20): the motd header no longer tells users to
  load modules with 'spack'; Spack is not installed anywhere.
- Lmod on the nodes is version 6.6 (2016), which is simply Ubuntu 22.04's
  `lmod` package. The upstream `lmod` role installs that same package on
  Debian-family hosts, so the first run changes nothing here (checked
  2026-09-08). A newer Lmod would need another source. herakles has no
  Lmod at all (see 5b).
- If Spack is rolled out later: upstream 26.07 pins v1.2.0 and installs the
  profile scripts only on the host that clones Spack (`slurm-master[0]`),
  while the install lives on shared NFS. Master's all-hosts play and zsh
  template (see deviation 5) would still be needed.

### Ansible node (found while building env-26.07)

- Fixed 2026-09-08 (deviation 0d): `ansible.cfg` pointed the fact cache at
  `/var/tmp/ansible_cache`, which on teuwen-ansible is `root:teu-ansible`
  mode 0700, so every admin got "error in 'jsonfile' cache ... disabling
  plugin" and facts were gathered on every run. Now `~/.ansible/fact_cache`,
  per user; verified with a local `setup` run that the directory is created
  and the warning is gone.

### Fact gathering fails on nodes with many NFS submounts (found 2026-09-04)

- On gaia, `Gathering Facts` fails with `[Errno 24] Too many open files`
  from `udevadm info ... rhea:/project-pool/network_homes/<user>`, and the
  play stops for that host. Cause: Ansible's mount-facts collector runs one
  `udevadm` per mount entry in a thread pool of `min(mounts, cpu_count)`
  threads. gaia has 256 CPUs and 300+ mounts (273 NFSv4 submounts under
  `/projects`, one per project dataset touched, plus one per user home:
  rhea exports with crossmnt), and the ssh session's soft `nofile` limit is
  1024. The other nodes have ~50 mounts and are fine. The count fluctuates
  with user activity (submounts expire after `nfs_mountpoint_timeout`, 500 s,
  when unused), which is why the same step can pass at one moment and fail
  ten minutes later. **Not an upgrade regression:** ansible-core 2.16 in the
  old env fails identically. slurm.conf uses only the custom facts
  (`ansible_local`). NHC `check_hw_physmem` now uses
  `ansible_local.memory.total_mb` (already 95% of MemTotal; the template
  divides by 0.95 so the ±5% window is the same as before) and the
  commented `check_hw_eth` loop is gone.
- Fix options: (a) `ansible_gather_subset: [min]` on `slurm-cluster` so
  implicit gather never runs the mount collector (see Facts gathering);
  **done** in group_vars. (b) raise the soft `nofile` limit for login
  sessions, e.g. `/etc/security/limits.d/90-nofile.conf` with
  `* soft nofile 65536` (hard limit is already 1048576; new ssh sessions
  only, so let Ansible's 5-minute control sockets expire first). (b) is
  still needed for unfiltered `setup` and ad-hoc `-m setup`. Nothing in
  the repo manages limits today.
- With (a) in place, `--check` on gaia should get past fact gathering for
  playbooks that only implicit-gather. `slurm.yml` no longer uses a bare
  `setup:` over `groups['all']`; its slurm.conf path gathers `local` only.
  A failure that still mentions `udevadm` / `Errno 24` is an explicit
  `setup` without `min`/`local` (or a stale full fact cache); `--flush-cache`
  once if the cache predates the subset.

### Top-level playbook wiring (chunk 4e)

- **Inline `hostlist=` on `import_playbook` is ignored (found
  2026-09-08).** `playbooks/slurm-cluster.yml` has three lines of the form
  `import_playbook: x.yml hostlist=slurm-node` (container registry, line 31;
  `nvidia-dcgm.yml`, line 78; `nhc.yml`, line 82). ansible-core 2.17 keeps
  only the file name and drops the rest, so those playbooks fall back to
  their `hosts: all` default: `--list-hosts` shows the NHC and DCGM plays on
  all twelve hosts, including atlas and kosmos. (DCGM is still off on atlas
  through its host_vars; NHC is not.) The registry playbook is gated off by
  `slurm_enable_container_registry: false`. Same lines in upstream 26.07,
  so an upstream bug. The `vars: hostlist:` form used elsewhere in the file
  works. Never showed in testing because every check run used
  `--limit slurm-node`. **Fixed 2026-09-08:** the three lines use the
  `vars:` form; `--list-hosts` now shows NHC and DCGM on slurm-node and the
  registry on slurm-master.
- `bootstrap-ssh.yml` and `bootstrap-sudo.yml` are disabled by commenting
  them out in `playbooks/slurm-cluster.yml`, as on master (joren,
  2024-06-05). Decided 2026-09-04: keep both disabled. ssh to the compute
  nodes works through Kerberos and sudo stays password-protected (`-K`),
  which is sensible for a shared cluster.
- `playbooks/slurm-cluster/mount_scratch_disks.yml` and
  `playbooks/container/apptainer.yml` are not in the top-level playbook on
  master either; they only run when someone runs them by hand.

### Inventory and host_vars (chunk 5a)

- **Fixed on this branch, still open on master: no default partition after
  the phase-out.** `partition_settings` marked `rtx2080ti_sm` as the default
  partition, but since e812a659 (2026-09-03) no active node in the
  inventory belongs to it (plato, schrodinger, carlos are commented out).
  The slurm.conf template only emits partitions that have nodes, so the next
  render on master produces a slurm.conf with no `Default=YES` partition and
  jobs submitted without `-p` are rejected. The live config on gaia still has
  the old layout with `rtx2080ti_sm` as default. This branch moves
  `default: true` to `rtx2080ti` (alanturing, hamilton), the closest match to
  the old default: the smallest GPU partition, so a forgotten `-p` lands
  somewhere cheap. Tell users, and update any documentation that names the
  default partition, before the first real Slurm run.
- **Fixed 2026-09-08 (deviation 14), still present on master:**
  `slurm_def_mem_per_cpu` and `slurm_max_job_timelimit` in
  `config/host_vars/*` were dead: the slurm.conf template reads both only
  from `partition_settings[<partition>]`, and Slurm has no per-node form of
  either (galileo's 3800 could never differ from the 7000 of its a6000
  partition mates). They were the first draft of the site config
  (f81872c5), superseded the same day by `partition_settings`. The comment
  above `partition_settings` ("individual nodes can overwrite settings in
  host_vars") was wrong for the same reason. On this branch the keys are
  gone, partition membership is an inventory group per partition, and the
  README describes how to add or remove a node.
- `config/host_vars/{carlos,plato,schrodinger}` (now only their
  `gpu_topology` overrides) and the commented hosts in the
  `partition_rtx2080ti_sm` and `partition_p6000` inventory groups describe
  phased-out nodes; remove once the nodes are gone for good.

### Site config (chunk 5b)

- **Nodes are not uniform: each one reflects the playbooks that were run by
  hand when it was last (re)provisioned.** Master's top-level
  `playbooks/slurm-cluster.yml` has not run on current Ansible for years
  (`include:` syntax), so admins ran individual playbooks, and skipped
  different ones on different nodes. Verified on the nodes 2026-09-04:
  - **herakles** was provisioned with the master roles on 2024-07-06/07
    (commit 5dce9a27): custom facts, Slurm built under
    `/opt/kosmos-cluster/build`, site prolog/epilog scripts, enroot,
    apptainer 1.3.3 (the role's pin), nvtop, motd, rsyslog forwarding, the
    fstab mount block, slurm.conf symlink. Never run against it: `nhc.yml`
    and `nvidia-dcgm.yml`, so it has no NHC and no DCGM although site config
    enables both. Consequence today: the shared slurm.conf sets
    `HealthCheckProgram=/usr/sbin/nhc`, which does not exist on herakles, so
    it is the only compute node whose health checks cannot run. A full run of
    the new branch would install both, which is the intended state. It also
    has no `lmod` package (`lmod.yml` never ran) and no docker-ce: it is the
    only node without it. Instead `podman-docker` (installed by hand
    2025-08-07) owns `/usr/bin/docker`. See the docker item below for why
    that matters.
  - **eudoxus** (provisioned 2024-08): node exporter and dcgm exporter both
    active as of 2026-09-08 (an earlier note found the node exporter
    inactive; that is stale). **aristarchus**: node exporter unit `failed`,
    dcgm exporter inactive. All other GPU nodes run both; gaia (CPU-only)
    runs the node exporter.
  - **docker-ce comes with the monitoring section, on every host (corrected
    2026-09-08).** `prometheus-node-exporter.yml` and
    `nvidia-dcgm-exporter.yml` each import `container/docker.yml`, whose
    hosts default to `all`; the top-level playbook imports both without a
    hostlist, gated only by `slurm_enable_monitoring: true`, and
    `docker_install: yes` is set in `config/group_vars/all.yml`. So a full
    run of `playbooks/slurm-cluster.yml` installs docker-ce on all twelve
    hosts, including atlas and kosmos. Same wiring on master. That is how
    nine of ten nodes got docker-ce (the earlier note blamed hand runs).
    Consequences: on herakles the install fails, because docker-ce-cli
    neither conflicts with nor replaces podman-docker and dpkg refuses to
    overwrite `/usr/bin/docker`; on gaia and eudoxus (held at 26.1.2)
    kubespray's pin upgrades docker to 28.3. **Decided 2026-09-08:** keep
    docker and the monitoring stack (Grafana dashboards are wanted later),
    and pin the version (deviation 13). **The config change is prepared, the
    run is not:** applying it restarts dockerd and with it the node and dcgm
    exporter containers on nine live nodes, so it belongs in a scheduled
    patch window, not on a running cluster. Still open: herakles must lose
    `podman-docker` before it can run the same docker-ce as the other nine,
    which is what "uniform across the nodes" requires. Until that is done,
    limit the exporter playbooks with `--limit 'slurm-node:!herakles'`, or
    skip the docker import with `-e '{"docker_install": false}'` -- note the
    JSON form: `-e docker_install=false` passes the *string* "false", which
    the playbook's `when: docker_install | default('yes')` treats as true.
  - The first `--check --diff` run of the new branch against all nodes will
    list these gaps per node; that output is the to-do list for bringing the
    nodes back in line.
- `slurm_password` / `slurm_db_password` are still the upstream placeholder
  strings, on master and here. They should live in an Ansible vault. **NOTE**:
  this is addressed in `docs/kosmos/slurm-secrets-vaults.md`. Passwords
  should be stored in a vault which all admins have access to.
- Decisions, not defects: NHC runs with the role's default `nhc.conf`
  template (the example recommends a site `nhc_config_template`).
- **Correction (2026-09-08): the monitoring server side is not inert.** An
  earlier note said the empty `[slurm-metric]` group means no Prometheus,
  Grafana or Alertmanager get deployed. That group is never consulted: the
  top-level playbook passes
  `hostlist: "{{ slurm_monitoring_group | default('slurm-metric') }}"` and
  site config sets `slurm_monitoring_group: "slurm-master"`, so a full run
  installs Prometheus, Grafana, Alertmanager and the slurm exporter on
  atlas, as docker containers. Whether they run there today is still
  unverified -- atlas has no Kerberos host principal, so the check needs `-k`:
  `ansible atlas -k -o -m shell -a 'systemctl is-active docker.prometheus.service docker.grafana.service'`.
  This matters because the node and dcgm exporters only have value if a
  Prometheus is scraping them.
