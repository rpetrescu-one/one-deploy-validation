# Networking subsystem validation

Enabled by `validation.networks_verification` (default `true`). Play tag: `-t network_validation`.

## What it validates

For every eligible virtual network of every OpenNebula cluster (all
clusters with hosts, discovered automatically), the role instantiates a small test VM on that
vNET and verifies from inside the VM that basic networking works: the default gateway answers
ping, DNS resolves an external host name, and the external host itself is reachable by ping.
Each vNET gets its own row in the HTML verification report; one broken vNET does not stop the
test of the remaining ones.

## How it works

1. The play runs on the frontend group; the role is enabled by `validation.networks_verification`
   (skipped entirely in the gpu-benchmark pre-deploy phase). If cluster discovery failed, it only
   records `Network validation = skipped — cluster discovery failed` and stops.
2. Per cluster, vNETs are queried live (`onevnet list -j`), so vNETs created earlier in the same
   run are covered too. A vNET is excluded when its name is in `validation.network.skip_vnets`,
   or when `validation.network.require_ip_ar` is true (default) and it has no IP4/IP6 address
   range (ETHER-only/AR-less vNETs assign just a MAC; the check cannot know the DHCP-given IP).
3. The test VM template is ensured via the shared `validation_common/ensure_test_template.yml`
   service: the marketplace app is exported when the template is missing, reused when it
   pre-exists, template and image are registered in the run manifest, and
   `validation.test_vm.vm.template_extra` (CONTEXT with the SSH key etc.) is applied.
4. Per eligible vNET: the VM (`odv-netval-<vnet><cluster suffix>`) is registered in the manifest,
   instantiated with `--nic <vnet>`, polled until RUNNING (10 x 10 s), then reached over ssh
   (retried 30 x 20 s). Inside it, `bind-tools`, `jq` and `jc` are installed (Alpine `apk`), then:
   gateway ping (10 packets, gateway taken from the VM's default route), `dig` of
   `validation.network.ext_host`, and ping of that host (3 packets). The vNET's report row is
   saved immediately, and the VM is terminated.
5. A per-vNET failure marks only that vNET's row as failed (with a truncated error detail) and
   the loop continues; the cluster's summary row then reads `failed` with the failed-vNET list.
6. An `always:` sweep terminates every surviving `odv-netval-*<cluster suffix>` VM by name
   pattern; VMs it cannot remove are recorded as leftovers.

## Requirements

- ICMP must be allowed on the infrastructure — gateway and external reachability are ping-based.
- Each tested vNET must give the VM a working IP config: reachable gateway, a DNS server able to
  resolve `ext_host`, and outbound internet access (the checks target an external host, and the
  Alpine VM installs packages with `apk` at test time).
- The frontend must reach the test VM's IP over ssh as `root` using `~oneadmin/.ssh/id_rsa`; the
  template CONTEXT must inject the matching public key (`SSH_PUBLIC_KEY="$USER[SSH_PUBLIC_KEY]"`
  via `validation.test_vm.vm.template_extra`, applied automatically by the shared template service).
- Marketplace access to export the test app (default `Alpine Linux 3.21`) — not needed when a
  template/image of that name already exists (it is then reused and never deleted).
- `jq` on the frontend (used by the vNET query); the OpenNebula CLI must work for `root` on the
  frontend (the shared template/cleanup services additionally run it as `oneadmin`).

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.networks_verification` | `true` | Enables the role (play-level gate). |
| `validation.network.ext_host` | — (required; reference inventory: `google.com`) | External host used for the DNS-resolution and external-ping checks. |
| `validation.network.skip_vnets` | `[]` | vNET names to exclude from testing. |
| `validation.network.require_ip_ar` | `true` | Skip vNETs without an IP4/IP6 address range. Set `false` to also test ETHER-only vNETs (only works if the VM still gets an observable IP). |
| `validation.test_vm.vm.market_name` | `Alpine Linux 3.21` | Marketplace app exported as the test VM template (shared with the other VM-based tests). |
| `validation.test_vm.vm.template_extra` | unset (reference inventory sets CONTEXT + sizing) | Raw template attributes appended to the ensured template; must provide the SSH public key CONTEXT for the ssh-based checks. |
| `validation.debug.fail_in` / `-e odv_fail_in=...` | `''` | Induced-failure hook: slug `network_validation` forces a failure inside the harness for testing. |
| `frontend_group` | `frontend` | Inventory group of the frontends; single-execution steps are gated to its first host. |

## Example

```yaml
all:
  vars:
    validation:
      networks_verification: true
      network:
        ext_host: 'google.com'
        # skip_vnets: [storage-only-vlan]
        # require_ip_ar: true
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```sh
make I=<inventory>.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (cluster discovery, cleanup sweep and report are tagged `always` and still run):

```sh
hatch env run -e validation-default -- ansible-playbook -i <inventory>.yml \
  -t network_validation playbooks/validation.yml
```

## Report output

Summary-check rows (via `verification_result`); the key gets a ` — cluster <name>` suffix on
multi-cluster inventories:

- `Network validation` — `skipped — cluster discovery failed` (FAIL — the word "failed" in the value trips the report's fail classifier before its skipped→WARN branch) when discovery failed.
- `Network validation[ — cluster <name>]` — `ok` (PASS) when every tested vNET passed;
  `skipped — no eligible vNETs` (WARN); `failed` (FAIL) with the failed-vNET list or the
  harness error detail as a NOTE comment.

Per-vNET table rows (fact `network_verification_results`, rendered as "Virtual Networks
Validation"); keys are prefixed `<cluster>/` on multi-cluster inventories:

- `<vnet>` — on success: `Test VM IP` plus the `jc`-JSON outputs of the gateway ping, external
  host ping and DNS resolution. Renders PASS when the ping JSON shows `packet_loss_percent: 0.0`.
- `<vnet>` — on failure: `Result: failed` plus a truncated `Detail` (FAIL).
- `<cluster>/networks` — `Result: skipped (no eligible vNETs)` (WARN).
- `<cluster>/validation` — `Result: failed` (FAIL) when the cluster's harness itself failed.

## Cleanup & failure behavior

Resources are registered in the run manifest (`odv_manifest`, mirrored to
`/tmp/odv_manifest.json`) *before* creation: each test VM (type `vm`, disposition `created`) and
the ensured template/image (types `template`/`image`, `created` when exported, `reused` when
pre-existing). Each VM is terminated right after its vNET's checks; independent of that, the
per-cluster `always:` block sweeps all `odv-netval-*<cluster suffix>` VMs by name pattern
(`terminate --hard`, falling back to `recover --delete`, polling until gone). The suite's final
sweep play (tagged `always`) removes the remaining manifest-registered resources — `reused` ones
are never touched, and exported images can be kept with `validation.cleanup.keep_exported_images`.
Anything that survives is recorded in `odv_leftovers` and shown in the report's "Execution &
Cleanup Summary"; unresolved leftovers are retried by the pre-run sweep of the next run.
