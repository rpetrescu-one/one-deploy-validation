# VM High Availability (destructive)

Enabled by `validation.run_vm_ha` (default `false`). Play tag: `-t vm_ha`.

**This test fences (powers off) one hypervisor per cluster on purpose.** It is ordered in
`playbooks/validation.yml` after every test that touches the hypervisors (only the
frontend-only `fe_ha` and `federation` plays follow it) — so a powered-off node cannot fail
their checks, and it asks for interactive confirmation before injecting the fault unless
`auto_confirm: true`.

## What it validates

Proves the whole OpenNebula VM-HA chain works end to end on each discovered cluster: a real host
error is detected by monitoring, the `host_error` hook fires on the RAFT leader, the fencing
driver powers the dead host off, the hook's `-r` delete-recreate resubmits the test VM, and the
VM reaches `RUNNING` again on a surviving host.

## How it works

Runs on the primary frontend, looping over every discovered cluster (report keys get a
` — cluster <name>` suffix when more than one cluster is validated):

1. **Setup**: ensures the marketplace template via the shared
   `validation_common/tasks/ensure_test_template.yml` (reused if pre-registered), instantiates
   `test_vm_ha<cluster-suffix>` pinned to the cluster with `SCHED_REQUIREMENTS` (the VM has no
   NIC), waits for `runn` (`deploy_retries` × `deploy_delay`), and reads the placement history
   for the deployment host name/ID and system-datastore ID.
2. **Fault injection**: after the confirmation pause, delegates
   `tasks/vm_ha_produce_error_<produce_error_method>.yml` to the Ansible node matching that
   OpenNebula host. The default `if_down` method runs
   `ip link set dev <if_down_params.interface_name> down` (async, loss of SSH tolerated — the
   interface is deliberately **never** restored, see Cleanup).
3. **Leader resolution**: maps the RAFT leader from `onezone show 0` to an inventory frontend by
   comparing `SERVER_ID` in each frontend's `oned.conf` — `/var/log/one/host_error.log` exists
   only on the leader, so all log checks are delegated there (single-frontend zones resolve to
   the local host).
4. **Verification**: `onehost forceupdate`, waits for host state `err` (30 × 5s, fixed), then
   greps `host_error.log` entries newer than the pre-test timestamp for `Hook launched`,
   `Fencing enabled` (`fencing_check_retries` × `fencing_check_delay` — fencing can take
   minutes), `Fencing success` and `Hook finished`.
5. **Recovery**: polls up to `recovery_retries` × `recovery_delay` seconds for the recreated VM
   to reach `runn` on a surviving host. If the VM sits in `clea*` (CLEANUP_RESUBMIT) for
   `cleanup_wedge_polls` consecutive polls, the role applies OpenNebula's documented operator
   remedy **once** — `onevm recover --failure` — and reports the recovery as WARN (see Report
   output).
6. **Cleanup** (`always:`): terminates the test VM by name, sets the dead host OFFLINE, and
   either recovers the node automatically (`node_power_on_cmd`) or records a leftover with the
   manual runbook.

## Requirements

- VM HA configured as per the OpenNebula documentation: the `host_error` `HOST_HOOK` on the
  frontends with `ARGUMENTS = "$TEMPLATE -r"` and `ARGUMENTS_STDIN = yes` — `-r` makes the hook
  delete-recreate the VMs of the failed host, and `$TEMPLATE` delivers the base64-encoded host
  template on stdin. The hook executes on the **RAFT leader** (the role finds it by itself).
- A **working fencing driver**: `fence_host.sh` must actually power the host off — it receives
  the base64 host template on stdin and parses it with `xpath.rb -b`, and must be adapted to
  your out-of-band mechanism (IPMI/BMC, virsh in nested labs, ...). Without real fencing the
  test stalls at the `Fencing success` check.
- At least two monitored hypervisors per validated cluster, so a surviving host can take the
  recreated VM (its image is PROLOG-cloned from scratch there — slow storage needs a larger
  `recovery_retries` window).
- `if_down_params.interface_name` must exist on the nodes and its loss must make host monitoring
  fail (the bridge/NIC carrying the monitoring network).
- The hypervisors must be in the inventory `node` group — the role maps the OpenNebula host name
  to an Ansible host to delegate the fault injection, and fails if no match is found.
- A TTY for the confirmation pause, or `auto_confirm: true` — `ansible.builtin.pause` blocks
  forever on unattended runs otherwise.
- OpenNebula CLI + `oneadmin` + `jq` on the frontends; marketplace reachability unless the
  template is pre-registered.

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_vm_ha` | `false` | Enable/disable the whole test. |
| `validation.vm_ha.produce_error_method` | `if_down` | Fault-injection method; loads `tasks/vm_ha_produce_error_<method>.yml` (only `if_down` ships). |
| `validation.vm_ha.if_down_params.interface_name` | none — **required** (reference inventory: `br-test`) | Interface downed on the VM's host. Never restored by the suite. |
| `validation.vm_ha.fencing_check_retries` / `fencing_check_delay` | `8` / `60` | Poll window (retries × seconds) for `Fencing enabled` in `host_error.log`. |
| `validation.vm_ha.deploy_retries` / `deploy_delay` | `30` / `10` | Poll window for the initial VM to reach `runn` before the fault is injected. |
| `validation.vm_ha.recovery_retries` / `recovery_delay` | `60` / `10` | Poll window for the recreated VM to reach `runn` on a surviving host after fencing. |
| `validation.vm_ha.cleanup_wedge_polls` | `12` | Consecutive `clea*` polls (× `recovery_delay` seconds) before the one-shot `onevm recover --failure` unwedge. |
| `validation.vm_ha.auto_confirm` | `false` | `true` skips the interactive confirmation pause — required for unattended runs. |
| `validation.vm_ha.node_power_on_cmd` | unset | Automated fenced-node recovery: shell command run on the frontend as `oneadmin` with `$ODV_FENCED_HOST` (OpenNebula host NAME) and `$ODV_FENCED_HOST_ID` in the environment (e.g. `ipmitool ... chassis power on`). Unset → the host stays OFFLINE and the report carries the manual runbook. |
| `validation.vm_ha.node_boot_timeout` | `300` | Seconds to wait for the powered-on node to answer SSH again (only with `node_power_on_cmd`). |
| `validation.vm_ha.node_monitored_retries` | `30` | × 10s polls for the re-enabled host to be monitored again (only with `node_power_on_cmd`; the manual path probes once). |
| `validation.vm_ha.vm_market_name` | `Alpine Linux 3.21` | Marketplace app to export; also the template/image name (cluster suffix appended). |
| `validation.vm_ha.oned_conf` | `/etc/one/oned.conf` | Path read on each frontend for `SERVER_ID` when mapping the RAFT leader. |
| `frontend_group` | `frontend` | Inventory group of the front-ends: its first host runs the test and all its hosts are scanned for `SERVER_ID` when mapping the RAFT leader (global suite variable, not under `validation.`). |
| `node_group` | `node` | Inventory group searched for the Ansible host matching the VM's placement — that host receives the fault injection over SSH (global suite variable). |
| `validation.debug.fail_in` / `-e odv_fail_in=vm_ha` | unset | Induces a failure at the start of the per-cluster block to exercise the rescue/cleanup path. |

## Example

```yaml
all:
  vars:
    validation:
      run_vm_ha: true
      vm_ha:
        produce_error_method: 'if_down'
        if_down_params:
          interface_name: 'br-test'
        auto_confirm: true          # unattended run
        node_power_on_cmd: 'ipmitool -H bmc-$ODV_FENCED_HOST chassis power on'
```

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```shell
# full suite (vm-ha runs after all node-touching tests)
make validation I=inventory/<env>/hosts.yaml ANSIBLE_ARGS='-e @playbooks/report_input_vars.yml'

# this test only (plays tagged `always` — discovery, cleanup sweep, report — still run)
hatch env run -e validation-default -- \
  ansible-playbook -i inventory/<env>/hosts.yaml -t vm_ha playbooks/validation.yml
```

## Report output

Keys recorded into the summary checks table (suffixed with ` — cluster <name>` in multi-cluster
runs):

| Key | Values |
|---|---|
| `VM HA: download a test VM template from the marketplace` | `ok` (PASS). |
| `VM HA: host error detected on host` | the failed host's name (INFO). |
| `VM HA: error hook triggered` | `ok` (PASS). |
| `VM HA: host fencing triggered on host` | the fenced host's name (INFO). |
| `VM HA: host fencing successful on host` | the fenced host's name (INFO). |
| `VM HA: error hook successful` | `ok` (PASS). |
| `VM HA: VM recovered successfully on host` | the new host's name (INFO), **or** `warning — recovered on <host> only after 'onevm recover --failure': ...` (WARN) when the delete-recreate wedged (below). |
| `VM HA: fenced host recovered automatically` | `ok` (PASS) — only when `node_power_on_cmd` ran and the host is monitored again. |
| `VM HA validation` | only on error: `failed` (FAIL, truncated error detail as comment) from the rescue, or `skipped — cluster discovery failed` (rendered FAIL). |

Two outcomes are deliberately reported as degraded rather than hidden:

1. **Wedged recovery (WARN)** — the delete-recreate can hang in `CLEANUP_RESUBMIT` forever:
   oned cancels the cleanup driver command racing the just-fenced host's power-off and no
   completion callback ever arrives. After `cleanup_wedge_polls` × `recovery_delay` seconds of
   consecutive `clea*`, the role applies `onevm recover --failure` once (correct: the host *is*
   dead) so the VM resubmits — the recovery row then carries the `warning — ...` value.
2. **Fenced host left OFFLINE (leftover)** — without `node_power_on_cmd` the host is *not*
   brought back: a dead host left in ERROR re-triggers the `host_error` hook every few minutes
   and each re-fire re-fences a manually powered-on node (observed live), so the role sets it
   OFFLINE to stop monitoring and the re-fire loop, and records an `odv_leftovers` row with the
   offline-first manual runbook: power the node on, `onehost enable <id>`, and remove the stale
   directory `/var/lib/one/datastores/<ds_id>/<vm_id>` (named in the report) that the fenced
   recreate left on the node.

## Cleanup & failure behavior

Resources created and their manifest entries (`type` / disposition): the VM
`test_vm_ha<cluster-suffix>` (`vm` / `created`, or `reused` when it pre-existed — registered
*before* instantiation so the sweep finds it even if instantiate half-succeeds), and the
exported template + image per cluster (`template` + `image` / `created` or `reused`).

On any failure inside the per-cluster block, the rescue records `VM HA validation<suffix> =
failed` and continues with the next cluster. The `always:` section then runs regardless:

- Terminates the test VM **by name** via the shared `terminate_vm_by_name` service
  (`terminate --hard` → `recover --delete`, polling until gone); a survivor becomes an
  `odv_leftovers` `vm` row (`terminate did not converge`).
- Never restores the downed interface — it may be the node's only SSH path, and fencing powers
  the host off anyway; node recovery is out-of-band by design.
- Sets the fenced host OFFLINE when it is not monitored (states other than `1`/`2`); a host that
  is still monitored (the test failed before fencing) is left untouched.
- With `node_power_on_cmd`: powers the node on, waits `node_boot_timeout` for boot, removes the
  stale system-datastore directory, re-enables the host and polls `node_monitored_retries` × 10s
  — success records the `fenced host recovered automatically` PASS row; anything short of
  monitored records the `host_state` leftover with the manual runbook instead.

Independently, the suite-final sweep play (tagged `always`) deletes every manifest resource with
disposition `created` (VM, template, image) and reports each as `removed`/`leftover`; `reused`
resources are kept.
