# Moving `slurm_password` and `slurm_db_password` into an Ansible vault

Status: proposal, 2026-09-08. Nothing below has been applied to the cluster yet.

## Why

`config/group_vars/slurm-cluster.yml` still carries the upstream placeholder
strings for both secrets, in plain text, in git:

```yaml
slurm_password: ReplaceWithASecurePasswordInTheVault
slurm_db_password: AlsoReplaceWithASecurePasswordInTheVault
```

The same values are on `master`, so the live cluster runs on them today.

## What the two values do

They are not user passwords. Know this before changing them.

- `slurm_password` is the seed for the munge key. The Slurm role hashes it
  with the cluster name as salt (`roles/slurm/templates/etc/munge/munge.key.j2`)
  and writes the result to `/etc/munge/munge.key` on every node. A new value
  means a new munge key.
- `slurm_db_password` is the MariaDB password of the slurmdbd account. The
  controller task sets it in the database and writes it into
  `slurmdbd.conf`.

## Step 1: set up the vault (safe, no cluster change)

Done once on the Ansible node (teuwen-ansible).

1. Create a vault password file outside git:

   ```bash
   openssl rand -base64 32 > config/.vault-pass
   chmod 600 config/.vault-pass
   echo '/config/.vault-pass' >> .gitignore
   ```

2. Uncomment the line in `ansible.cfg` so every run finds it:

   ```
   vault_password_file = ./config/.vault-pass
   ```

   Without it, add `--ask-vault-pass` to every `ansible-playbook` call, next
   to the usual `-kK`.

3. Every admin who runs playbooks needs a copy of `config/.vault-pass`. Hand it
   over out of band. It must never be committed.

## Step 2: encrypt the values

```bash
source /opt/kosmos-cluster/env/bin/activate
ansible-vault encrypt_string "$(openssl rand -base64 24)" --name slurm_password
ansible-vault encrypt_string "$(openssl rand -base64 24)" --name slurm_db_password
```

Each command prints a block like this. Paste it into
`config/group_vars/slurm-cluster.yml` in place of the plaintext line:

```yaml
slurm_password: !vault |
          $ANSIBLE_VAULT;1.1;AES256
          6338...
```

Inline encrypted strings keep the rest of the file readable and diffable.
Committing the encrypted blocks is fine, that is the point of the vault.

Check that decryption works before touching any node. The `debug` module runs
on the Ansible node and does not connect to atlas, but the host must be in the
`slurm-cluster` group for the group_vars to apply:

```bash
ansible -i config/inventory atlas -m debug -a 'var=slurm_db_password'
```

### Option: encrypt first, rotate later

To get the secrets out of plain text without changing anything on the nodes,
encrypt the existing placeholder strings instead of new random ones. That can
be done any day. The rotation below then becomes a separate, scheduled step.

## Step 3: rotating the secrets on the cluster (needs a window)

This is the risky part, not the encryption.

**Munge key.** A new `slurm_password` gives every node a new munge key. All
nodes, including atlas, kosmos and herakles, must receive it in the same run.
A node left on the old key cannot authenticate to the controller: it shows as
`down` in `sinfo` and jobs cannot launch there.

- Pick a quiet window and drain or at least warn users.
- Run `playbooks/slurm-cluster/slurm.yml` against the whole cluster, not with
  `--limit`.
- Do a `--check --diff` run first. It will show the munge key change on every
  node, which confirms the scope.
- Afterwards check `sinfo` and `munge -n | ssh <node> unmunge` from atlas.

**Database password.** The controller run changes the MariaDB account and
`slurmdbd.conf` in the same play and restarts slurmdbd. Accounting pauses for a
few seconds, that is all.

## Things to keep in mind

- herakles has never had the new branch run against it and lacks NHC and DCGM
  (see `docs/kosmos/porting-notes.md`). It still needs the munge key rollout;
  a full run there also installs those, which is the intended state.
- Anyone running playbooks from a clone without `config/.vault-pass` gets an
  error at startup, not a silent fallback to the placeholder, which is what we
  want.
- `config/group_vars/all.yml` also carries the upstream MAAS admin password
  (`maas_adminusers`, `admin`/`admin`). MAAS is not used on kosmos, so it is
  harmless, but the same method applies if that ever changes.
