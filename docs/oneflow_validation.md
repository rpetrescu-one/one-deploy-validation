# OneFlow smoke test

Enabled by `validation.run_one_flow` (role default `false`; reference inventory: `true`). Play tag: `-t one_flow`.

## What it validates

End-to-end health of the OneFlow orchestration subsystem (`opennebula-flow`): the role
creates a temporary service template, instantiates a two-VM service from it, waits for the
service to reach `RUNNING`, reads back the role cardinality (VM count), and deletes
everything again. A cloud where any step of that lifecycle stalls or errors — flow API
down, scheduler not placing the VMs, delete not converging — fails the test. In
multi-cluster deployments the whole cycle runs once per discovered cluster.

## How it works

1. Runs on the **primary frontend** only, looping over the clusters discovered by
   `validation_common` (clusters without hosts are skipped by discovery). If cluster
   discovery failed, a single `skipped — cluster discovery failed` report row is recorded
   instead.
2. Picks a VM template for the service role: reuses the per-cluster template `test_vm`
   already exported when available, otherwise exports the marketplace app itself via the
   shared `validation_common/ensure_test_template.yml` (idempotent: reuses a pre-registered
   template of the same name, registers template + image in the run manifest, and appends
   `validation.test_vm.vm.template_extra` — CONTEXT, sizing — when defined). An assert
   guarantees a numeric template ID before continuing.
3. Renders a temporary service template JSON named `flow-smoke-svc<cluster-suffix>`:
   one role `app`, cardinality 2, `straight` deployment, `terminate-hard` shutdown.
4. Registers the service template and service in the run manifest **by name, before
   creation**, then runs `oneflow-template create` and `oneflow-template instantiate`.
   Both are retried 5×5 s against transient OneFlow API errors (e.g.
   `[one.document.info] Error getting document` on HA zones).
5. Polls `oneflow show` until `SERVICE STATE` is `RUNNING`, up to
   `state_retries × state_delay` (default 30 × 10 s = 300 s). If the state never reaches
   `RUNNING`, the last 20 lines of `oneflow show` are captured as the failure comment.
6. Reads the `app` role cardinality and records the report keys (see below).
7. In an `always` section: deletes the service (`oneflow recover --delete` for `FAILED_*`
   states, plain `oneflow delete` otherwise), polls up to 10×6 s until it is gone, deletes
   the service template (same wait), and removes the temporary JSON file. Non-converging
   deletes are recorded as leftovers, never silently ignored.

The play in `playbooks/validation.yml` deliberately schedules this role **before**
`core_services`: the core-services checks restart `oned`/`opennebula-flow`, and on an HA
zone restarting the leader's `oned` destabilizes monitoring and flow-server state for
minutes — OneFlow scheduled right after it fails on transients (observed live:
`one.document.info` errors, `DEPLOYING` stalls). Flow first, restarts after.

## Requirements

- OneFlow (`opennebula-flow`) running on the frontend, with the `oneflow` /
  `oneflow-template` CLI available to the connecting user.
- Per validated cluster: an image datastore and capacity to run **2 small VMs**
  (Alpine by default).
- Marketplace access to export the test app — not needed when `test_vm` already exported
  the template this run, or when a template with the expected name
  (`<market_name><cluster-suffix>`) is pre-registered (semi air-gapped sites; it is then
  marked `reused` and never deleted).

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_one_flow` | `false` (reference inventory: `true`) | Enable the test. |
| `validation.one_flow.state_retries` | `30` | Poll attempts while waiting for `SERVICE STATE: RUNNING`. |
| `validation.one_flow.state_delay` | `10` | Seconds between state polls. `state_retries × state_delay` is the total window (default 300 s) for the DEPLOYING→RUNNING transition — raise it on slow labs and on HA frontends. |
| `validation.test_vm.vm.market_name` | `'Alpine Linux 3.21'` | Marketplace app used for the service's VM template (shared with `test_vm`; same name means the exported template is shared, not duplicated). |
| `validation.test_vm.vm.template_extra` | unset | (shared) Template attributes appended when this role exports the template itself. |
| `validation.debug.fail_in: one_flow` | unset | Induced-failure hook for harness testing; also armable per-run via `-e odv_fail_in=one_flow`. |

## Example

Minimal inventory fragment (`group_vars` scope):

```yaml
validation:
  run_one_flow: true
  one_flow:
    state_retries: 60   # 60 x 10 s: double the poll window for a slow/HA lab
    state_delay: 10
```

Full suite:

```shell
make I=inventory/<env>.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml.example"
```

Only this test (tag `one_flow`):

```shell
make I=inventory/<env>.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml.example" TAGS=one_flow
# or directly:
hatch env run -e validation-default -- ansible-playbook -i inventory/<env>.yml -t one_flow playbooks/validation.yml
```

## Report output

Keys recorded into the HTML/PDF report (`… — cluster <name>` suffix added in
multi-cluster runs):

- `OneFlow smoke test (service/state/vms)` — value `service=<id>, state=<state>,
  vms_qty=<n>`. Renders **PASS** when `state=RUNNING`, **FAIL** when the state contains
  `FAILED`, **WARN** on `UNKNOWN`. The comment column carries `service state=<state>` plus
  the captured error detail (truncated to 800 chars).
- `OneFlow smoke test result` — `ok` (**PASS**) or `failed` (**FAIL**). This explicit
  pass/fail key is what the report's Execution & Cleanup Summary aggregates (the
  free-string key above is treated as informational there).
- `OneFlow smoke test` — `skipped — cluster discovery failed` (single row, only when
  discovery failed).

## Cleanup & failure behavior

Resources created per cluster, all registered in the run manifest: service template +
service `flow-smoke-svc<cluster-suffix>` before creation (manifest types
`service_template`, `service`, registered with an empty ID and the deterministic name so
the sweep can still resolve them when ID parsing fails), and — only when the role exports
the VM template itself — `template` + `image` named `<market_name><cluster-suffix>`,
registered immediately after the export completes (marked `reused` when pre-existing, and
then never deleted).

Any task failure lands in the block's `rescue` (captures the error message) and the
`always` section still runs the full cleanup and reporting; a play-level rescue in
`playbooks/validation.yml` keeps the rest of the suite going even if the role aborts.
Per-iteration facts are reset before each cluster, so a failure early in one cluster's
iteration can never run cleanup with the previous cluster's IDs. The role polls until the
service and the service template are actually gone; a delete that does not converge is
recorded as a `leftover` row (`service` / `service_template`) in the Execution & Cleanup
Summary, where leftovers render as failures. The suite-final `validation_sweep` play then
deletes anything still present per the manifest and additionally removes stray
`flow-smoke-svc*` services/templates by name pattern (second net); the pre-run sweep of
the next run cleans previous-run leftovers as well. The induced failure
(`-e odv_fail_in=one_flow`) fires before anything is created: the test reports `failed`
and cleanup finds nothing to remove.
