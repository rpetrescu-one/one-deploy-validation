# Federation validation

Enabled by `validation.run_federation` (default `false`). Play tag: `-t federation`.

## What it validates

That an OpenNebula federation is correctly configured and healthy across all
zones: the `FEDERATION` block in `oned.conf` (MODE, ZONE_ID, and — on slaves —
MASTER_ONED), FireEdge's default-zone configuration and service state, zone
discovery via `onezone`, TCP reachability of every zone endpoint, the XML-RPC
API of the master zone (from slaves), synchronization of federated resources
(users, groups, ACL rules, marketplaces, VDCs), database backend and
replication log status (MySQL/MariaDB), and consistency of the federated
counts across all zones. The role is read-only — it creates no VMs or other
resources — and every check records a row and moves on instead of aborting.

## How it works

The role runs on **every host of the frontend group** (in a federation
inventory, each zone's frontend); cross-zone steps aggregate over the
`zone_group`. If cluster discovery failed on the primary frontend, the whole
role is replaced by one recorded skip per frontend host
(`Federation validation on <host>`). Six sub-checks run in order, each
individually toggleable:

1. **check_federation_config** — extracts the `FEDERATION` block from
   `oned.conf`: MODE must parse as `MASTER` or `SLAVE` (anything else,
   including STANDALONE, records `failed`), ZONE_ID must be set, and on SLAVE
   zones MASTER_ONED must be an `http(s)://` URL. If `check_fireedge` is on,
   compares the `default_zone` id in `fireedge-server.conf` against the oned
   ZONE_ID; the FireEdge service's systemd state is recorded regardless of
   the toggle.
2. **check_zones** — `onezone list -j`: records the zone count (warning when
   below `min_zones`), checks that all zones report the same `FED_INDEX`
   (`info` on HA followers with no data), and verifies via `onezone show`
   that the configured ZONE_ID actually exists in the federation.
3. **check_endpoints** — TCP-connects (`wait_for`, `endpoint_timeout`
   seconds) to the host:port parsed from every zone's ENDPOINT URL (on every
   host except the first `zone_group` host, the endpoint list is taken from
   the first host's discovery — its own list is overwritten). On SLAVE zones
   it additionally pings the master and, if reachable,
   POSTs a `one.system.version` XML-RPC call authenticated from
   `/var/lib/one/.one/one_auth` (no route records `info`, not a failure).
4. **check_data_sync** — counts federated resources with `oneuser`,
   `onegroup`, `onemarket`, `oneacl` (zero users/groups records `failed`);
   optionally verifies oneadmin has user ID 0 (`verify_oneadmin`); records
   the DB `BACKEND` from `oned.conf` and, for MySQL with `check_db_backend`,
   the `logdb` row count using the credentials parsed from `oned.conf`.
5. **check_advanced_sync** — VDC / marketplace-app / datastore / vnet counts
   (each behind its own toggle), all zones enabled (STATE 0), zone
   server-pool size (HA), MySQL `logdb` replication lag (warning above a
   hardcoded 300 s), cross-zone VM visibility, a local timestamp row
   (`check_time_sync`), and on SLAVE zones an authenticated
   `oneuser show --endpoint <MASTER_ONED>` test.
6. **check_consistency** — compares the users/groups/ACL counts recorded by
   all `zone_group` hosts; identical counts record `ok - consistent`,
   differing ones a warning. Skipped when the group has fewer than two hosts.

Any unexpected task error lands in the block's `rescue:`, which records
`Federation validation on <host> = failed` with the failing task's detail.

## Requirements

- A deployed federation: `FEDERATION` MODE `MASTER` or `SLAVE` in `oned.conf`
  on every frontend the play targets (a standalone zone records MODE as
  `failed`), at least `min_zones` zones registered.
- All zone frontends present in one inventory group (`zone_group`, normally
  the frontend group) — the endpoint borrowing and cross-zone consistency
  comparison read facts from those hosts.
- `oneadmin` CLI access on each frontend (tasks `become_user: oneadmin`) and
  a readable `/var/lib/one/.one/one_auth` for the master API test.
- Network reachability from each frontend to every zone endpoint's host:port;
  ICMP to the master for the slave-side probes (no route degrades those rows
  to `info`).
- For the DB checks: a MySQL/MariaDB backend and the `mysql` client on the
  frontend; on SQLite the log/lag checks are skipped. The replication-lag
  query connects as `mysql -u oneadmin opennebula` with no password — on a
  password-protected DB the `replication lag` row is silently absent (only
  the step-4 log-entries count uses the credentials parsed from `oned.conf`).

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_federation` | `false` | Enable the role (playbook-level switch). |
| `validation.federation.zone_group` | `frontend_group` \| `'frontend'` | Inventory group holding all zone frontends (reference inventory sets `frontend`). |
| `validation.federation.min_zones` | `2` | Minimum zone count before `total zones` records a warning. |
| `validation.federation.endpoint_timeout` | `10` | Seconds for each endpoint TCP test and the master XML-RPC call. |
| `validation.federation.check_fireedge` | `true` | Compare FireEdge `default_zone` against the oned ZONE_ID. |
| `validation.federation.check_db_backend` | `true` | Record `logdb` count / replication lag on MySQL backends. |
| `validation.federation.verify_oneadmin` | `true` | Verify the oneadmin user exists with ID 0. |
| `validation.federation.oned_conf` | `/etc/one/oned.conf` | oned configuration file to parse. |
| `validation.federation.fireedge_conf` | `/etc/one/fireedge-server.conf` | FireEdge configuration file to parse. |
| `validation.federation.check_federation_config` | `true` | Sub-check toggle (step 1). |
| `validation.federation.check_zones` | `true` | Sub-check toggle (step 2). |
| `validation.federation.check_endpoints` | `true` | Sub-check toggle (step 3). |
| `validation.federation.check_data_sync` | `true` | Sub-check toggle (step 4). |
| `validation.federation.check_advanced_sync` | `true` | Sub-check toggle (step 5). |
| `validation.federation.check_consistency` | `true` | Sub-check toggle (step 6). |
| `validation.federation.check_vdc_sync` | `true` | Record the VDC count (step 5). |
| `validation.federation.check_marketplace_apps` | `true` | Record the marketplace-app count (step 5). |
| `validation.federation.check_datastores` | `true` | Record the datastore count (step 5). |
| `validation.federation.check_vnets` | `true` | Record the vnet count (step 5). |
| `validation.federation.check_time_sync` | `true` | Record the per-host timestamp row (step 5). |

`expected_mode`, `xmlrpc_port`, `grpc_port`, `max_time_drift`, and
`max_replication_lag` are declared in the role defaults (and the ports appear
in the reference inventory block) but are **not consumed by any check** —
setting them has no effect today; endpoint ports come from the zone ENDPOINT
URLs and the lag threshold is fixed at 300 s.

## Example

```yaml
all:
  vars:
    validation:
      run_federation: true
      federation:
        min_zones: 2
        endpoint_timeout: 10
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```sh
make I=<inventory> validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (plus the always-on plumbing and the final cleanup sweep):

```sh
hatch run validation-default:ansible-playbook -i <inventory> -t federation playbooks/validation.yml
```

Debug: `-e odv_fail_in=federation` (or `validation.debug.fail_in: federation`)
forces a failure inside the block to exercise the rescue/report path.

## Report output

Federation rows appear twice: keys containing `federation` render in the
**Federation Configuration** check table (aggregated results) — except keys
whose text also matches an earlier report category: `Federation FireEdge
service` and the `marketplaces`/`marketplace apps`/`datastores` count rows
land in the **Core Services** table, and a `Federation endpoint <url>` row
whose URL contains `RPC2` lands in the **LDAP Authentication** table. The
**Federation Detailed Results (All Zones)** matrix still shows every recorded
key per frontend with the ` on <host>` suffix stripped — one column per zone.
The Execution & Cleanup Summary's `Federation` row shows the worst outcome.

Recorded keys (per host unless noted): `Federation MODE`, `ZONE_ID`,
`MASTER_ONED` (slaves), `FireEdge zone ID` / `zone name` /
`zone ID verification` / `FireEdge service`, `total zones`,
`FED_INDEX consistency`, `zone ID verification`,
`endpoint connectivity` (skip row), `Federation endpoint <url>` (per
endpoint), `master API accessible` (slaves), `users count`, `groups count`,
`oneadmin user`, `database backend`, `log entries` (MySQL), `marketplaces
count`, `ACL rules count`, `VDCs count`, `marketplace apps count`,
`all zones enabled`, `datastores count`, `vnets count`, `server pool` /
`server pool size in zone <id>`, `replication lag` (MySQL),
`cross-zone VM visibility`, `time`, `slave auth to master` (slaves),
`users/groups/ACLs consistency across zones`, `cross-zone consistency`
(skip row), and `Federation validation` (only on discovery-skip or rescue).

Badges: `ok`/`ok - …`/`reachable`/`active` → PASS; values containing
`failed`, `unreachable`, `inactive`, or `error` → FAIL; `warning …` or plain
`skipped …` → WARN; `info - …` and bare values (counts, `MASTER`, zone ids,
backend names) → INFO. A skip caused by an upstream failure (e.g. `skipped —
no ZONE_ID (federation config check failed or disabled)`) contains "failed"
and therefore renders FAIL — intentional, so cascaded skips stand out.

## Cleanup & failure behavior

The role is entirely read-only: it creates no VMs, files, or packages,
registers nothing in the run manifest, and the final `validation_sweep` play
has nothing of its own to delete — it can never produce leftover rows.
Individual checks use `failed_when: false` and record their own
`failed`/`warning` rows; only an unexpected task error reaches `rescue:`,
which records `Federation validation on <host> = failed` (with the failing
task and message, truncated) and lets the rest of the run continue.
