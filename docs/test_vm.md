# VM instantiation test

Enabled by `validation.run_test_vm` (default `true`). Play tag: `-t test_vm`.

## What it validates

Proves the basic VM lifecycle works on every OpenNebula cluster that has hosts: a template can
be exported from the marketplace (or an existing one reused), a test network can be created (or
an existing one reused), a VM instantiates from that template, reaches `RUNNING`, and answers on
the network. On multi-frontend (HA) inventories each frontend instantiates its own test VM, so
the check also exercises every frontend's CLI path to oned.

## How it works

Runs on all hosts of the frontend group, looping over every discovered cluster
(report keys get a ` — cluster <name>` suffix when more than one cluster is validated):

1. **Prepare** (primary frontend only): includes the shared service
   `validation_common/tasks/ensure_test_template.yml`, which exports the marketplace app
   `validation.test_vm.vm.market_name` to the cluster's image datastore — skipped when a
   template with the target name already exists (semi air-gapped reuse) — registers template and
   image in the run manifest, and appends `validation.test_vm.vm.template_extra` to the template
   (`onetemplate update --append`, idempotent). Per-cluster template/image ID maps are stored as
   facts for other roles.
2. **Network**: each frontend pings the test network gateway (only when both
   `validation.test_vm.create_vnet` and `validation.test_vm.vm.check_connection` are true); the
   primary frontend then includes the shared `validation_common/tasks/ensure_test_vnet.yml`,
   which creates or updates the vnet from `validation.test_vm.vnet.*`, assigns it to the
   cluster, and registers it in the manifest. With `create_vnet: false` the whole sub-check is
   skipped and the cluster's existing vnet (`validation.test_vm.vnet_name`) is reused.
3. **Instantiate** (every frontend): waits for the exported image to be `rdy`/`used`, registers
   the VM name in the manifest *before* creating it, then runs `onetemplate instantiate` with
   `--nic <cluster vnet>` (anchors scheduling to the cluster) and
   `--name odv-test-vm-<frontend-host><cluster-suffix>`, and polls until the VM is `runn`.
4. **Connect** (when `check_connection`): resolves the active HA leader, the leader attaches a
   NIC, each frontend fetches the VM IP and pings it, then probes `onegate vm show` over SSH as
   `oneadmin` (informational only — its failure does not fail the test).

Other tests (storage-benchmark, oneflow, ...) provision the same template and vnet through the
shared `ensure_*` services, so **disabling this test does not break them** — and because
`template_extra` is applied inside `ensure_test_template.yml`, every consumer gets it even when
`run_test_vm` is `false`.

## Requirements

- OpenNebula CLI tools and the `oneadmin` user on the frontends; `jq` installed there.
- Marketplace reachability from the frontend — unless a VM template named after
  `validation.test_vm.vm.market_name` (plus cluster suffix) is pre-registered, in which case the
  export is skipped and the template is reused.
- With `create_vnet: true`: the bridge/physical device referenced by `validation.test_vm.vnet.*`
  must exist on the hypervisors, and the configured gateway must answer ICMP from the frontends.
- With `create_vnet: false`: each validated cluster must contain at least one eligible vnet
  (owning an IP4/IP6 address range and not listed in `validation.network.skip_vnets`); discovery
  prefers the vnet named `validation.test_vm.vnet_name` and falls back to the cluster's first
  eligible vnet (or set `validation.cluster_overrides.<cluster>.vnet_name` to force one).
- With `check_connection: true`: ICMP from the frontends to the VM's address range, and a
  template CONTEXT that injects `$USER[SSH_PUBLIC_KEY]` (the default `template_extra` does) for
  the onegate SSH probe.

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_test_vm` | `true` | Enable/disable the whole test. |
| `validation.test_vm.vm.market_name` | `Alpine Linux 3.21` | Marketplace app to export; also the template/image name (cluster suffix appended). |
| `validation.test_vm.vm.check_connection` | `true` | Attach NIC, ping the VM and run the onegate probe. `false` also skips the gateway ping and records the connection row as skipped. |
| `validation.test_vm.vm.template_extra` | `MEMORY="256"` + CONTEXT block (reference inventory: `MEMORY="512"` + CONTEXT) | Raw template text appended to the exported template inside the shared `ensure_test_template` service — applies to every test that uses the template, not only this one. |
| `validation.test_vm.create_vnet` | `true` (reference inventory: `false`) | Create/update the test vnet. When `false`, the vnet in `validation.test_vm.vnet_name` is reused and the "Test network creation" row reads `skipped — create_vnet disabled` (rendered INFO). |
| `validation.test_vm.vnet_name` | `VLAN_580` (reference inventory: `public`) | Name of the vnet to create or reuse; cluster discovery prefers it when picking each cluster's test vnet. |
| `validation.test_vm.vnet.desc` | `A test network for post-deployment cloud verification` | Vnet description (only used when `create_vnet: true`, as are all `vnet.*` keys below). |
| `validation.test_vm.vnet.vn_mad` | `bridge` | Virtual network driver. |
| `validation.test_vm.vnet.bridge` | `br-test` | Bridge name; omitted from the vnet template when set to `null`. |
| `validation.test_vm.vnet.phydev` | `eth1` | Physical device; omitted when `null` (reference inventory: `''`). |
| `validation.test_vm.vnet.network_address` | `10.0.0.0` | Network address. |
| `validation.test_vm.vnet.network_mask` | `255.255.255.0` | Network mask. |
| `validation.test_vm.vnet.dns` | `8.8.8.8` | DNS server for the vnet. |
| `validation.test_vm.vnet.gateway` | `10.0.0.254` | Gateway; must answer ping from the frontends. |
| `validation.test_vm.vnet.ar` | one `IP4` range, `10.0.0.10` size `10` | Address ranges (`type`/`ip`/`size` each). |
| `validation.cluster_overrides.<cluster>.vnet_name` | auto-discovered | Forces the vnet used for the VM's NIC on that cluster. |
| `validation.cleanup.keep_exported_images` | `false` | Final sweep keeps the exported template/image (`kept (by flag)`). |
| `validation.debug.fail_in` / `-e odv_fail_in=<slug>` | unset | Slug `test_vm` induces a failure at the start of the block to exercise the rescue/cleanup path. |

## Example

```yaml
all:
  vars:
    validation:
      run_test_vm: true
      test_vm:
        create_vnet: false        # reuse an existing network
        vnet_name: public
        vm:
          check_connection: true
          market_name: 'Alpine Linux 3.21'
```

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```shell
# full suite
make validation I=inventory/<env>/hosts.yaml ANSIBLE_ARGS='-e @playbooks/report_input_vars.yml'

# this test only (plays tagged `always` — discovery, cleanup sweep, report — still run)
hatch env run -e validation-default -- \
  ansible-playbook -i inventory/<env>/hosts.yaml -t test_vm playbooks/validation.yml
```

## Report output

Keys recorded into the summary checks table (suffixed with ` — cluster <name>` in multi-cluster runs):

| Key | Values |
|---|---|
| `Download a test VM template from the marketplace` | `ok` (PASS) when the export ran; `skipped — template pre-exists, marketplace not used` (WARN). |
| `Updating a VM template` | `ok` (PASS); `skipped — no template_extra defined` (WARN). |
| `Test network creation` | `ok` (PASS); `skipped — create_vnet disabled, reusing vnet <name>` (INFO). |
| `Test VM instantiation` | `ok` (PASS); absent if the flow failed earlier. |
| `Connection to the test VM instance` | `ok` (PASS); `skipped — validation.test_vm.vm.check_connection is false` (WARN). |
| `Test VM validation` | Only on error: `failed` (FAIL, with a truncated error detail as comment) from the rescue, or `skipped — cluster discovery failed` (rendered FAIL) when discovery produced no clusters. |

In general `ok` renders PASS, `failed` renders FAIL, skip reasons containing "disabled" render
INFO, and other `skipped — ...` reasons render WARN.

## Cleanup & failure behavior

Resources created and their manifest entries (`type` / disposition):

- One VM per frontend host, `odv-test-vm-<frontend-host><cluster-suffix>` — `vm` / `created`.
- Exported template and image per cluster — `template` + `image` / `created`, or `reused` when
  the template pre-existed.
- The test vnet — `vnet` / `created`, or `reused` when it already existed (never registered when
  `create_vnet: false`).

On any failure inside the per-cluster block, the rescue records
`Test VM validation<suffix> = failed` and the loop continues with the next cluster — the suite
is not aborted. An `always:` section then runs regardless of outcome: it re-discovers this
host's VM by its deterministic name and terminates it (`terminate --hard`, falling back to
`recover --delete`, polling until gone), and removes rendered temp files
(`/var/tmp/vnet_*.template`); the template-extra scratch file (`/tmp/odv_template_extra.txt`)
is removed by the shared `ensure_test_template` service itself (leaked only if the template
update fails mid-way). A VM that survives termination is
recorded as an `odv_leftovers` row (`terminate did not converge`) and shows up as a leftover in
the report's Execution & Cleanup Summary.

Independently, the suite-final sweep play (tagged `always`) deletes every manifest resource with
disposition `created` — including the template, image and vnet — and reports each as
`removed`/`leftover`; `reused` resources are always kept (`kept (reused)`), and
`validation.cleanup.keep_exported_images: true` keeps the exported template/image. A pre-run
sweep also clears leftovers of a previous run before this test starts.
