# Connectivity matrix

Enabled by `validation.run_conn_matrix` (default `false`). Play tag: `-t conn_matrix`.

## What it validates

Full VM-to-VM reachability across the deployment: one test VM is pinned to every
hypervisor host registered in OpenNebula, and every VM pings every other VM in the
same cluster over the configured virtual network. The result is a packet-loss
matrix that proves (or disproves) that the vNet fabric actually carries traffic
between all host pairs — per cluster, in multi-cluster deployments.

## How it works

The role runs in a single play spanning the `node` and `frontend` groups
(`playbooks/validation.yml`); tasks are routed internally to the node hosts or the
primary frontend. If cluster discovery (from `validation_common`) failed, the test
self-skips and records `Connectivity matrix: skipped — cluster discovery failed`.

1. Each node host generates a dedicated SSH key pair (`~/.ssh/conn-matrix`); the
   primary frontend collects all public keys.
2. The frontend ensures the test template/image exists in every validated cluster
   (marketplace export via `validation_common/ensure_test_template.yml`, reused if
   already registered) and, per OpenNebula host, creates a VM group
   `only-host-<id>` (`HOST_AFFINED`) plus a VM `conn-mtx-vm-on-host-<id>` on the
   cluster's resolved conn-matrix vNet, with the node's public key, `NETWORK`,
   `REPORT_READY` and `TOKEN` in the CONTEXT. It waits for `runn` state
   (10 × 10 s). A failing host records its own report key and the loop continues.
3. The frontend builds host → VM-IP and host → cluster maps.
4. Each node host installs `jc`/`jq` (tracked), adds a helper `/32` source address
   (its VM IP offset by the VM count) and a `/32` route to its own VM on the
   configured bridge, SSHes into its VM as root, and pings every other
   same-cluster VM `ping_count` times; each result is parsed with `jc --ping` into
   `/tmp/conn-matrix-results/<src>/<dst>.json`.
5. The frontend folds all per-node vectors into `conn_results_matrix`; the raw
   data is written to `/tmp/conn-matrix-raw-data.json` on the Ansible controller
   and the HTML matrix is embedded in the main verification report.

## Requirements

- The VM CONTEXT sets `TOKEN`/`REPORT_READY`, so the guest will try to contact
  OneGate — but no check consumes it: the test only waits for `RUNNING` state and
  uses direct SSH, so an unreachable `ONEGATE_ENDPOINT` at most makes the
  in-guest context reporting fail.
- A marketplace app named `validation.conn_matrix.market_name` reachable from the
  frontend, or a pre-registered template/image of the same name (then it is
  reused and never deleted). The exported template additionally receives the
  suite-wide `validation.test_vm.vm.template_extra` (the shared
  `ensure_test_template` service applies it for every consumer); the per-VM SSH
  key/`NETWORK`/`REPORT_READY`/`TOKEN` CONTEXT is passed at instantiate time via
  `--raw`.
- The vNet used by the VMs must ride the bridge named in
  `validation.conn_matrix.bridge_name` on every hypervisor, and the vNet needs an
  IP4/IP6 address range (AR-less/ETHER-only vNets are not auto-selected).
- ICMP allowed between VMs, and SSH from each hypervisor to its local VM.
- Every inventory node must be a registered OpenNebula host whose monitored
  `HOSTNAME` matches the node's `hostname` output (the role keys its maps on it).
- Root privileges on the nodes (`ip addr/route`, package install) and `oneadmin`
  CLI access on the frontend.

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_conn_matrix` | `false` | Enable the test. |
| `validation.conn_matrix.market_name` | — (required, no code default; reference inventory: `Alpine Linux 3.21`) | Marketplace app / template name used for the test VMs (suffixed per cluster in multi-cluster setups). |
| `validation.conn_matrix.vnet_name` | `vnet-default` (reference inventory: `public`) | Preferred vNet for the VMs. Read by cluster discovery: per cluster it is used when eligible there, otherwise the cluster's primary test vNet; a `validation.cluster_overrides.<name>.vnet_name` wins over both. |
| `validation.conn_matrix.bridge_name` | `br-conn-matrix` (reference inventory: `br0`) | Bridge device on each hypervisor where the helper `/32` address and route are added to reach the local VM. |
| `validation.conn_matrix.ping_count` | `3` (reference inventory: `10`) | Pings per VM pair. |
| `validation.debug.fail_in` (or `-e odv_fail_in=conn_matrix`) | `''` | Induced-failure hook: slug `conn_matrix` makes the block fail on entry to exercise the rescue/cleanup path. |

Group names come from the suite-wide `frontend_group` / `node_group` variables
(defaults `frontend` / `node`).

## Example

```yaml
all:
  vars:
    validation:
      run_conn_matrix: true
      conn_matrix:
        bridge_name: br0
        ping_count: 10
        vnet_name: public
        market_name: 'Alpine Linux 3.21'
```

Full suite (report prompts pre-answered from a vars file — copy
`playbooks/report_input_vars.yml.example` first):

```sh
make I=inventory/myclod.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (the `always`-tagged discovery, sweep and report plays still run):

```sh
make I=inventory/myclod.yml T=conn_matrix validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
# or directly:
hatch env run -e validation-default -- ansible-playbook -i inventory/myclod.yml \
  -t conn_matrix -e @playbooks/report_input_vars.yml playbooks/validation.yml
```

## Report output

Keys recorded in `verification_result` (summary checks table):

- `Connectivity matrix` — `ok` (PASS) when no host failed; `failed` (FAIL) with a
  comment naming the failed hosts, or with the extracted error detail when the
  frontend side failed; `skipped — cluster discovery failed` when discovery broke.
- `Connectivity matrix VM creation (host id <N>)` — `failed` (FAIL) per host whose
  VM could not be created; this does **not** block an overall `ok` (the matrix
  simply misses that host).

The report also renders the matrix itself as a single From/To table of
packet-loss percentages spanning ALL node hosts across clusters, while pings
only run between same-cluster VMs — so on a multi-cluster deployment every
cross-cluster cell renders "missing" and the badge is capped at WARN. Badge
logic: PASS when every off-diagonal cell exists with 0.0 % loss (only
reachable when all node hosts are in one cluster), WARN when cells are
missing, FAIL on any loss or an empty matrix. Raw data stays in
`/tmp/conn-matrix-raw-data.json` on the controller.

## Cleanup & failure behavior

Everything the role creates is registered in the per-host run manifest
(`odv_manifest`): SSH key pair and results directory (`file`), the bridge address
and route (`ip_addr`, `"<cidr>:dev:<bridge>"` format) and the VM
`conn-mtx-vm-on-host-<id>` (`vm`) *before* creation; `only-host-<id>`
(`vm_group`), the exported template/image (`template`/`image`, `created` or
`reused`) and any `jc`/`jq` package this run actually installed (`package`) are
registered immediately after their create step, since their disposition depends
on its outcome.

The test body runs in a block/rescue/always harness. A node-side failure raises a
flag the frontend reads in `always`; a frontend failure is recorded with detail
via `record_failure`. Cleanup runs in `always` on both host kinds and is
state-independent — it re-derives everything from live state plus the manifest,
so it also works standalone: nodes remove the key pair, results directory and the
manifest-recorded `/32` addresses/routes from the bridge; the frontend terminates
`conn-mtx-vm-on-host-*` VMs regardless of their state (`terminate --hard`,
fallback `recover --delete`, polled until gone), deletes the `only-host-*` VM
groups and the rendered `/tmp` template files. A second net sweeps VMs matching
`^conn-mtx-vm-on-host` whose host id vanished. Nothing in cleanup can abort the
run: anything that cannot be removed becomes an `odv_leftovers` row (shown in the
report's Execution & Cleanup Summary). Template/image are never deleted by the
role itself — the end-of-run sweep play removes `disposition=created` manifest
entries and keeps `reused` ones, and the pre-run sweep clears leftover conn-mtx
VMs from a previous crashed run.
