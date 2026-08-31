# Network benchmark

Enabled by `validation.run_network_benchmark` (default `true`). Play tag: `-t network_benchmark`.

## What it validates

Measures the raw network quality of the hypervisor interconnect: from every
host in the `node` inventory group it runs a ping RTT test and an iperf3 TCP
throughput test against **every other** node host (a full N×(N−1) directed
mesh over the hosts' `ansible_host` addresses). The numbers are informational
— there are no pass/fail thresholds on RTT or throughput; the check fails only
when a measurement itself cannot be completed (unreachable peer, blocked port,
iperf3 error, a dependency missing at measurement time — a failed package
install by itself is tolerated).

## How it works

1. The play runs on all hosts of the node group (tag `network_benchmark`);
   it is skipped entirely on `gpu_benchmark_phase=pre` baseline runs.
2. On each node, the dependencies `jc`, `jq` and `iperf3` are installed via
   the shared `validation_common/install_packages_tracked.yml` primitive
   (apt cache refreshed first on Debian). Only packages that were *actually
   installed by this run* are registered in the cleanup manifest.
3. Ping: `ping -c 10 <peer>` to every other node host; the average RTT is
   extracted with `jc --ping | jq .round_trip_ms_avg`.
4. iperf3 server: if no `iperf3 -s -p <port>` is already running, one is
   started in the background (registered in the manifest as process
   `iperf3:<port>` *before* starting, and marked "started by us"); a
   pre-existing server is reused and never touched. The role waits up to 30 s
   for the port.
5. iperf3 client: `iperf3 -c <peer> -p <port> -t <time> -J` against every
   other node host, reading `end.sum_sent.bits_per_second` (sender-side).
   Client runs are throttled to one host at a time so concurrent tests never
   share the links being measured.
6. On success the role records `Network benchmark on <host> = ok`; a rescue
   block records `failed` plus a truncated error detail instead of aborting
   the suite. The `always` block kills the iperf3 server — only when this run
   started it.

## Requirements

- At least two hosts in the node group (with one host the loops are empty and
  the check trivially records `ok`).
- `ansible_host` set to an address reachable from the other nodes; ICMP and
  TCP on the iperf3 port (default 5201) allowed between all node hosts.
- Package repository access on the nodes to install `jc`, `jq`, `iperf3`
  (skipped for packages already present).

## Configuration

| Option | Default | Description |
|---|---|---|
| `validation.run_network_benchmark` | `true` (code and reference inventory) | Enable/disable the test. |
| `validation.network_benchmark.iperf_port` | `5201` (reference inventory: `5201`) | TCP port the iperf3 server listens on and clients connect to. |
| `validation.network_benchmark.iperf_test_time` | `10` (reference inventory: `10`) | Duration in seconds of each iperf3 client run (`-t`). |
| `node_group` | `node` | Suite-wide inventory group name for the hypervisor hosts the mesh is built from. |
| `validation.debug.fail_in` / `-e odv_fail_in=network_benchmark` | unset | Debug hook: force a failure at the top of the block to exercise the rescue/cleanup harness. |

## Example

Minimal inventory `group_vars/all.yml` fragment:

```yaml
validation:
  run_network_benchmark: true
  network_benchmark:
    iperf_port: 5201
    iperf_test_time: 10
```

Full suite (report variables included):

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```bash
make validation I=inventory/<env>/hosts.yaml \
  ANSIBLE_ARGS='-e @playbooks/report_input_vars.yml'
```

Only this test (the cleanup sweep and report plays are tagged `always` and
still run):

```bash
hatch env run -e validation-default -- ansible-playbook \
  -i inventory/<env>/hosts.yaml -t network_benchmark playbooks/validation.yml
```

## Report output

- `Network benchmark on <inventory_hostname>` — one row per node host in the
  verification results table. `ok` (PASS) means every ping and every iperf3
  run against every peer completed; `failed` (FAIL) means any step errored,
  with the failing task and message attached as a comment. There are no WARN
  or INFO outcomes; measured values never fail the check by themselves.
- The summary's *Test execution* table shows the worst of these rows under
  the "Network benchmark" label (OK / FAILED / NO RESULT RECORDED).
- The raw per-host `iperf_results` and `ping_exec` registers are collected
  from the node hosts into a `network_benchmark` map and rendered in the
  report's **Network Benchmarking Results** section: a throughput table
  (client host → server, Mbps, sender-side `sum_sent`) and a ping table
  (source → destination, average RTT in ms over 10 pings).

## Cleanup & failure behavior

Resources this role creates, and how they are cleaned:

- **iperf3 server process** — manifest type `process`, name `iperf3:<port>`,
  registered immediately *before* the server is started. The role's `always`
  block kills it at the end of the test (success or failure), but only when
  this run started it; a pre-existing server is reused and never killed nor
  registered. If the kill itself errors (pkill rc > 1), the role records an
  `odv_leftovers` row so the report flags it as LEFTOVER. The final
  unconditional sweep play also matches `process` manifest entries and kills
  any surviving `iperf3 -s -p <port>`.
- **Packages** (`jc`, `jq`, `iperf3`) — manifest type `package`, one entry
  per package this run newly installed (pre-installed packages are never
  registered, so the sweep never uninstalls them). The final sweep removes
  the registered ones and records removed/leftover rows in the report's
  *Execution & Cleanup Summary*.

Any failure inside the test is caught by the rescue block: the suite
continues, the failure is recorded for the report, and the `always` cleanup
above still runs. The manifest is mirrored to `/tmp/odv_manifest.json` on
each host, so even an aborted run's server/packages are swept by the next
run's final sweep.
