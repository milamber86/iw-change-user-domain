# IceWarp user domain change

Ansible playbook that moves IceWarp **user** accounts from one domain to another on a remote Linux IceWarp server.

This operation is **officially unsupported**. IceWarp does not provide a supported way to change an account's domain. Take filesystem and MySQL backups before running, and test on a non-production copy first.

The playbook does **not** create the destination domain. Local-part is unchanged (`example.user@olddomain.loc` → `example.user@newdomain.loc`). IceWarp **groups** are out of scope.

## What it does

For each user:

1. Verify the source account exists, the destination domain exists, and the destination account does not exist (`tool.sh`).
2. Disable login (`u_accountdisabled 2`).
3. Move the maildir. Skip-move the archive directory when it is absent.
4. Update the accounts, groupware, directory cache, and webclient databases.
5. Rewrite `u_mailboxpath`, `~webmail/settings.xml`, and trigger a directory-cache refresh.

IceWarp services are restarted once at the end (`icewarpd.sh --restart all`). Login stays disabled unless `iw_enable_login_after` is true.

## Requirements

- Ansible 2.14+ on the control node
- SSH as root (or equivalent) to the IceWarp host
- `/opt/icewarp/tool.sh` and `/opt/icewarp/icewarpd.sh` on the host
- `mysql` client on the host, with passwordless access via `~/.my.cnf` (same as the old shell script)

## Setup

From the repository root:

```bash
cp inventory/hosts.example.yml inventory/hosts.yml
cp inventory/group_vars/all.example.yml inventory/group_vars/all.yml
```

Edit both files. Required variables:

| Variable | Meaning |
| --- | --- |
| `iw_source_domain` / `iw_dest_domain` | IceWarp domains |
| `iw_source_mailbox_path` / `iw_dest_mailbox_path` | Domain `d_basemailboxpath` |
| `iw_source_archive_path` / `iw_dest_archive_path` | Domain archive roots |
| `iw_accounts_db` | Accounts database name |
| `iw_groupware_db` | Groupware database name |
| `iw_directorycache_db` | Directory cache database name |
| `iw_webclient_db` | Webclient database name |
| `iw_users` | List of local-parts or full source emails |

Mailbox paths (example):

```text
/opt/icewarp/tool.sh export domain 'olddomain.loc' d_basemailboxpath
```

Archive roots default to `/opt/icewarp/archive/<domain>/` when `u_autoarchivepath` is empty (`c_system_tools_autoarchive_path` + domain). A non-empty custom `u_autoarchivepath` that does not match the inventory source archive path fails the play.

## Usage

Run from the repository root.

List of users in inventory:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml
```

Single account (replaces `iw_users`):

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml -e iw_user=example.user
# or
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml -e iw_user=example.user@olddomain.loc
```

Preflight only (`tool.sh` + filesystem checks, no moves or SQL):

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml --check
```

Re-enable login after a successful move:

```bash
ansible-playbook -i inventory/hosts.yml playbooks/change-user-domain.yml -e iw_enable_login_after=true
```

## Safety

- Do not re-run a user that already moved: preflight fails (source gone, destination exists).
- Destination maildir and archive targets must not exist; the playbook will not overwrite them.
- The list stops on the first user failure. If an earlier user was already mutated, IceWarp is still restarted.
- Custom `u_autoarchivepath` values are not supported in v1.
