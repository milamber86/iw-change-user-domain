# IceWarp account domain change

Ansible playbook that moves IceWarp accounts from one domain to another on a remote Linux IceWarp server.

This operation is **officially unsupported**. Take filesystem and MySQL backups before running, and test on a non-production copy first.

The playbook creates the destination domain if it does not exist. It supports IceWarp account types 0–8 (user, mailing list, executable, notification, static route, catalog, list server, group, resource). It does **not** rewrite group membership lists.

Database names and mailbox/archive/config paths are discovered from `tool.sh` and `_webmail/server.xml` unless you set them in inventory or extra-vars.

## What it does

1. Discover DB names and paths (or use overrides). Check MySQL connectivity.
2. Create the destination domain if missing; create dest mail/archive/config directories as `icewarp:icewarp`.
3. Resolve the account list (`iw_users` / `iw_user`, or export `*@source` for the whole domain).
4. Disable login on all selected accounts, then restart IceWarp.
5. For each account:
   - Verify the source exists and the destination account does not.
   - Move maildir and `config/<domain>/<alias>.txt` when those paths exist; skip types with no mailbox data.
   - Move archive when present and the dest archive path does not exist.
   - Update accounts (including config-style `U_Mailbox` / `U_ForwardOlderTo`, and alias rename).
   - Update groupware, ActiveSync (`devices.user_id`), directory cache, and webclient.
   - Rewrite `u_mailboxpath` (not for executables), `~webmail/settings.xml`, refresh directory cache, queue full-text reindex, and re-enable login.
6. Restart IceWarp again.

A timestamped log of each action and its result is written on the IceWarp host (default `/root/iw-change-user-domain-<timestamp>.log`). Ansible prints that path when the play finishes.

## Requirements

- Ansible 2.14+ on the control node
- SSH as root (or equivalent) to the IceWarp host
- `/opt/icewarp/tool.sh` and `/opt/icewarp/icewarpd.sh` on the host
- `mysql` client on the host, with passwordless access via `~/.my.cnf`

## Setup

From the repository root:

```bash
cp inventory/hosts.example.yml inventory/hosts.yml
cp inventory/group_vars/all.example.yml inventory/group_vars/all.yml
```

Required variables:

| Variable | Meaning |
| --- | --- |
| `iw_source_domain` / `iw_dest_domain` | IceWarp domains |

Optional: `iw_users` (local-parts, `user@source`, or `old@source,new@dest`). If unset, every account in the source domain is moved.

Optional overrides: mailbox/archive/config paths and `iw_accounts_db`, `iw_groupware_db`, `iw_directorycache_db`, `iw_eas_db`, `iw_webclient_db`. See [inventory/group_vars/all.example.yml](inventory/group_vars/all.example.yml).

A non-empty custom `u_autoarchivepath` that does not match the source archive path fails the play.

## Usage

Run from the repository root.

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml
```

Single account:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml -e iw_user=example.user
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml -e iw_user=example.user@olddomain.loc
```

Alias rename:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml \
  -e iw_user=old.alias@olddomain.loc -e iw_dest_email=new.alias@newdomain.loc
```

Preflight only (no moves, SQL, domain create, or restarts):

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml --check
```

Leave login disabled after the move:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml -e iw_enable_login_after=false
```

## Safety

- Do not re-run an account that already moved: preflight fails (source gone, destination exists).
- Destination maildir and config targets must not exist; the playbook will not overwrite them.
- The list stops on the first account failure. If anything was already mutated, IceWarp is still restarted.
- Custom `u_autoarchivepath` values are not supported.
- Group member lists are not rewritten.
