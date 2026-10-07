# `slurm_password` and `slurm_db_password`

Status: in place on teuwen-ansible since 2026-09-30; used from the first run
on the reinstalled cluster (deviation 30 in `porting-notes.md`). Replaces the
Ansible-vault proposal of 2026-09-08 (in git history under
`docs/kosmos/slurm-secrets-vault.md`).

## What the two values do

They are not user passwords. Know this before changing them.

- `slurm_password` is the seed for the munge key. The Slurm role hashes it
  with the cluster name as salt (`password_hash('sha512', 'kosmos')`,
  `roles/slurm/templates/etc/munge/munge.key.j2`) and writes the result to
  `/etc/munge/munge.key` on every Slurm host. A new value means a new munge
  key, and hosts with different keys cannot talk to each other.
- `slurm_db_password` is the MariaDB password of the slurmdbd account. The
  controller task sets it in the database and writes it into `slurmdbd.conf`
  (`StoragePass`).

Until the reinstall both were the upstream placeholder strings, in plain
text in git, so anyone with the DeepOps repository could compute the munge
key. Role defaults still contain those placeholders; site group_vars
overrides them.

## Where they are

- `/opt/kosmos-cluster/.slurm-secrets.yaml` on teuwen-ansible, owner
  `root`, group `teuwen-sudoers`, mode 0640 (`lookup('file')` runs as the
  admin running the playbook). Do not copy it onto cluster nodes or into a
  clone.

  ```yaml
  ---
  slurm_password: '<secret>'
  slurm_db_password: '<secret>'
  grafana_admin_password: '<secret>'   # monitoring.yml only (deviation 45)
  ```

- `/etc/profile.d/kosmos-slurm-secrets.sh` (0644, holds only the path):

  ```bash
  export KOSMOS_SLURM_SECRETS_FILE=/opt/kosmos-cluster/.slurm-secrets.yaml
  ```

- `config/group_vars/slurm-cluster.yml` reads the file through that variable
  (`kosmos_slurm_secrets_file`, then `lookup('file', ...) | from_yaml`). The
  lookup runs on the Ansible node, only when a task uses one of the values.
  An unset variable stops the run with "KOSMOS_SLURM_SECRETS_FILE is not
  set"; an unreadable file or a missing key also stops it. Nothing falls
  back to a placeholder.

Check from a clone, without printing the values:

```bash
source /opt/kosmos-cluster/env-26.07/bin/activate
echo "$KOSMOS_SLURM_SECRETS_FILE"
ansible atlas -m debug -a "msg={{ (slurm_password | length > 0) and (slurm_db_password | length > 0) }}"
```

`true` means both are set. `debug` runs on the Ansible node and changes
nothing on atlas.

## Rules

- Run every playbook that touches Slurm from teuwen-ansible, in a login
  shell (new terminal after the file was set up).
- Changing `slurm_password` changes the munge key: run `slurm.yml` against
  every Slurm host in one go (no `--limit`), then check
  `munge -n | ssh <node> unmunge` from atlas for every node.
- Changing `slurm_db_password` needs a run that includes atlas; it resets
  the MariaDB user and restarts slurmdbd.
- The Slurm role's password hash depends on the Ansible/passlib version
  (porting-notes, check-run results 2026-09-08): hosts must be deployed from
  the same environment (env-26.07), or their munge keys differ.
- Do not run `slurm.yml` for real against the 22.04 cluster (`--check`
  is fine): the first real use is
  the reinstall, where every host gets the new key on its first run.
