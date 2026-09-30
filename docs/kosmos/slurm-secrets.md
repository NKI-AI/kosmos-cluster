# Slurm munge / slurmdbd seeds (not in git)

Site `config/group_vars/slurm-cluster.yml` reads `KOSMOS_SLURM_SECRETS_FILE`
(control node), parses YAML, and sets `slurm_password` and
`slurm_db_password`. Unset env, unreadable file, or missing key → play
fails. Role defaults still have the DeepOps placeholders; they are not
used when this lookup succeeds.

`slurm_password` is templated to `/etc/munge/munge.key` as
`password_hash('sha512', slurm_cluster_name)` (`kosmos`). Every
`slurm-cluster` host must get the same key in one `slurm.yml` run from
`env-26.07`. `slurm_db_password` is the MariaDB user and
`StoragePass` in `slurmdbd.conf` on the controller.

## On teuwen-ansible

File: `/opt/kosmos-cluster/.slurm-secrets.yaml`  
Mode `0640`, owner `root`, group `teuwen-sudoers` (`lookup('file')` runs
as the playbook user). Do not copy it onto cluster nodes or into a clone.

```yaml
---
slurm_password: '…'
slurm_db_password: '…'
```

```bash
# /etc/profile.d/kosmos-slurm-secrets.sh  (0644; path only)
export KOSMOS_SLURM_SECRETS_FILE=/opt/kosmos-cluster/.slurm-secrets.yaml
```

Login shells pick that up. Then, from a clone with current `group_vars`:

```bash
source /opt/kosmos-cluster/env-26.07/bin/activate
echo "$KOSMOS_SLURM_SECRETS_FILE"
ansible -i config/inventory atlas -m debug -a 'var=slurm_password'
```

Playbooks stay `ansible-playbook -K …`. Debug only prints the variable; it
does not rewrite munge or MariaDB.

Do not apply `slurm.yml` on the current 22.04 cluster. First real use is
the reinstall of all `slurm-cluster` hosts (new seeds in the YAML, then
apply).
