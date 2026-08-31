# Front-end High Availability

Enabled by `validation.run_fe_ha` (default `false`). Play tag: `-t fe_ha`.

## What it validates

A RAFT-based OpenNebula front-end HA deployment: that the OpenNebula API is
reachable through the floating VIP from every front-end, that the
configuration directories have identical file contents on all front-ends
(with `SERVER_ID` in `oned.conf` sanitized out, since it legitimately differs
per FE), that the zone has a RAFT leader, and that stopping `oned`
on that leader triggers a real failover — the VIP migrates and a *different*
FE is elected leader. Results go into the shared cloud verification report
and a standalone HTML report at `/tmp/fe_ha_report.html`
(written on the Ansible controller, not on a front-end).

## How it works

Runs on the hosts of the `frontend` group (`frontend_group` overrides the
name). Entry guards record a `skipped — …` row and do nothing else when
cluster discovery (from `validation_common`) failed or when `one_vip` is not
defined. Otherwise, inside a `block`/`rescue`/`always` harness:

1. Installs `jq` via the shared tracked-package helper — only packages this
   run actually installed are registered in the run manifest (role slug
   `fe-ha`) for the final sweep to remove.
2. **VIP reachability** — waits for `<one_vip>:2633` from every FE (up to
   `vip_timeout` seconds each) and records one aggregated row. If any FE
   cannot reach the VIP, the role deliberately aborts into `rescue`:
   stopping the leader while the VIP is already down would only make things
   worse.
3. **Leader discovery** — runs
   `onezone show <zone> -j | jq … STATE == "3"` on the first FE and records
   the initial leader; no leader found fails into `rescue`.
4. **Config parity** — recursively lists the files under each directory in
   `one_config_path` on every FE, drops paths matching
   `config_diff_exclude_patterns`, reads them with `slurp` (no disk
   changes), strips `SERVER_ID` lines from `/etc/one/oned.conf`, and
   compares every FE against the first FE (the reference host). Differences
   are recorded per host and file: presence, line counts, SHA-256, and the
   lines unique to each side.
5. **Leader failover** — stops the `opennebula` systemd unit on the leader,
   waits a fixed 20 seconds, re-checks VIP reachability from all FEs
   (recorded, but non-aborting so the restore still runs), then queries the
   new leader from a surviving FE. The check passes only when a new leader
   exists and differs from the initial one.
6. Records the overall verdict `FE HA validation = ok`, or `failed` with the
   list of failed sub-checks.

`rescue` records `FE HA validation = failed` with the failing task's detail.
`always` restarts `oned` on the original leader, verifies it with
`systemctl is-active`, records a leftover if the restore did not take, and
renders `/tmp/fe_ha_report.html` in every outcome. Leadership/VIP migration
is deliberately **not** reverted — a migrated leader is a valid HA state;
the report documents the before/after leaders.

## Requirements

- Front-end HA deployed per the OpenNebula documentation: 2+ front-ends in
  the inventory `frontend` group, RAFT zone configured, and a floating VIP
  (`one_vip`, normally inherited from the one-deploy inventory). Without
  `one_vip` the role records a skip and does nothing.
- The test is disruptive on purpose: it stops `oned` on the current leader.
  Run it against a cloud that can tolerate a leader failover.
- Package-manager access on the front-ends to install `jq`.
- `become` rights on the front-ends (systemd stop/start of `opennebula`).

## Configuration

Defaults come from the role; the *Reference* column shows
`inventory/reference/group_vars/all.yml` where it differs. Keys with a
variable named in parentheses fall back to that bare role-default variable,
so those can also be overridden as plain inventory vars
(`config_diff_exclude_patterns` has no bare-var fallback).

| Option | Default | Reference | Description |
|---|---|---|---|
| `validation.run_fe_ha` | `false` | `false` | Enable the role. |
| `validation.fe_ha.one_zone_name` | `OpenNebula` (`one_zone_name`) | same | Zone name passed to `onezone show` for both leader queries. |
| `validation.fe_ha.one_config_path` | `['/etc/one']` (`one_config_path`) | `['/etc/one', '/var/lib/one/remotes/etc']` | Directories whose file contents are compared across all FEs (recursive). |
| `validation.fe_ha.config_diff_exclude_patterns` | `['\.bak$']` | same | Regex patterns; file paths matching any of them are excluded from the diff. |
| `validation.fe_ha.vip_timeout` | `120` (`one_vip_timeout`) | — | Seconds each VIP reachability check waits for `<one_vip>:2633`. |
| `one_vip` | — (required) | — | Floating VIP of the HA front-end, from the deployment inventory. Undefined → the whole test records a skip. |
| `frontend_group` | `frontend` | — | Name of the inventory group holding the front-ends. |

## Example

```yaml
all:
  vars:
    one_vip: 172.20.0.100          # usually already set by one-deploy
    validation:
      run_fe_ha: true
      fe_ha:
        one_config_path:
          - /etc/one
          - /var/lib/one/remotes/etc
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```sh
make I=<inventory> validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (plus the always-on plumbing and the final cleanup sweep):

```sh
hatch run validation-default:ansible-playbook -i <inventory> -t fe_ha playbooks/validation.yml
```

Debug: `-e odv_fail_in=fe_ha` (or `validation.debug.fail_in: fe_ha`) forces a
failure inside the block to exercise the rescue/report path.

## Report output

Recorded keys:

- `FE HA validation` — `ok`, `failed` (comment: failed sub-checks or rescue
  detail), or `skipped — cluster discovery failed` /
  `skipped — one_vip is not defined …`.
- `VIP connectivity from all FEs` — `ok` or `failed` (+ unreachable FEs).
- `Initial FE leader node` — the leader hostname.
- `Check content of the config directory for file diffs at all FE nodes` —
  `ok` or `error - config file differences found`; the comment carries the
  reference host, exclude patterns, and expandable per-host/per-file diffs.
- `VIP reachability after leader migration` — `ok` or `failed`.
- `A new FE leader node after the failover` — the new leader hostname, or
  `failed` when no new leader was elected.

Badge mapping in the main report: `ok` → PASS; `failed` / `error - …` →
FAIL; `skipped — one_vip is not defined …` → WARN; hostname values → INFO.
`skipped — cluster discovery failed` contains "failed" and renders FAIL —
intentional, so cascaded skips are not mistaken for benign ones. The
standalone `/tmp/fe_ha_report.html` renders every check recorded on the
first front-end (in a full run that includes earlier roles' rows too), with
the same expandable config-diff details.

## Cleanup & failure behavior

The role creates no OpenNebula objects. It touches two things:

- `jq` (manifest type `package`, role `fe-ha`) — registered only when this
  run installed it, and uninstalled by the final `validation_sweep` play;
  pre-installed packages are never removed.
- the `opennebula` unit on the initial leader — stopped by the failover
  step and restarted in `always:` (idempotent, tolerant of an unreachable
  host, and skipped only when the block failed before a leader was
  identified, i.e. nothing was stopped). The restore is verified with
  `systemctl is-active`; if the unit is not active, a leftover row (type
  `host_state`, role `fe-ha`) lands in the report's Execution & Cleanup
  Summary (the per-host `odv_leftovers` fact — `/tmp/odv_manifest.json`
  carries only manifest/sweep entries).

Any unexpected failure lands in `rescue:` (recording
`FE HA validation = failed`), and `always:` still restores the leader and
renders the standalone report. Leadership and VIP placement are left where
the failover put them.
