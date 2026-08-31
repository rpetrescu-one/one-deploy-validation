# Storage benchmark

Enabled by `validation.run_storage_benchmark` (default `true`). Play tag: `-t storage_benchmark`.

## What it validates

Measures the storage performance an actual guest sees on each validated cluster: the role
instantiates a benchmark VM per (cluster, template) pair, runs a fixed fio job suite
(random/sequential/mixed/sync profiles at several queue depths) against the VM's disk, and
renders IOPS, bandwidth and p99 latency per job — with a coarse star score — into the HTML
verification report. It is a measurement, not a pass/fail threshold check: the test itself
only fails on infrastructure errors (VM never runs, ssh unreachable, fio fails).

## How it works

All tasks run on the primary frontend (first host of the `frontend` group), once per
cluster discovered by `validation_common` and per configured template:

1. Resolve naming facts: report key `Storage benchmark (<template>)` (plus
   ` — cluster <name>` in multi-cluster runs) and the deterministic VM name
   `odv-storage-bench-<template-slug><cluster-suffix>`.
2. Default template (the `test_vm` marketplace app): reuse the image the `test_vm` role
   already exported for this cluster; otherwise export/reuse it via the shared
   `validation_common/ensure_test_template.yml` (idempotent, registers template + image in
   the run manifest, applies `validation.test_vm.vm.template_extra` — the CONTEXT with the
   SSH key). Non-default templates must pre-exist as `<template><cluster-suffix>`; a
   missing one records `skipped — template not found` for that pair.
3. Register the VM name in the run manifest, then instantiate the template with
   `--nic <storage vnet> --disk <image>:size=8000 --mem 1g` and wait for state `runn`.
4. Wait for root ssh into the VM (oneadmin's `~/.ssh/id_rsa`), set public DNS resolvers
   and `apk add fio` (both skipped with `skip_fio_install: true`).
5. Run the fio suite (`--output-format=json`) against a 4 GiB test file
   (`/tmp/onebench.testfile`, `direct=1`, `ioengine=libaio`, 5 s ramp + 5 s runtime per
   job, jobs serialized with `stonewall`, p99 latency percentiles).
6. Parse the JSON into the `storage_benchmark` fact, record `ok`, and always terminate the
   benchmark VM by name.

## Requirements

- At least one discovered cluster with an image datastore and a usable vnet (asserted by
  the shared cluster discovery).
- The resolved vnet must give the VM an IP reachable from the frontend, and by default
  public internet egress (fio is installed with `apk` from the Alpine mirrors). Semi
  air-gapped sites: use an image with fio preinstalled and set `skip_fio_install: true`.
- Root ssh into the VM using oneadmin's key — the default template gets this via
  `validation.test_vm.vm.template_extra` (SSH_PUBLIC_KEY in CONTEXT); custom templates
  must provide it themselves. The fio install path assumes an Alpine guest (`apk`).
- Space for the benchmark disk: the image is resized to 8000 MB at instantiation.

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_storage_benchmark` | `true` | Enable/disable the test (also gates the role in `playbooks/validation.yml`). |
| `validation.storage_benchmark.vnet_name` | `VLAN_580` (reference inventory: `public`) | Preferred vnet for the benchmark VM's NIC. Used when a vnet with this name exists (and is eligible) in the cluster; otherwise the cluster's resolved primary vnet is used. A `validation.cluster_overrides.<cluster>.vnet_name` override wins unconditionally. |
| `validation.storage_benchmark.templates` | `[<default template>]` | List of VM template names to benchmark per cluster. The default entry is `validation.test_vm.vm.market_name` (falls back to `Alpine Linux 3.21`) and is exported from the marketplace when needed; any extra entry must already exist as `<template><cluster-suffix>`. |
| `validation.storage_benchmark.skip_fio_install` | `false` | Skip setting DNS and installing fio inside the VM — for images that ship fio preinstalled. |
| `validation.debug.fail_in` / `-e odv_fail_in=storage_benchmark` | unset | Induced-failure hook: makes the test block fail on entry to exercise the rescue/cleanup path. |

## Example

```yaml
all:
  vars:
    validation:
      run_storage_benchmark: true
      storage_benchmark:
        vnet_name: public
        # templates: ['Alpine Linux 3.21', 'my-ceph-tuned-template']
        # skip_fio_install: true   # image ships fio (semi air-gapped)
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```shell
make I=inventory/<env>/hosts.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (cleanup sweep and report plays are tagged `always` and still run):

```shell
make I=inventory/<env>/hosts.yml T=storage_benchmark validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
# or directly:
hatch env run -e validation-default -- ansible-playbook -i inventory/<env>/hosts.yml \
  -t storage_benchmark -e @playbooks/report_input_vars.yml playbooks/validation.yml
```

## Report output

Summary-table keys (`verification_result`):

- `Storage benchmark (<template>)[ — cluster <name>]` — `ok`, `failed` (with a truncated
  error detail as a comment), or `skipped — template not found`.
- `Storage benchmark` — `skipped — cluster discovery failed` when discovery itself failed.

In the execution summary, `ok` renders OK (PASS), `failed` renders FAILED, `skipped — …`
renders SKIPPED; no recorded key shows NO RESULT RECORDED.

The "Storage Benchmarking Results" section renders one table per
`<frontend host> (<template>)[ — cluster <name>]` entry of the `storage_benchmark` fact.
Rows are fio **job names, not errors**: `rr`/`rw` = random read/write, `seqr`/`seqw` =
sequential read/write, `mix_*_70r` = 70/30 read/write mix, `syncwrite` = write with end-of-job fsync;
`_4k`/`_64k`/`_128k`/`_1m` is the block size and `qdN` the iodepth — e.g. `rr_4k_qd1` is
random 4k read at queue depth 1. Full set: `rr_4k_qd{1,4,16,32,64}`,
`rw_4k_qd{1,4,16,32,64}`, `mix_4k_70r_qd16`, `mix_64k_70r_qd16`, `seqr_128k_qd16`,
`seqr_1m_qd4`, `seqw_128k_qd16`, `seqw_1m_qd4`, `syncwrite_4k_qd1`.

Each row shows IOPS, bandwidth and p99 latency (mixed jobs sum read+write and take the
worse p99) plus a hard-coded star score from the report template: sequential (`seq*`) jobs
by bandwidth — ★★★ ≥ 300 MB/s, ★★ ≥ 150, ★ ≥ 75, ⚠ below; all other jobs by p99 latency —
★★★ ≤ 5 ms, ★★ ≤ 10 ms, ★ ≤ 20 ms, ⚠ above. The score is informational only; it never
turns the summary row into WARN/FAIL.

## Cleanup & failure behavior

- **Manifest**: the VM name is registered (`type: vm`, role `storage-benchmark`) before
  instantiation; a template/image exported by the role is registered by
  `ensure_test_template.yml` (`created` when exported this run, `reused` when pre-existing).
- **always:** the role terminates every VM named `odv-storage-bench-…` for the pair via the
  shared `terminate_vm_by_name.yml` — state-independent (finds the VM by name, not by
  registered variables), tolerant, with a 30-retry gone-wait. A VM that survives is
  recorded as an `odv_leftovers` row (rendered red LEFTOVER in the report).
- **rescue:** records `failed` plus the failing task's message, then the run continues
  with the next (cluster, template) pair — the suite is run-to-completion.
- Exported templates/images are deleted by the end-of-run sweep unless they were `reused`
  or `validation.cleanup.keep_exported_images: true` keeps them; a skipped pair created
  nothing, so its rescue/always do nothing.
