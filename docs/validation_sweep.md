# Cleanup sweep & preclean (internal role)

Internal role: always active — no enable flag, no play tag, no induced-failure slug. It runs under the `always` tag, so it executes even on partial (`-t <test>`) runs.

## What it validates

Nothing — this is the suite's cleanup engine, not a test. It guarantees the "always clean" contract: every resource a validation run created (VMs, VM groups, vnets, flow services and templates, exported images/templates, files, packages, processes, bridge IPs) is deleted at the end of the run even when tests fail mid-way, resources that pre-existed (`reused`) are never touched, and anything it could not delete is reported as a red LEFTOVER row in the report's Execution & Cleanup Summary instead of silently surviving. It also precleans the *previous* run's leftovers before this run starts, so a stale broken resource (e.g. an err-state image) cannot poison this run's own resource reuse.

## How it works

The role has two wiring points in `playbooks/validation.yml`, both tagged `always`:

1. **Pre-run preclean** (`tasks_from: preclean.yml`, primary frontend only, right after the first `validation_common` play and before any test role): loads the per-host manifest mirror `/tmp/odv_manifest.json` left by the previous run (either its leftovers-only rewrite, or a full manifest from an aborted run). Cluster-object entries (`vm`, `service`, `service_template`, `vnet`, `template`, `image`) are deleted best-effort right away; host-local entries (`file`, `package`, `process`, `ip_addr`), `host_state` and `vm_group` are folded unchanged into this run's `odv_manifest` fact so the end-of-run sweep handles them. Images get an extra `oneimage delete --force` fallback (7.4 CLI) after the normal delete fails to converge — exactly the stuck err-image case that motivates the preclean. A uniform presence re-check then rewrites the mirror to what is still unresolved (kept in the file only, deliberately *not* in the fact — a stale `created` disposition from a prior run must not collide with a resource this run legitimately reuses under the same name).
2. **Final sweep** (the role itself, last play before the report, on frontends + nodes, no `run_*` gate; no-ops on an empty manifest): each host re-loads and merges its mirror (so a cleanup-only re-run after an abort still works — a corrupt mirror degrades to a warning), all hosts' `odv_manifest` facts are aggregated, and `tasks/lib/plan.yml` turns the aggregate into a sweep plan. OpenNebula objects are deleted on the primary frontend only (`sweep_one_objects.yml`), host-local types on every host (`sweep_local.yml`), and every plan entry is recorded as an `odv_sweep_results` row. Finally the mirror is rewritten to hold **only this run's unresolved leftovers**, so the next run's preclean retries them — and cannot resurrect already-deleted `created` entries against a same-named resource the operator re-created in between.

**Plan rules** (`tasks/lib/plan.yml`, pure logic, unit-tested by `test/harness/test_logic.yml`):

- Entries are deduped by `(type, name)` — by `(type, name, host)` for the host-local types `file`/`package`/`process`/`ip_addr`.
- If **any** duplicate says `disposition: created`, the resource is ours → `delete` (created wins over reused); all-`reused` → `keep-reused`.
- `image`/`template` entries that would be deleted become `keep-by-flag` when `validation.cleanup.keep_exported_images` is set.
- `host_state` entries are excluded entirely — restoring host state is the owning role's own job; that role reports failures via `odv_leftovers`.
- The first non-empty `id` among the duplicates wins.

**Deletion style** (both sweep files and the preclean): every delete runs as `oneadmin` with `failed_when: false` and prints an `ABSENT`/`GONE`/`STUCK` sentinel; already-absent resources are a clean no-op. In the final sweep (`sweep_one_objects.yml`), `vm`/`template`/`image` objects are resolved by **name first**; the manifest `id` is only a fallback and is used **only if the object's current name still matches the manifest entry** — a stale mirror or poisoned id can never kill an unrelated bystander. VMs get `onevm terminate --hard` with `onevm recover --delete` fallback and a converge wait; services `oneflow delete` with `oneflow recover --delete` fallback. A **second net** then catches anything that escaped the manifest, by the suite's deterministic name conventions: VMs matching `^(odv-|conn-mtx-vm-on-host|test_vm_ha|gpu-bench-)` and stray `flow-smoke-svc` services/service templates (`gpu-bench-` is skipped when `gpu_benchmark.keep_stack_on_failure` is set).

**Local types** (`sweep_local.yml`, every host, this host's plan entries only): `file` → `file: state=absent`; `ip_addr` (name contract `<ip>/32:dev:<bridge>`) → `ip addr del` + `ip route del`; `process` (name contract `<binary>:<port>`) → `pkill -f` with the pattern's first character bracketed so the wrapper shell never matches itself (pkill rc 0 and 1 both count as success); `package` → `package: state=absent`. A failed removal becomes a `leftover` row, the play continues.

## Requirements

- OpenNebula CLI on the primary frontend, working as `oneadmin` via become: `onevm`, `onevnet`, `onetemplate`, `oneimage`, `onevmgroup`, `oneflow`, `oneflow-template`, plus `jq` (used to verify names on id-fallback deletes). The image `--force` fallback needs the OpenNebula 7.4 CLI.
- Write access to `/tmp/odv_manifest.json` on every host (the per-host manifest mirror).
- On hypervisor hosts: `ip`, `pkill` and the OS package manager, for the host-local sweeps.

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.cleanup.keep_exported_images` | `false` (reference inventory: `false`) | Keep `image`/`template` resources the run created (`keep-by-flag`) instead of deleting them. Useful for iterative runs — the vLLM appliance image is multi-GB. |
| `gpu_benchmark.keep_stack_on_failure` | `false` | Top-level key read by the sweep's second net only: when set, stray `gpu-bench-*` VMs are excluded from the name-pattern kill so a failed GPU stack survives for post-mortem. Distinct from `gpu_benchmark.k8s.keep_stack_on_failure`, which is what the gpu-benchmark role's own teardown honors — set both to keep the whole stack. |
| `frontend_group` | `frontend` | Inventory group whose first host runs the preclean and the OpenNebula-object sweep (global suite variable, not under `validation.`). |
| `node_group` | `node` | Inventory group swept (together with the frontends) for host-local resources (global suite variable). |

No `odv_fail_in` slug exists for this role — the debug fail hooks live in the test roles.

## API reference (entry points)

### `tasks/main.yml` — the final sweep (role entry)

- **Wiring:** last play before the report, `hosts: frontends + nodes`, `tags: [always]`, no gate (skipped only in the GPU-benchmark `pre` phase, like the rest of the suite).
- **Inputs:** every play host's `odv_manifest` fact (rows appended by `validation_common/manifest_add.yml`: `{type, id, name, cluster, role, disposition, host}`) merged with that host's `/tmp/odv_manifest.json` mirror; `validation.cleanup.keep_exported_images`; `gpu_benchmark.keep_stack_on_failure`.
- **Registers:** per-host `odv_sweep_results` rows — the plan entry plus `action` (`removed` | `kept (reused)` | `kept (by flag)` | `leftover`) and `detail` (the delete's output, truncated to 200 chars, on `leftover`; second-net rows carry role `sweep (second net)` — their removed VM rows and all stray-flow rows carry detail `found by name pattern, not in manifest`, leftover VM rows `terminate did not converge`). Kept rows and OpenNebula-object rows are recorded on the primary frontend; local-type rows on their own host.
- **Side effect:** rewrites `/tmp/odv_manifest.json` to this host's `leftover` rows only.

### `tasks/preclean.yml` (`tasks_from`)

- **Wiring:** own play right after the first (`validation_common`) play, primary frontend only, `tags: [always]`.
- **Inputs:** `/tmp/odv_manifest.json` only (an aborted previous run leaves no facts). Missing/corrupt mirror → clean no-op.
- **Registers:** folds carry-through (`file`/`package`/`process`/`ip_addr`/`host_state`/`vm_group`) mirror entries into this run's `odv_manifest` fact; records the `verification_result` key `Pre-run leftover cleanup` = `removed N leftover(s) from a previous run` via `validation_common/record_result.yml` — only when N > 0, so a clean previous run adds no report row; VM deletion goes through `validation_common/terminate_vm_by_name.yml` (`tvbn_role: "sweep (pre-run)"`), which appends `odv_leftovers` rows for any VM it could not terminate.
- **Side effect:** rewrites the mirror to carry-through entries + still-present cluster objects.

### `tasks/lib/plan.yml` (`tasks_from`, pure logic)

- **Inputs:** fact `_sweep_manifest` (aggregated manifest entries), `validation.cleanup.keep_exported_images`.
- **Registers:** fact `_sweep_plan` — deduped entries with `action: delete | keep-reused | keep-by-flag` and the best-known `id`, `host_state` excluded. No side effects; this is the piece the logic harness unit-tests.

`tasks/sweep_one_objects.yml` and `tasks/sweep_local.yml` are internal to `main.yml` (they consume `_sweep_plan`) and are not meant to be included from elsewhere.

### How rows reach the report

The report play on localhost aggregates, from **all** hosts: `odv_manifest` → `report_manifest`, `odv_sweep_results` → `report_sweep_results`, `odv_leftovers` → `report_leftovers`. The Execution & Cleanup Summary section renders unconditionally: a count line (with an explicit warning when the manifest is non-empty but the sweep recorded nothing — i.e. the sweep play did not run), then one table row per sweep result. `removed` / `kept (reused)` / `kept (by flag)` render as plain text; `action: leftover` rows and every `odv_leftovers` row render as red **LEFTOVER** with the failure detail (and host, for `odv_leftovers`). The preclean's `Pre-run leftover cleanup` row renders as INFO in the main results table.

## Cleanup & failure behavior

This role *is* the cleanup; it creates nothing and never aborts the play — every delete is tolerant (`failed_when: false` / `ignore_errors`), and a corrupt manifest mirror degrades to a warning. Its failure mode is the LEFTOVER row: a resource that survived both its owning role's own `always:`/`rescue:` cleanup and this sweep (and, on the next run, the preclean's retry — including the image `--force` fallback) needs an operator to look at it. The leftovers-only mirror rewrite is what makes retries safe across runs: leftovers persist on purpose, resolved `created` entries must not.
