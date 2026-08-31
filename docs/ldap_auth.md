# LDAP authentication

Enabled by `validation.run_ldap_auth` (default `false`). Play tag: `-t ldap_auth`.

## What it validates

End-to-end LDAP authentication against a deployed OpenNebula frontend: that the
configured LDAP server accepts a bind, that oned has the `ldap` authentication
driver enabled, that a real LDAP user can log in through every entry point
(`oneuser` CLI, the raw XML-RPC endpoint, and the FireEdge web UI), that the
user's directory group maps to the expected OpenNebula group, and that local
(non-LDAP) authentication still works as a fallback. Every check is a recorded
comparison — a failing check is written into the report and the role moves on
to the next one instead of aborting the run.

## How it works

All checks run on the **primary frontend only** (first host of the `frontend`
group) and are skipped with a recorded reason when cluster discovery failed.

1. Installs the LDAP client tools via the shared tracked-package helper
   (`openldap-clients` + `curl` on RedHat, `ldap-utils` + `curl` on Debian
   and any other non-RedHat family);
   packages actually installed by this run are registered in the run manifest.
2. Parses `validation.ldap_auth.server` (an embedded `host:port` wins over
   `validation.ldap_auth.port`) and performs a base-scope `ldapsearch` bind as
   `bind_dn` → **LDAP bind to server**.
3. Greps `/etc/one/oned.conf` for an `ldap` `AUTHN` entry inside the
   `AUTH_MAD` section → **OpenNebula LDAP auth driver configured**.
4. Writes `ldap_user:ldap_pass` into a temporary `ONE_AUTH` file (mode 0600,
   registered in the run manifest) and runs `oneuser show` with it →
   **LDAP user login to XML-RPC**.
5. Searches the directory group `ldap_group_dn` (filter
   `(objectClass=posixGroup)`) for a `<ldap_group_member_attr>: <ldap_user>`
   line → **LDAP group membership (directory)**.
6. Compares `oneuser show -j` (as the LDAP user) against
   `onegroup show -j <expected_group_name>`: passes when the user's `GNAME`
   equals `expected_group_name` or its `GROUPS` contain the expected group id
   (`expected_group_id` if set, otherwise the id looked up by name) →
   **OpenNebula group mapping**.
7. POSTs a `one.user.info` XML-RPC call authenticated as
   `ldap_user:ldap_pass` to `rpc2_proto://<host>:<port>/RPC2` (port from
   `rpc2_port`, else `PORT` in `/etc/one/oned.conf`, else 2633); passes on
   HTTP 200 with no `<fault>` element → **XML-RPC (RPC2) login (LDAP)**.
8. POSTs a JSON login as the LDAP user to FireEdge, trying
   `fireedge_login_endpoint` plus the fallbacks `/fireedge/api/auth/`,
   `/api/login`, `/login` (port from `fireedge_port`, else
   `/etc/one/fireedge-server.conf`, else 2616); any HTTP 200/201 passes →
   **FireEdge UI login (LDAP)**.
9. Runs `oneuser show <local_user>` with `local_auth_file` as `ONE_AUTH` →
   **Local auth fallback**.

Steps 4–8 are skipped (with a recorded reason) when `ldap_user`/`ldap_pass`
are empty; the login/mapping checks are also skipped when the auth driver
check or a prerequisite check failed. Commands and request bodies embedding
passwords run with `no_log`, and recorded error comments have the passwords
masked.

## Requirements

- A reachable LDAP server; the bind and group checks use plain `ldap://`
  (no `ldaps://` support in this role).
- oned configured with the `ldap` auth driver (the role verifies this, it does
  not configure it), and an LDAP user that can authenticate to OpenNebula.
- A bind DN with read access to `base_dn` and the group entry; the group must
  be a `posixGroup` whose member attribute values literally contain the
  `ldap_user` string.
- Package-manager access on the frontend to install the LDAP client tools.
- A running FireEdge server for the UI login check (otherwise that single
  check records `failed`).

## Configuration

All options live under `validation.*`. Defaults below are the role defaults;
the *Reference* column shows the value set in
`inventory/reference/group_vars/all.yml` where it differs.

| Option | Default | Reference | Description |
|---|---|---|---|
| `validation.run_ldap_auth` | `false` | `false` | Enable the role. |
| `validation.ldap_auth.server` | `"127.0.0.1"` | `"172.20.0.7:389"` | LDAP server; `host:port` form overrides `port`. |
| `validation.ldap_auth.port` | `389` | — | LDAP port, used only when `server` has no `:port`. |
| `validation.ldap_auth.base_dn` | `"dc=example,dc=com"` | same | Search base for the bind check. |
| `validation.ldap_auth.bind_dn` | `""` | `"uid=admin,dc=example,dc=com"` | Bind DN for `ldapsearch` (bind + group lookup). |
| `validation.ldap_auth.bind_pass` | `""` | set | Bind password (kept out of logs/comments). |
| `validation.ldap_auth.ldap_user` | `""` | `"oneuser"` | LDAP test user; empty skips all login checks. |
| `validation.ldap_auth.ldap_pass` | `""` | set | Test user's password; empty skips all login checks. |
| `validation.ldap_auth.local_user` | `"oneadmin"` | same | Local user for the fallback check. |
| `validation.ldap_auth.local_auth_file` | `"/var/lib/one/.one/one_auth"` | same | `ONE_AUTH` file for the fallback check. |
| `validation.ldap_auth.group_mapping.expected_group_name` | `""` | `"opennebula-group"` | Expected OpenNebula group; empty skips the mapping check. |
| `validation.ldap_auth.group_mapping.expected_group_id` | `""` | `""` | Expected group id; empty means "use the id of `expected_group_name`". |
| `validation.ldap_auth.group_mapping.ldap_group_dn` | `""` | `"cn=opennebula-group,ou=group,dc=example,dc=com"` | Directory group DN; empty skips the directory membership check. |
| `validation.ldap_auth.group_mapping.ldap_group_member_attr` | `"memberUid"` | same | Member attribute searched for `ldap_user`. |
| `validation.ldap_auth.fireedge_host` | `""` | — | FireEdge host; empty falls back to the frontend's `ansible_host`. |
| `validation.ldap_auth.fireedge_port` | `""` | — | FireEdge port; empty reads `/etc/one/fireedge-server.conf`, else 2616. |
| `validation.ldap_auth.fireedge_proto` | `"https"` | `"http"` | FireEdge URL scheme. |
| `validation.ldap_auth.fireedge_login_endpoint` | `"/fireedge/api/auth/"` | same | First login endpoint tried; the built-in fallbacks are always appended. |
| `validation.ldap_auth.fireedge_skip_tls_verify` | `true` | same | Skip TLS certificate verification for FireEdge. |
| `validation.ldap_auth.rpc2_host` | `""` | — | XML-RPC host; empty falls back to the frontend's `ansible_host`. |
| `validation.ldap_auth.rpc2_port` | `""` | — | XML-RPC port; empty reads `PORT` from `/etc/one/oned.conf`, else 2633. |
| `validation.ldap_auth.rpc2_proto` | `"http"` | same | XML-RPC URL scheme. |
| `validation.ldap_auth.rpc2_path` | `"/RPC2"` | same | XML-RPC endpoint path. |
| `validation.ldap_auth.rpc2_skip_tls_verify` | `true` | same | Skip TLS certificate verification for XML-RPC. |

## Example

```yaml
all:
  vars:
    validation:
      run_ldap_auth: true
      ldap_auth:
        server: "172.20.0.7:389"
        base_dn: "dc=example,dc=com"
        bind_dn: "uid=admin,dc=example,dc=com"
        bind_pass: "..."
        ldap_user: "oneuser"
        ldap_pass: "..."
        group_mapping:
          expected_group_name: "opennebula-group"
          ldap_group_dn: "cn=opennebula-group,ou=group,dc=example,dc=com"
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```sh
make I=<inventory> validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (plus the always-on plumbing and the final cleanup sweep):

```sh
hatch run validation-default:ansible-playbook -i <inventory> -t ldap_auth playbooks/validation.yml
```

Debug: `-e odv_fail_in=ldap_auth` (or `validation.debug.fail_in: ldap_auth`)
forces a failure inside the block to exercise the rescue/report path.

## Report output

Rendered in the report's **LDAP Authentication** table (keys containing
`ldap`/`rpc2`) — except `OpenNebula group mapping` and `Local auth fallback`,
which contain neither and render in the **Other Checks** table instead;
recorded keys:

- `LDAP authentication validation` — only on failure paths: `failed` (rescue)
  or `skipped — cluster discovery failed`.
- `LDAP bind to server`, `OpenNebula LDAP auth driver configured`,
  `LDAP user login to XML-RPC`, `LDAP group membership (directory)`,
  `OpenNebula group mapping`, `XML-RPC (RPC2) login (LDAP)`,
  `FireEdge UI login (LDAP)`, `Local auth fallback` — `ok`, `failed`, or a
  `skipped …` reason; failures carry a sanitized comment.

Badge mapping: `ok` → PASS; `failed` → FAIL; `skipped (missing …)` /
`skipped — no … configured` → WARN. A skip *caused by an upstream failure*
(e.g. `skipped — LDAP bind to server failed`) contains the word "failed" and
therefore also renders as FAIL — intentional, so cascaded skips are not
mistaken for benign ones.

## Cleanup & failure behavior

Created resources, all registered in the run manifest before use:

- the temporary `ONE_AUTH` credentials file (manifest type `file`, role
  `ldap-auth`) — removed by the role's `always:` section at the end of the
  block, and again by the final `validation_sweep` play if the run aborted
  before that;
- LDAP client packages *newly installed by this run* (manifest type
  `package`) — uninstalled by the final sweep; packages already present
  before the run are never manifested or removed.

Individual checks never abort the role — they record `ok`/`failed` and
continue. A genuine environment failure (e.g. tempfile creation, fact
gathering) lands in `rescue:`, which records
`LDAP authentication validation = failed` with the failing task's detail; the
`always:` cleanup still runs. Anything the sweep fails to delete is recorded
as a `leftover` row in the report's Execution & Cleanup Summary and kept in
`/tmp/odv_manifest.json` so the next run retries it.
