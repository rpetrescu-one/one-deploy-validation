[//]: # ( vim: set wrap : )

# one-deploy-validation

This repository provides a toolset for automating the validation of an OpenNebula deployment.
A single `ansible-playbook` run executes every enabled test case against the target cloud,
cleans up everything it created, and produces an HTML/PDF report with a per-check verdict
(PASS / INFO / WARN / FAIL) and a full execution & cleanup audit trail.

## Test catalog

Each test case is implemented as an Ansible role. The table lists every test with its enabler
flag (set under the `validation:` dictionary in your inventory), its default in the
[reference inventory](./inventory/reference/group_vars/all.yml), and the tag that runs it in
isolation. Follow the links for the full per-role documentation: what is validated, all
supported options with defaults, examples, report output and cleanup behavior.

| Test case | Details | Enabler flag | Default | Tag |
|---|---|---|---|---|
| VM instantiation (template export, deploy, SSH) | [docs/test_vm](./docs/test_vm.md) | `validation.run_test_vm` | on | `test_vm` |
| Core Services (systemd units, host cycle, datastores) | [docs/validation](./docs/validation.md) | `validation.run_core_services` | on | `core_services` |
| Networking subsystem (per-vNet GW/DNS/external) | [docs/network_validation](./docs/network_validation.md) | `validation.networks_verification` | on | `network_validation` |
| Storage benchmark (fio in a test VM) | [docs/storage-benchmark](./docs/storage-benchmark.md) | `validation.run_storage_benchmark` | on | `storage_benchmark` |
| Network benchmark (host-to-host throughput) | [docs/network-benchmark](./docs/network-benchmark.md) | `validation.run_network_benchmark` | on | `network_benchmark` |
| OneFlow smoke test (service lifecycle) | [docs/oneflow_validation](./docs/oneflow_validation.md) | `validation.run_one_flow` | on | `one_flow` |
| Connectivity matrix (VM-to-VM across vNets) | [docs/conn_matrix](./docs/conn_matrix.md) | `validation.run_conn_matrix` | off | `conn_matrix` |
| LDAP authentication | [docs/ldap_auth](./docs/ldap_auth.md) | `validation.run_ldap_auth` | off | `ldap_auth` |
| VM High Availability (**destructive**: fences a host) | [docs/vm-ha](./docs/vm-ha.md) | `validation.run_vm_ha` | off | `vm_ha` |
| Front-end High Availability (leader failover) | [docs/fe_ha](./docs/fe_ha.md) | `validation.run_fe_ha` | off | `fe_ha` |
| Federation | [docs/federation](./docs/federation.md) | `validation.run_federation` | off | `federation` |
| GPU / LLM benchmark | [docs/gpu-benchmark](./docs/gpu-benchmark.md) | `validation.run_gpu_benchmark` | off | `gpu_benchmark` |

Suite internals (always active, not test cases):

| Component | Details | Purpose |
|---|---|---|
| Shared services & harness | [docs/validation_common](./docs/validation_common.md) | run manifest, result/leftover recording, shared template/vnet services, induced failures |
| Cleanup sweep & preclean | [docs/validation_sweep](./docs/validation_sweep.md) | pre-run leftover removal and the unconditional final cleanup sweep |

[docs/network-requirements.md](./docs/network-requirements.md) lists every external
endpoint the suite may contact (per source machine, with the config keys that avoid
each access) — the whitelist for environments with restricted internet access.

Tests are ordered so that destructive actions cannot poison other results: OneFlow runs
before Core Services (whose oned restarts destabilize an HA leader for minutes), and VM HA
runs last (a fenced, powered-off node must not fail the non-destructive checks).

## Requirements

We recommend using Ubuntu 22.04 or 24.04 as the host OS, where the validation is initiated.
The following packages must be installed on the host:

- `git`
- `python3`
- `python3-pip`
- `python3-venv`
- `make`

WeasyPrint (the final PDF rendering step) also needs the Pango/Cairo system libraries — on
a minimal Ubuntu server install them via
`apt install libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0`.

## Environment Setup

1. Clone the repository and move into its directory.
2. Create and activate a Python virtual environment:
```shell
   python3 -m venv .venv
   source .venv/bin/activate
```
3. Install required tools inside the virtual environment:
```shell
   python -m pip install hatch uv weasyprint
```
4. Install Ansible collections:
```shell
hatch env run -e validation-default -- ansible-galaxy collection install  -r requirements.yml -p ./collections
```

You may also use alternative virtual environment managers (such as pipx).
The key principle is: do not modify or replace system-level Python and/or Ansible packages. Keep everything isolated inside your project environment.

## Inventory/Execution

1. Inventories are kept in the [inventory](./inventory/) directory, please take a look at [example.yml](./inventory/reference/example.yml)

2. Customize the configuration of the validation testcases by setting the enabler flags (`validation.run_*` booleans) in [all.yml](./inventory/reference/group_vars/all.yml). This file contains the recommended configuration that should be tested on most deployments. Always intend to enable all testcases that are relevant for the deployment (for example, if VM HA or FE HA are configured, enable those testcases as well).
If any testcase is disabled compared to the current [all.yml](./inventory/reference/group_vars/all.yml), please provide justification in addition to the generated HTML reports.

3. Fill in the report details such as customer name, version, abstract etc.. in ./playbooks/report_input_vars.yml.example. Make a copy and reference that copy during the execution step. Without this vars file the report play prompts interactively for customer/version/abstract on a TTY — unattended runs must pass it.

4. To execute `ansible-playbook` using the example template you can run

   ```shell
   make I=inventory/reference/example.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
   ```
Ensure that your Python virtual environment is activated before running the playbook.

### Running a single test

Every test has a tag (see the [test catalog](#test-catalog)). A tag run executes only that
test plus the always-on plays (discovery, preclean, sweep, report):

```shell
make I=inventory/reference/example.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml -t vm_ha"
```

A tag run overwrites the report and labels it **PARTIAL RUN** (header and execution summary),
so a partial report can never be mistaken for a full validation.

### Testing the harness itself

`-e odv_fail_in=<slug>` makes one test fail on purpose so you can verify that the run still
completes, cleans up and reports honestly. The available slugs are listed in
[docs/validation_common.md](./docs/validation_common.md).
`make test` runs the suite's own regression harness locally (no cloud access needed).

## Multi-cluster deployments

The validation is cluster aware. Every OpenNebula cluster that has at least
one host is validated in a single run: tests that create VMs (test VM,
connectivity matrix, network validation, storage benchmark, VM HA, OneFlow,
GPU benchmark)
run once per cluster and only use that cluster's hosts, datastores and
virtual networks. Marketplace images are exported once per cluster (suffixed
with the cluster name when more than one cluster is validated) and report
entries are suffixed with ` — cluster <name>`.

Optional inventory settings (`validation.clusters`,
`validation.cluster_overrides`) restrict the cluster list or pin a specific
vnet/image datastore per cluster — see
`inventory/reference/group_vars/all.yml`.

## Validation Results

The execution of all the tests produces the following output files on the Ansible controller (e.g. laptop):

- `/tmp/cloud_verification_report_<inventory-dir>.html`
- `/tmp/cloud_verification_report_<inventory-dir>.pdf`

`<inventory-dir>` is the basename of the inventory's *directory*, not the inventory file
name — for `inventory/reference/example.yml` the files are
`/tmp/cloud_verification_report_reference.{html,pdf}`.
- `/tmp/conn-matrix-raw-data.json` (when connectivity matrix validation is enabled; HTML results are included in the main report)
- `/tmp/fe_ha_report.html` (when FE HA validation is enabled)

Report badges: **PASS** — the check succeeded; **INFO** — a recorded data point (e.g. a
hostname) or an intentional, configuration-driven skip; **WARN** — the check passed only
with caveats (e.g. a recovery that needed a nudge) or was skipped for a non-configuration
reason; **FAIL** — the check failed. The "Execution & Cleanup Summary" section lists every
test (enabled or not) and every resource the run created, with its fate.

## Cleanup guarantees

The suite always cleans up after itself: every resource it creates (VMs,
virtual networks, OneFlow services, exported marketplace images/templates,
temporary files, packages it installed) is registered in a run manifest and
removed by a final sweep play that runs regardless of test failures. The
report's "Execution & Cleanup Summary" section lists every resource and its
fate (removed / kept because it pre-existed / kept by
`validation.cleanup.keep_exported_images` / LEFTOVER needing manual action).
Tests keep running after individual failures; every test reports
`ok` / `failed` / `skipped — <reason>` in the report.

The one deliberately special case is the hypervisor fenced by the
(destructive, default-off) VM HA test: with
`validation.vm_ha.node_power_on_cmd` configured the node is powered back on,
cleaned and re-enabled automatically at the end of the test; without it the
node is left OFFLINE on purpose and the report carries the exact manual
recovery runbook. See [docs/vm-ha.md](./docs/vm-ha.md).
