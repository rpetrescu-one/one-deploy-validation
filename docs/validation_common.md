# Shared services & harness internals (internal role)

**Internal role — always active.** No `run_*` flag, no tag: it runs in the first play of
`playbooks/validation.yml` on every host, before any test role (skipped, like the whole
suite, in the GPU-benchmark pre phase), and every test role
`include_role`s its task files as a library.

## What it validates

Nothing by itself — this is the shared library of the suite. It discovers the OpenNebula
clusters to validate (facts the per-cluster tests iterate over), and provides the harness
primitives every test uses: the run manifest that makes cleanup deterministic, result/failure
recording for the report, tracked package installs, VM termination for `always:` cleanup
blocks, and the shared "ensure template/vnet exists" services.

## How it works

1. Every host records the output of `hostname` as the `hostname_cmd` fact (consumed by
   `conn_matrix`/`vm-ha` host mapping).
2. On the primary frontend only (first host of `frontend_group`, default `frontend`), it runs
   `cluster_discovery.yml`: lists cluster/datastore/vnet pools, keeps clusters that have hosts
   (optionally filtered by `validation.clusters`), resolves each cluster's image datastore and
   test/conn-matrix/storage vnets, and builds `one_clusters`, `one_clusters_multi` and
   `host_id_to_cluster`. Clusters without hosts are recorded as skipped.
3. `host_map.yml` then builds `host_name_to_hostname_cmd` (ONE host NAME → monitored
   `TEMPLATE.HOSTNAME`).
4. A discovery failure does not kill the run: a `rescue:` sets `odv_discovery_failed: true`
   and records `Cluster discovery = failed` — tests self-skip on that fact and the report
   still renders.
5. For the rest of the run the role is passive: tests call its entry points (below). Resources
   are registered in the manifest *before* creation, so the final `validation_sweep` play can
   clean up even after an aborted run (via the `/tmp/odv_manifest.json` mirror).

## Requirements

- ONE CLI tools (`onecluster`, `onevnet`, `onevm`, `onetemplate`, `onemarketapp`, ...) usable
  as `oneadmin` via `become` on the primary frontend.
- `jq` on the frontend for `terminate_vm_by_name.yml` state polling (the core-services role
  installs it via `install_packages_tracked`; standalone tag runs may need it pre-installed).
- Marketplace access for `ensure_test_template.yml`, unless the template is pre-registered
  under the target name (semi air-gapped reuse path).

## Configuration

Most keys are optional with code defaults (`| d(...)`); rows marked
**required at point of use** are read bare by the shared services and must be
present whenever that path runs (the reference inventory sets them). Where
`inventory/reference/group_vars/all.yml` recommends a different value, both are shown.

| Option | Default | Description |
|---|---|---|
| `validation.clusters` | unset = all clusters with hosts | Restrict validation to the named clusters. Unknown names abort discovery. |
| `validation.cluster_overrides.<name>.image_ds_id` | auto: first image datastore (TYPE 0) of the cluster | Per-cluster image datastore override. |
| `validation.cluster_overrides.<name>.vnet_name` | auto (see vnet resolution below) | Per-cluster vnet override; wins for primary, conn-matrix and storage vnets and bypasses the eligibility filter. |
| `validation.network.skip_vnets` | `[]` | Vnet names never auto-selected during discovery. |
| `validation.network.require_ip_ar` | `true` | Auto-selected vnets must own at least one IP4/IP6 Address Range (ETHER-only vnets give test VMs no observable IP). |
| `validation.run_test_vm` | `true` | Read by discovery to decide whether the test vnet may still be created later in the run. |
| `validation.test_vm.vnet_name` | `VLAN_580` (reference: `public`) | Base name of the per-cluster test vnet; multi-cluster runs append `-<cluster>`. **Required at point of use**: `ensure_test_vnet.yml` reads it bare — the `VLAN_580` default applies only inside cluster discovery. |
| `validation.test_vm.create_vnet` | `true` (reference: `false`) | Gates `ensure_test_vnet.yml`: create/update the test vnet vs. reuse an existing one. **Required at point of use** on the test-vnet path (read bare). |
| `validation.test_vm.vnet.*` | see `templates/test_vnet.j2` | Rendered vnet definition: `desc`, `vn_mad`, `ar` (list of `{type, ip, size}`) are required; `bridge` (default `br-test`, `null`/omitted omits), `phydev` (`null`/omitted omits), `network_address` (`10.0.0.0`), `network_mask` (`255.255.255.0`), `dns` (`8.8.8.8`), `gateway` (`10.0.0.254` — the template's bare `10.0.0.1` fallback is shadowed by the test_vm role default). |
| `validation.test_vm.vm.template_extra` | unset (reference sets MEMORY + CONTEXT with `SSH_PUBLIC_KEY`) | Raw template text appended (`onetemplate update --append`) to every template ensured with `ensure_apply_extra` (ssh-based checks depend on its CONTEXT). |
| `validation.conn_matrix.vnet_name` | `vnet-default` (reference: `public`) | Preferred conn-matrix vnet; falls back to the cluster's primary vnet when absent/ineligible. |
| `validation.storage_benchmark.vnet_name` | `VLAN_580` (reference: `public`) | Preferred storage-benchmark vnet; same fallback. |
| `validation.debug.fail_in` / `-e odv_fail_in=<slug>` | unset | Induced-failure hook, see below. |
| `frontend_group` | `frontend` | Inventory group whose first host is the primary frontend (discovery + sweep host). |

### Induced-failure hook

Every test role guards a deliberate `fail:` with
`when: (odv_fail_in | d((validation.debug | d({})).fail_in | d(''))) == '<slug>'` — set
`-e odv_fail_in=<slug>` (or `validation.debug.fail_in`) to force that test into its
rescue/cleanup path. Existing slugs: `test_vm`, `storage_benchmark`, `conn_matrix`,
`network_validation`, `network_benchmark`, `vm_ha`, `fe_ha`, `ldap_auth`, `federation`,
`one_flow`, `core_services`, `gpu_benchmark`. `validation_common` itself has no slug.

### Naming convention

ONE objects created by the suite are named `odv-<test>-...` plus the cluster suffix
(`-<cluster>`, multi-cluster runs only), e.g. `odv-test-vm-<host>`, `odv-netval-<vnet>`,
`odv-storage-bench-<vnet>`. New roles must follow it: the sweep's stray hunt matches
`^(odv-|conn-mtx-vm-on-host|test_vm_ha|gpu-bench-)` to catch unmanifested survivors.

## API reference (entry points)

Call with `include_role: {name: validation_common, tasks_from: <file>}` and the listed vars.

| tasks_from | Inputs | Effect / registers |
|---|---|---|
| `main.yml` | — (runs automatically in play 1) | `hostname_cmd` on all hosts; on the primary frontend `one_clusters` (entries: `id`, `name`, `host_ids`, `image_ds_id`, `vnet_names`, `vnet_names_eligible`, `vnet_override`, `name_suffix`, `report_suffix`, `vnet_name`, `conn_matrix_vnet_name`, `storage_vnet_name`), `one_clusters_multi` (string — always use `\| bool`), `host_id_to_cluster`, `host_name_to_hostname_cmd`, `odv_discovery_failed`. |
| `manifest_add.yml` | `manifest_type` (`vm\|vnet\|image\|template\|service\|service_template\|vm_group\|file\|package\|process\|ip_addr\|host_state`), `manifest_name`, `manifest_role`; optional `manifest_id` (default `''`), `manifest_cluster` (`''`), `manifest_disposition` (`created`\|`reused`, default `created`) | Appends one row to the per-host `odv_manifest` fact and rewrites the `/tmp/odv_manifest.json` mirror. Call it immediately **before** creating the resource. |
| `record_result.yml` | `result_key`, `result_value`, optional `result_comment` | Merges into `verification_result` / `verification_comments` (the report's summary table). |
| `record_failure.yml` | `failure_key` (call inside `rescue:` only) | Records `<failure_key> = failed` with a comment extracted from `ansible_failed_task`/`ansible_failed_result`, truncated to 800 chars. |
| `record_leftover.yml` | `leftover_type`, `leftover_name`, `leftover_role`, optional `leftover_detail`, `leftover_host` | Appends to the per-host `odv_leftovers` fact (rendered red in the report's cleanup summary). |
| `terminate_vm_by_name.yml` | `tvbn_name` XOR `tvbn_regex` (matched against VM NAME), `tvbn_role`; optional `tvbn_retries` (10), `tvbn_delay` (10s), `tvbn_detail_suffix` | Name-anchored, state-independent cleanup for `always:` blocks: `onevm terminate --hard` with `recover --delete` fallback, polls until gone. Never aborts a play; sets `_tvbn_survivors` (`id:name` list, `[]` when clean) and records one leftover per survivor (or one row when the listing itself failed). |
| `install_packages_tracked.yml` | `pkg_names` (list), `pkg_role` | Installs packages one at a time and manifests **only** the ones this run actually installed (`changed`) — pre-installed packages are never swept. Install errors are tolerated. |
| `ensure_test_template.yml` | `ensure_app_name`, `ensure_name`, `ensure_ds_id`, `ensure_role`; optional `ensure_cluster`, `ensure_apply_extra` (default `true`) | Exports the marketplace app unless a template named `ensure_name` already exists (reuse path for air-gapped sites; a same-name image in another datastore is assumed not to occur thanks to per-cluster names). Manifests template + image with disposition `created` when the export ran, else `reused`. Applies `validation.test_vm.vm.template_extra` unless `ensure_apply_extra: false` (set false for non-generic templates, e.g. GPU appliances). Sets `_export_template_id`, `_export_image_id`. |
| `ensure_test_vnet.yml` | `ensure_vnet_cluster` (a `one_clusters` entry), `ensure_role` | Gated by `validation.test_vm.create_vnet`. Sets `_ensure_vnet_name` (= `validation.test_vm.vnet_name` + suffix), manifests it `created`/`reused`, creates or updates it from `test_vnet.j2`, assigns it to the cluster and removes it from cluster 0 (both steps skipped when the target cluster IS cluster 0 — new vnets already land there). |
| `export_marketapp.yml` | `_export_app_name`, `_export_name`, `_export_ds_id` | Low-level helper behind `ensure_test_template.yml` (no manifest rows) — prefer the wrapper. |
| `cluster_discovery.yml` / `host_map.yml` | — | Re-runnable pieces of `main.yml` (primary frontend only). |

Result-value convention for `record_result`: `ok` (or `ok - ...`) and the exact values
`reachable`/`active`/`enabled`/`running` (or a value containing `state=running`) render
PASS; strings containing `failed`/`error`/`unreachable`/`inactive`/`fault` render FAIL;
`warning`/`skipped`/`unknown`/` n/a` render WARN (`skipped` + `disabled` renders INFO);
anything else INFO. Classification runs on the value *plus* the comment text — see
`status_from` in `playbooks/templates/appendix-cloud-report.j2` for the full rules.

This role itself records only: `Cluster <name> validation = skipped (no hosts)` and, on
discovery failure, `Cluster discovery = failed`.

## Cleanup & failure behavior

The role creates almost nothing of its own — it is the bookkeeping that makes everyone else's
cleanup work. Manifest rows (`odv_manifest` + the `/tmp/odv_manifest.json` mirror on each
host that wrote one) are consumed twice: a pre-run sweep (`validation_sweep/preclean.yml`)
clears the *previous* run's unresolved leftovers, and the final `validation_sweep` play —
tagged `always`, so it runs regardless of failures — aggregates all hosts' manifests, dedupes
by (type, name) — plus host for the host-local types (`file`/`package`/`process`/`ip_addr`)
— and deletes every resource where any duplicate says `created`. All-`reused`
resources are kept (`kept (reused)`); images/templates are kept when
`validation.cleanup.keep_exported_images` is set (a `validation_sweep` option). After the
sweep the mirror is rewritten to hold only unresolved leftovers, so the next run retries them.

Resources ensured here map to manifest types: `ensure_test_template` → `template` + `image`;
`ensure_test_vnet` → `vnet`; `install_packages_tracked` → `package` (per-host).
`terminate_vm_by_name` and `record_leftover` feed `odv_leftovers` — a leftover means a
cleanup step **could not confirm** removal/restoration; it is reported (red row in the
report's Execution & Cleanup Summary) rather than silently ignored, and VM leftovers are
retried by the next run's preclean.
