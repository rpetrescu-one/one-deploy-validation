# Core Services verification

Enable flag: `validation.run_core_services` · Play tag: `-t core_services`

## What it validates

Checks that the OpenNebula control plane on the primary frontend is healthy and resilient: the XML-RPC API answers, every configured systemd unit (oned, gate, flow, Fireedge by default) is enabled at boot and survives a restart, the OS package manager has an OpenNebula repository configured, one-gate/one-flow/Fireedge listen on their configured ports, every registered KVM host survives a disable/enable monitoring cycle, and datastores and marketplaces are registered with sane capacity. All checks run with `failed_when: false` — a failing check is recorded in the report and the run continues.

## How it works

The role runs only on the **first host of the frontend group** (the primary FE); it is skipped entirely, with a `Core services validation = skipped — cluster discovery failed` row, when the shared cluster discovery failed.

1. Optional induced-failure hook fires if `odv_fail_in=core_services` (or `validation.debug.fail_in`), then facts and `service_facts` are gathered and the `jc`/`jq` packages are installed via the shared tracked installer (manifested, so the sweep can remove them later).
2. `oneuser list` verifies the XML-RPC API.
3. For each entry of `validation.core_services.service_list`: record whether the unit is enabled at boot, restart it, and record whether it is running afterwards. Units not present on the FE get a `skipped - service not present` row instead.
4. `oned -v` records the version; the OS package sources are grepped for the configured OpenNebula repository (Debian and RedHat families).
5. On OpenNebula < 6.99 with `opennebula-scheduler.service` present, the legacy scheduler is stop/started and `sched.log` is checked for `oned successfully contacted`.
6. one-gate and one-flow listening ports are verified against their server config files; `opennebula-flow` is additionally stop/start cycled.
7. If `validation.core_services.check_fireedge_ui` is true and the unit exists, Fireedge is stop/start cycled, checked for boot enablement, its listening socket is polled (5 × 2 s), and the listen address is curl-ed. Otherwise all four Fireedge keys are recorded as skipped.
8. Every host registered in `onehost list` is manifested (`host_state`), then cycled: `onehost disable` → `enable` → `forceupdate` → poll up to 300 s (30 × 10 s) for the host to return to state `on`.
9. Datastore and marketplace pools are listed; non-`system` datastores must not report negative `FREE_MB`.
10. An aggregate `Core services validation` row is computed: `failed` if any of this role's own report keys recorded `failed`, else `ok`.

**Ordering note (HA/RAFT):** step 3 restarts `opennebula.service` on the primary FE. In an HA zone that is usually the RAFT **leader**, so the restart triggers a leader failover and destabilizes monitoring and the flow server for minutes. This is why the OneFlow smoke test is deliberately ordered **before** this role in `playbooks/validation.yml`, and why `validation.one_flow.state_retries/state_delay` may need raising on HA frontends when tests are re-run out of order.

## Requirements

- A deployed OpenNebula frontend reachable as the first host of the `frontend_group` inventory group, with the CLI tools (`oneuser`, `onehost`, `onedatastore`, `onemarket`) authenticated for the connecting user (host cycling runs as `oneadmin` via become).
- systemd (the role relies on `service_facts` and `systemctl`), plus `ss` and `curl` on the FE.
- Package-manager access to install `jc` and `jq` (or have them preinstalled).
- Registered hypervisor hosts whose monitoring can bring them back to state `on` within 300 s of a disable/enable cycle. Do not run this while a host is fenced or down — the cycle check will fail on it.
- Tolerance for brief service interruption: every listed unit is restarted, so the API/GUI blink, and on HA the RAFT leader fails over.

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_core_services` | `true` | Enable/disable the whole test. |
| `validation.core_services.service_list` | `opennebula.service`, `opennebula-gate.service`, `opennebula-flow.service`, `opennebula-fireedge.service` (each as `{name, desc}`) | Units to check for boot enablement and restart-resilience. `desc` is used to build the report keys. The reference inventory ships the same list; add entries to check more units. `opennebula-scheduler.service` needs no entry — it is checked automatically on < 6.99. |
| `validation.core_services.check_fireedge_ui` | `true` | Run the four Fireedge GUI checks (stop/start, boot enablement, listening port, HTTP connect). When false or the unit is absent, they are recorded as skipped. |
| `validation.debug.fail_in` | unset | Set to `core_services` to trigger the induced-failure hook (harness testing). Equivalent per-run extra var: `-e odv_fail_in=core_services`. |
| `frontend_group` | `frontend` | Inventory group whose first host runs the checks (global suite variable, not under `validation.`). |

## Example

Minimal inventory fragment (`group_vars/all.yml`):

```yaml
validation:
  run_core_services: true
  core_services:
    check_fireedge_ui: true
    service_list:
      - name: opennebula.service
        desc: OpenNebula core (oned)
      - name: opennebula-gate.service
        desc: OpenNebula gate
      - name: opennebula-flow.service
        desc: OpenNebula flow
      - name: opennebula-fireedge.service
        desc: OpenNebula Fireedge GUI
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```sh
make validation I=inventory/<env>/hosts.yaml ANSIBLE_ARGS='-e @playbooks/report_input_vars.yml'
```

Only this test (plus the always-on report/sweep plays):

```sh
make validation I=inventory/<env>/hosts.yaml TAGS=core_services
# or directly:
hatch env run -e validation-default -- ansible-playbook -i inventory/<env>/hosts.yaml \
  -t core_services -e @playbooks/report_input_vars.yml playbooks/validation.yml
```

## Report output

Report keys recorded via `verification_result` (comments carry the error detail on failure):

- `XML-RPC API status` — `ok`/`failed`.
- `<desc> is enabled`, `<desc> restarted` — one pair per `service_list` entry present on the FE (`ok`/`failed`); `<desc> not installed` = `skipped - service not present` for absent units.
- `Oned version` — the `oned -v` banner (rendered INFO) or `failed`.
- `Configured OpenNebula repository` — the repo URL or `failed`.
- `OpenNebula scheduler can contact oned` — `ok`/`failed`/skipped; recorded only on < 6.99.
- `OpenNebula one-gate service listens on the server` — `ok`/`failed`.
- `Verify one-flow stops and starts`, `Verify one-flow service port is open on the server` — `ok`/`failed`/skipped.
- `Verify fireedge GUI stops and starts`, `Verify fireedge GUI is enabled to start automatically`, `Verify fireedge GUI listens port`, `Verify connection to a fireedge server` — `ok`/`failed`, or `skipped - fireedge UI check disabled or service not present`; the connect check alone can also record `skipped - fireedge port not listening` when the port poll failed.
- `Status of the registered KVM hosts` — host id/name/state list, `no hosts registered`, or `failed`.
- `Put hosts offline and then set online. Hosts status` — `ok` only if **every** host returned to `on` within 300 s; `skipped - no hosts registered` otherwise applicable.
- `Datastores list`, `Datastore capacity more than 0`, `Registered marketplaces` — pool listings (INFO) and `ok`/`failed` checks. An empty marketplace pool is `failed`.
- `Core services validation` — the aggregate row: `failed` (comment lists the failing keys) if any key above failed, `ok` otherwise, or `skipped — cluster discovery failed`.

Badges in the HTML/PDF report follow the shared mapping: values containing `failed`/`error` render **FAIL**, `skipped … disabled` renders **INFO**, other `skipped` values render **WARN**, `ok` renders **PASS**, and free-text listings (version, pools, host tables) render **INFO**.

## Cleanup & failure behavior

- **Manifest:** each registered host is manifested as type `host_state` before cycling; `jc`/`jq` are manifested as type `package` only if this run actually installed them.
- **always block (unconditional restore):** every registered host is re-enabled — but **only** when its state is genuinely `dsbl`/`off`/`offline`/`disabled`, followed by `onehost forceupdate`. A blind `onehost enable` on an already-enabled host would reset its monitoring to INIT and leave the cluster momentarily unschedulable for the next test, so healthy hosts are left untouched. All `service_list` units, the legacy scheduler (< 6.99) and Fireedge are then (re)started regardless of check outcomes.
- **Leftovers:** any host the always block failed to re-enable is recorded via `record_leftover` (type `host_state`) and rendered as a red LEFTOVER row in the report's Execution & Cleanup Summary. `host_state` entries are deliberately excluded from the final sweep plan — restoration is this role's own job; the sweep only reports them. Manifested packages installed by this run are uninstalled by the final sweep.
- **rescue:** catches harness bugs only (plumbing failures — individual checks cannot throw) and records `Core services validation = failed` with the failing task's detail. The play never aborts.
