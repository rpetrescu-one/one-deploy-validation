# GPU / LLM benchmark

Enabled by `validation.run_gpu_benchmark` (default `false`). Play tag: `-t gpu_benchmark`.

## What it validates

GPU / LLM inference benchmark for AI Factory validation. It measures the same
hardware in up to three environments — **bare-metal host**, the **vLLM
appliance VM** (GPU passthrough) and a **Kubernetes cluster** deployed per the
OpenNebula AI-ready K8s guide — with one shared load profile, and reports the
virtualization overhead of each against the physical numbers, with noise
guards so that only real regressions flag. Per GPU-bearing host it runs a
**GPU health phase** (nvidia-smi inventory, cuBLAS SGEMM compute, PCIe
H2D/D2H bandwidth, DCGM diagnostics) and an **LLM inference phase** (vLLM
serving each configured model, each GPU benchmarked individually with a fixed
GuideLLM load profile, plus power sampling, provisioning time and a
functional API conformance suite).

## How it works

Enabled by `validation.run_gpu_benchmark: true`; play tag `gpu_benchmark`
(both the frontend play and the bare-metal node play carry it). The
post-deploy flow, per discovered ONE cluster (`tasks/per_cluster.yml`, driven
from the primary frontend):

1. **Discover GPUs** from `onehost show` PCI monitoring (vendor 10de) —
   a cluster with zero GPUs records an explicit "skipped" row and stops.
2. **Ensure the vLLM appliance template** via the shared
   `validation_common/ensure_test_template.yml` service: marketplace export
   (`appliance_market_name`) + run-manifest registration of template and
   image with a `created`/`reused` disposition. It is called with
   `ensure_apply_extra: false` — this is the GPU appliance template, not the
   generic test-VM one, so the suite-wide `validation.test_vm.vm.template_extra`
   CONTEXT is deliberately **not** injected. `USER_INPUTS` are stripped from
   the export (CLI prompting is unusable without a TTY) and the OS disk is
   resized to `max(vm.disk_mb, image size)` — never shrunk.
3. **GPU health phase**: one `gpu-bench-health-h<host_id>` VM per GPU host
   with all its GPUs attached — nvidia-smi inventory, cuBLAS, PCIe bandwidth,
   DCGM (see `dcgm.run_in_vm`).
4. **LLM benchmark phase**, per backend in `llm_backends`: the `appliance`
   backend instantiates one VM per (host, model) — or one VM per GPU with
   `vm_per_gpu: true` — waits for the model to serve, then runs GuideLLM per
   GPU plus power sampling and the functional suite; the `k8s` backend
   deploys the AI-ready-K8s stack and runs the same tests in vLLM pods; the
   `baremetal` backend re-measures the physical numbers live (see below) in
   an earlier node-scoped play.
5. **Baseline comparison**: `<inventory_dir>/gpu_baseline.json` (written by a
   pre-deploy run or the live re-measure) is loaded if present and every
   virtualized metric is compared against it; a corrupt file degrades to
   "no comparison" with a note, never a failure.
6. **Aggregate status** (`ok`/`flag`/`failed`) per cluster, assemble
   `gpu_benchmark_results`, record the report row, and persist
   `/tmp/gpu_benchmark/summary.json` on the frontend.

### Bare-metal baseline (pre-deploy phase)

Before the OpenNebula deploy, the same benchmark can run **directly on a node
host's OS** — no OpenNebula, no VM — to record the hardware's raw capability
as the reference the virtualized deployment is later judged against
(`tasks/baremetal/main.yml`, node-group play):

```bash
# BEFORE the deploy (clean host):
make validation I=inventory/<env>/hosts.yaml ANSIBLE_ARGS='-e gpu_benchmark_phase=pre'
# ... deploy OpenNebula ...
# AFTER the deploy (normal run — loads the baseline automatically):
make validation I=inventory/<env>/hosts.yaml
```

The `gpu_benchmark_phase=pre` extra var (or `gpu_benchmark.phase: pre`) skips
every other validation play (they need OpenNebula), runs the hardware tests +
the LLM benchmark (venv with vLLM pinned to the appliance's version + the
**same** GuideLLM profile) on the selected node host(s) — default: the first
host of the `node` group; `gpu_benchmark.baremetal.hosts` takes a list or
`'all'`; `gpu_count` limits GPUs as usual — and saves
`<inventory_dir>/gpu_baseline.json` on the controller. The post-deploy run
then adds a **"Virtualization overhead vs bare-metal baseline"** section to
the report (per metric: bare-metal vs virtualized vs overhead %, flagged
beyond `baremetal.baseline_tolerance_pct`, default 10%, with the same noise
guards as the GPU-to-GPU comparison).

### NUMA-correct benchmarking (multi-socket hosts)

On a dual-socket host an unpinned run measures scheduler LUCK, not the
hardware: the same L40S swung 1660 → 2685 tok/s purely on process placement
relative to its socket. Two knobs make both phases NUMA-deterministic:

- **Pre phase** — `baremetal.numa_pin: true` (default): each `vllm serve` +
  its load generator is `numactl`-bound to the NUMA node of the GPU under
  test (numactl is installed/purged via the manifest if missing).
- **Post phase** — `vm_per_gpu: true`: one benchmark VM per GPU, attached by
  exact PCI `SHORT_ADDRESS` and pinned with
  `TOPOLOGY = [ NODE_AFFINITY = <the GPU's node> ]` (the node comes from the
  host's own PCI monitoring). OpenNebula REJECTS combining `NODE_AFFINITY`
  with `PIN_POLICY` ("NUMA node affinity cannot be set for pinned VMs"), so
  when the node is known affinity wins and `vm.pin_policy` is ignored;
  `vm.pin_policy: CORE|THREAD|SHARED` is emitted INSTEAD only when no NUMA
  node is reported. Cost: one appliance boot + model download per GPU.
  Default (`vm_per_gpu: false`) keeps the original all-GPUs-in-one-VM flow —
  note that flow cannot be NUMA-local to GPUs on different sockets.

### Live bare-metal re-measure in the post run

Adding `'baremetal'` to `gpu_benchmark.llm_backends` makes the post run
refresh the physical numbers FIRST, on the deployed node, before the
appliance/k8s backends run: the node's GPUs are temporarily released from
`vfio-pci` (the persistent driverctl override is lifted), the NVIDIA driver
is installed, the exact pre-phase benchmark runs on the host (hardware + LLM,
NUMA-pinned, with the unsaturated-sweep retry), the fresh numbers replace
`gpu_baseline.json`, and cleanup restores the vfio binding — override
persistence included — before any VM is created. The comparison then uses
SAME-DAY, SAME-DRIVER physical data, eliminating the "driver differs between
runs" caveat.

Safety: a GPU attached to a running VM aborts the release with the address
named (terminate those VMs first); `nvidia-persistenced` is stopped around
every vfio (re)bind (a running persistenced wedges the bind forever — hit
live during a one-deploy install); an incomplete restore is surfaced loudly
in the report, since a node without vfio on its GPUs cannot serve passthrough
VMs. Cost: ~35-45 min per run (driver install + model download on the host).
The two-phase flow (pre before deploy, post after) remains the default and
needs none of this.

### Kubernetes backend (bare-metal vs vLLM appliance vs K8s)

`gpu_benchmark.llm_backends` selects which post-deploy backends run the
benchmark (default `['appliance']` — behavior identical to before the knob
existed). With `['k8s']` or `['appliance', 'k8s']` the role deploys an RKE2
cluster **exactly per the OpenNebula 7.4 "AI-ready Kubernetes" guide**: the
`Service Capi` appliance (k3s management cluster with the CAPONE provider,
exported through the same shared `ensure_test_template.yml` service with
`ensure_apply_extra: false`), the `capone/capone-rke2` chart (0.1.7) with 1
control-plane + **one GPU worker per benchmarked GPU** (PCI passthrough by
vendor/class, device id auto-filled when uniform), the NVIDIA `gpu-operator`
(v25.3.2, the guide's containerd env for RKE2), and the guide's CUDA
verification Job on every worker as a hard gate. helm and kubectl are
installed on the frontend if missing (the guide's install commands);
run-installed binaries are manifest-registered as `created` and removed by
the final sweep, while pre-installed ones are never manifest-owned and never
touched.

The one piece the guide stops short of — LLM serving — is a vLLM pod per
worker pinned to the SAME vLLM version as the baseline
(`vllm/vllm-openai:v<baremetal.vllm_version>`), with guidellm running INSIDE
the container against localhost using the shared profile: the same tests, the
same metrics, the same SLO gates, the same bare-metal comparison. K8s results
are keyed `<model> · k8s` and their overhead rows are labeled `[k8s]`; with
both backends in one run the report's overhead table grows an environment
column per backend (bare-metal | vLLM appliance | Kubernetes), with a
combined `Overhead % (vm / k8s)` column and a Status column naming the
breaching environment.

The hardware micro-benchmarks also run in-cluster (`k8s.hw_probe`, default
`true`): a one-shot Job per GPU worker with a CUDA **devel** image
(`k8s.cuda_devel_image`) compiles and runs the SAME `cublas_sgemm.cu` +
`pcie_bandwidth.cu` sources used by the health flow and the results fill the
Kubernetes cells of the cuBLAS / PCIe H2D / PCIe D2H rows. Since K8s workers
cannot be NUMA-pinned, the in-pod PCIe number is the signal that attributes
(or clears) NUMA placement when a `[k8s]` LLM row breaches tolerance. The
probe honors `cublas.enabled` / `pcie_bw.enabled`, is bounded by
`k8s.hw_probe_timeout_s`, and is best-effort: a failure becomes a report
caveat, never a lost benchmark. It runs only when a bare-metal baseline file
(`gpu_baseline.json`) exists — its only consumer is the baseline comparison,
so without one the ~2.5 GB devel-image pull is skipped and the k8s hardware
cells are not produced.

Bootstrap wedges and how they are reported: the `Service Capi` appliance boot
is bimodal on throttled labs, and two deadlocks have been observed live. The
rancher-turtles helm install can stick (`failed`/`uninstalling`/`pending-install`
→ the wait uninstalls it `--no-hooks` so the k3s retry job reinstalls cleanly),
and the appliance's k3s apiserver can lose its **Secrets watch cache** while
quorum reads stay correct — kubelet then reports `secret ... not found` for a
secret that exists, the CAPI core pod never starts, no provider installs, and
the wait can never succeed. The wait detects the second one exactly (it compares
the cached `resourceVersion=0` secret LIST against the quorum LIST every ~5 min)
and restarts k3s **once** on the capi VM, which recovered the stack in 15 s
live; `k8s.unwedge_apiserver_cache: false` disables it. No in-cluster remedy
works for that fault — deleting the stale cert-manager temp secret, kicking the
pod, restarting cert-manager, recreating the `Certificate` and minting the cert
by hand were all verified useless.

When the stack does fail, the report no longer says "non-zero return code": the
waits print a greppable `K8S_STACK_VERDICT rc=… reason=…` line **last**, the
rescue captures the redacted stdout/stderr tail into the failed model entry
(`error`, `error_detail`) and writes the full evidence to
`/tmp/gpu_benchmark/k8s_failure<cluster suffix>.log`, which survives teardown.

Deviations, all deliberate and documented in-line: worker resources use
`vm.vcpu`/`vm.memory_mb` (role defaults 8 vCPU/16 GiB; the validated vgpu2
lab raised them to 32 vCPU/64 GiB in its site inventory, not shipped in this
repo), NOT the guide's
12–16/32 examples; K8s workers are **not NUMA-pinned** (the chart shares one
worker template — the report states this caveat); the functional API suite
and power sampling are appliance/bare-metal-only in v1. Budget ~30–45 min
extra for the K8s stack. Teardown is described under
[Cleanup & failure behavior](#cleanup--failure-behavior).

### Measurement honesty — the guidellm client is bimodal

The load generator itself (guidellm, pip-installed fresh in every VM/pod) has
two stable modes, proven live on identical hardware minutes apart: in the
slow mode the client wastes ~1.4 s per request slot, the capped throughput
probe under-measures by ~15%, and the rate ladder derived from it stops BELOW
the throughput knee — the whole run then under-reports capacity by the same
~15% while the server-side token speed (ITL) is byte-identical in both modes.
The role defends in two layers:

- `parse_guidellm` detects the **unsaturated ladder** (the last constant
  rungs still climb linearly while the peak sits on the ladder tail) and
  marks the result `sweep_unsaturated` — treated everywhere exactly like a
  truncated sweep: a LOWER BOUND. SLO breaches become `inconclusive` (`*` in
  the report), GPU-to-GPU and bare-vs-virt gaps against the affected side are
  not flagged, and the report carries a caveat.
- `llm_retry_unsaturated` (default `true`) re-runs the sweep ONCE on the
  affected GPU and keeps the better curve. Capacity is a max-capability
  metric, so best-of-two removes the downward bias and cannot inflate the
  result; a failed retry never discards the first attempt.

## Requirements

- NVIDIA GPUs configured for PCI passthrough on the node hosts (vfio-pci, as
  set up by one-deploy) and visible in `onehost show` PCI monitoring.
- The ONEAI marketplace (`MARKET_MAD=one`) registered in OpenNebula so
  `onemarketapp export` can find `appliance_market_name` — the PUBLIC
  marketplace ships the same appliance as `service_Vllm`. The appliance is
  x86-64 only; on aarch64 hosts point `appliance_market_name` at an aarch64
  vLLM appliance.
- Egress from the benchmark VMs (`vnet_name`) for model / CUDA toolkit / pip
  downloads; the pre phase and the live `baremetal` backend need egress from
  the node host itself (NVIDIA repo + pip + HF); the k8s backend additionally
  needs the guide's image URLs, NGC and helm chart repos reachable from the
  frontend and VMs.
- A HuggingFace token (`hf_token`) for gated models (e.g. Llama) — read it
  from the environment, never commit it.
- Datastore capacity for the appliance image (the public `service_Vllm` image
  is 100 GB) and `vm.disk_mb` per benchmark VM; the k8s backend adds
  `k8s.worker_disk_mb` per worker.

## Configuration

The user config is a **top-level `gpu_benchmark` dict** (not under
`validation:`), merged recursively over the role defaults — list only the
keys you change. `inventory/reference/group_vars/all.yml` is the complete,
commented knob reference; the rationale behind each default lives next to it
in `defaults/main.yml`. Secrets such as `hf_token` must come from the
environment (`"{{ lookup('env', 'HF_TOKEN') }}"`), never from a committed
file.

| Option | Default | Description |
|---|---|---|
| `validation.run_gpu_benchmark` | `false` | Enable flag for the whole role |
| `gpu_benchmark.phase` | `post` | `pre` = bare-metal baseline before the deploy; usually set via `-e gpu_benchmark_phase=pre` (the extra var overrides the key and also skips every other validation play) |
| `gpu_benchmark.llm_backends` | `['appliance']` | Post-deploy backends: any subset of `baremetal`, `appliance`, `k8s`; the report grows one environment column per backend |
| `gpu_benchmark.appliance_market_name` | `'vLLM Inference Engine'` | Marketplace app serving vLLM (public marketplace: `service_Vllm`) |
| `gpu_benchmark.vnet_name` | `public` | VM network; needs egress; falls back to the cluster's validation vnet when not eligible in that cluster |
| `gpu_benchmark.models` | `[Qwen/Qwen2.5-3B-Instruct]` | One appliance VM per model (`ONEAPP_VLLM_MODEL_ID`) |
| `gpu_benchmark.hf_token` | `""` | HuggingFace token for gated models (`ONEAPP_VLLM_MODEL_TOKEN`) |
| `gpu_benchmark.gpu_count` | `all` | Limit how many discovered GPUs are benchmarked |
| `gpu_benchmark.baremetal.hosts` | `[]` | Pre-phase targets: `[]` = first `node`-group host, a list, or `'all'` |
| `gpu_benchmark.baremetal.workdir` | `/root/gpu-bench-tmp` | Everything the pre phase adds lives (and dies) here |
| `gpu_benchmark.baremetal.vllm_version` | `"0.17.1"` | PIN to your appliance's vLLM version (comparability) |
| `gpu_benchmark.baremetal.allow_driver_install` | `true` | Install (and purge at cleanup) the NVIDIA driver when the host has none; `false` = fail instead |
| `gpu_benchmark.baremetal.baseline_tolerance_pct` | `10` | Flag a virtualized metric worse than bare-metal by more than this % |
| `gpu_benchmark.baremetal.baseline_file` | `""` | `''` = `<inventory_dir>/gpu_baseline.json` |
| `gpu_benchmark.baremetal.allow_on_deployed` | `false` | Let phase=pre run on a host that already has OpenNebula |
| `gpu_benchmark.baremetal.numa_pin` | `true` | numactl-bind serve + load generator to the GPU's NUMA node |
| `gpu_benchmark.vm.vcpu` | `8` | Benchmark VM vCPUs (32 validated on L40S — vLLM is CPU-hungry) |
| `gpu_benchmark.vm.memory_mb` | `16384` | Benchmark VM memory (65536 validated on L40S) |
| `gpu_benchmark.vm.disk_mb` | `40960` | OS disk resize at instantiation (never shrunk below the image size) |
| `gpu_benchmark.vm.pin_policy` | `''` | `CORE`\|`THREAD`\|`SHARED`; ignored when `NODE_AFFINITY` is emitted (`vm_per_gpu`) |
| `gpu_benchmark.vm_per_gpu` | `false` | One VM per GPU, NUMA-affine (recommended on multi-socket hosts; +1 boot per GPU) |
| `gpu_benchmark.vm_apt_https` | `false` | Rewrite VM apt sources to https + prefer the distro CUDA toolkit (port-80-blocked / throttled labs) |
| `gpu_benchmark.serve_timeout_s` | `1200` | Wait for the appliance to serve the model |
| `gpu_benchmark.vllm_context.api_port` | `8000` | Served API port |
| `gpu_benchmark.vllm_context.gpu_mem_util` | `0.9` | vLLM GPU memory utilization |
| `gpu_benchmark.vllm_context.model_max_length` | `1024` | `ONEAPP_VLLM_MODEL_MAX_LENGTH` (prompt+output context) |
| `gpu_benchmark.k8s.capi_app_name` | `'Service Capi'` | Management-cluster appliance |
| `gpu_benchmark.k8s.release_name` | `gpu-bench-k8s` | Helm release; names the workload VMs/images (per-cluster suffix added) |
| `gpu_benchmark.k8s.capone_chart_version` | `'0.1.7'` | `capone/capone-rke2` chart version (guide-pinned) |
| `gpu_benchmark.k8s.gpu_operator_version` | `'v25.3.2'` | NVIDIA gpu-operator version (guide-pinned) |
| `gpu_benchmark.k8s.router_image_url` | guide vRouter qcow2 URL | Virtual router image |
| `gpu_benchmark.k8s.node_image_url` | guide Ubuntu 24.04 qcow2 URL | Node image; its kernel headers must still exist in the Ubuntu archive |
| `gpu_benchmark.k8s.worker_disk_mb` | `204800` | Worker OS disk |
| `gpu_benchmark.k8s.one_xmlrpc_ip` | `''` | oned endpoint IP for the capi VM; `''` = auto (benchmark vnet bridge IP) |
| `gpu_benchmark.k8s.deploy_timeout_s` | `2700` | Workload-cluster deploy budget |
| `gpu_benchmark.k8s.bootstrap_timeout_s` | `5400` | Capi appliance bootstrap budget (bimodal on slow networks) |
| `gpu_benchmark.k8s.unwedge_apiserver_cache` | `true` | Restart k3s ONCE if its Secrets watch cache goes stale (proven deadlock) |
| `gpu_benchmark.k8s.keep_stack_on_failure` | `false` | `true` = a FAILED k8s backend keeps the stack for post-mortem (credential files still removed); the next run adopts it |
| `gpu_benchmark.k8s.hw_probe` | `true` | cuBLAS+PCIe Job per worker (fills the k8s hardware rows; runs only when a bare-metal baseline `gpu_baseline.json` exists) |
| `gpu_benchmark.k8s.cuda_devel_image` | `nvcr.io/nvidia/cuda:12.8.1-devel-ubuntu24.04` | Needs nvcc; CUDA <= the gpu-operator driver ceiling |
| `gpu_benchmark.k8s.hw_probe_timeout_s` | `1500` | Bounds pull + compile + both benchmarks per worker |
| `gpu_benchmark.guidellm_profile` | see `defaults/main.yml` | The SHARED load profile (sweep, warmup exclusion, `max_concurrency=128`, 512/256 tokens). Changing it re-defines the measurement — re-record the baseline |
| `gpu_benchmark.guidellm_status` | `successful` | Request-status bucket the metrics are read from |
| `gpu_benchmark.guidellm_max_duration_s` | `20` | Seconds per sweep rate; ~40 for large (14B) models |
| `gpu_benchmark.llm_retry_unsaturated` | `true` | Re-run a sweep once when the guidellm client landed in its slow mode |
| `gpu_benchmark.thresholds` | `{profile: chat, ttft_p95_ms: 200, itl_p95_ms: 50, min_throughput_req_s: null}` | Absolute SLO gates on the sync run; `null` disables a gate |
| `gpu_benchmark.reference` | `{}` (reference inventory ships an L40S entry) | Per (GPU name, model id) PARTIAL threshold overrides — see calibration below |
| `gpu_benchmark.llm_variance_pct` | `20` | GPU-to-GPU outlier tolerance for the LLM metrics |
| `gpu_benchmark.compare_min_samples` | `30` | No comparison flag below this many successful requests |
| `gpu_benchmark.compare_min_throughput_req_s` | `1.0` | No throughput flag under this absolute rate (tiny-denominator guard) |
| `gpu_benchmark.compare_min_ttft_delta_ms` | `25` | Sync-TTFT breaches flag only when also material in absolute ms |
| `gpu_benchmark.cublas` | `{enabled: true, n: 16384, iters: 10, variance_pct: 25, allow_toolkit_install: true}` | cuBLAS SGEMM benchmark; `allow_toolkit_install: false` for airgap |
| `gpu_benchmark.dcgm` | `{enabled: true, level: 2, timeout_s: 900, allow_install: true, run_in_vm: true}` | DCGM diagnostics; `run_in_vm: false` = host (pre phase) only; raise `timeout_s` for level 3 |
| `gpu_benchmark.pcie_bw` | `{enabled: true, size_mb: 256, iters: 20, min_gbs: 8}` | PCIe H2D/D2H transfer test (passthrough data path) |
| `gpu_benchmark.pcie_expected_width` | `null` | e.g. `8` where GPUs are wired x8 by design (AWS g4dn); `null` = strict current-vs-max check |
| `gpu_benchmark.functional.enabled` | `true` | Functional API conformance suite per (host, model) |
| `gpu_benchmark.power_sampling` | `{enabled: true, interval_s: 5}` | Power/clock/temperature sampling under load (tokens/W) |
| `gpu_benchmark.fail_on_flag` | `false` | `true` = fail the play when any cluster is `flag`/`failed` (default: report WARN only) |

## Example

```yaml
validation:
  run_gpu_benchmark: true

gpu_benchmark:            # partial dict, merged recursively over role defaults
  vnet_name: nat          # VM network; needs egress for model/toolkit download
  llm_backends: ['appliance', 'k8s']   # any subset incl. 'baremetal'; default ['appliance']
  hf_token: "{{ lookup('env', 'HF_TOKEN') }}"   # only for gated models
```

Full suite:

> Copy `playbooks/report_input_vars.yml.example` to `playbooks/report_input_vars.yml` and fill in the report details first (see the main README).

```bash
make I=inventory/<env>/hosts.yaml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml"
```

Only this test (plus the always-on discovery/preclean/sweep/report plays; the
report is labeled PARTIAL RUN):

```bash
make I=inventory/<env>/hosts.yaml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml -t gpu_benchmark"
# equivalent direct invocation:
hatch env run -e validation-default -- ansible-playbook -i inventory/<env>/hosts.yaml \
  -t gpu_benchmark -e @playbooks/report_input_vars.yml playbooks/validation.yml
```

Bare-metal baseline before the deploy:

```bash
make I=inventory/<env>/hosts.yaml validation ANSIBLE_ARGS='-e gpu_benchmark_phase=pre'
```

## Report output

Rows recorded in `verification_result` (rendered in the HTML/PDF report):

- `GPU benchmark[ — cluster <name>]` — one row per ONE cluster: `ok` (PASS),
  `warning - anomalies flagged` (WARN — one of the judgment signals below
  fired), `failed - LLM benchmark produced no results` / `failed` (FAIL — the
  benchmark itself broke; the error is captured in the result entry),
  `skipped - no NVIDIA GPUs discovered`, or
  `skipped — cluster discovery failed` (run-to-completion: the row is never
  silently absent).
- `GPU baseline (bare-metal, pre-deploy)` — the pre phase / live re-measure
  row, same `ok` / `warning` / `failed` semantics.
- `verification_comments` under the same keys carry caveats: partial K8s
  teardown leftovers, an incomplete vfio restore, baseline profile
  mismatches, and cleanup notes.

The full structured results live in the `gpu_benchmark_results` fact,
persisted as `/tmp/gpu_benchmark/summary.json` on the frontend: one entry per
cluster (key `<frontend host><report suffix>`; bare-metal runs use
`<node host> (bare-metal baseline)`) with `discovery`, `gpu_health`, `llm`
(per model / per GPU metrics), `baseline_delta`, `note`, `status`
(`ok`/`flag`/`failed`), `error` (on failure) and `meta` (driver/CUDA
versions, models, thresholds, load profile). The report renders hardware
inventory, KPI cards, per-GPU metrics, load-sweep tables and charts from it.
A `flag` never fails the play unless `fail_on_flag: true`.

### How results are judged

Independent signals; any of them turns the cluster status to `flag` (reported
as WARN — the role never hard-fails unless `fail_on_flag: true`):

1. **GPU-to-GPU comparison** (multi-GPU hosts only): every GPU runs the same
   benchmark; a card whose throughput drops below `best × (1 − llm_variance_pct/100)`
   or whose latency rises above `best × (1 + llm_variance_pct/100)` relative to
   the best card is flagged (default 20 %). cuBLAS has its own
   `cublas.variance_pct` (default 25 %). This is hardware-independent — the
   cards are their own reference. A single-GPU host has nothing to compare and
   shows no comparison. **Three noise guards** stop a false outlier when the
   data can't support the call: if the weakest GPU completed fewer than
   `compare_min_samples` successful requests (default 30) the whole comparison
   is marked low-confidence and nothing is flagged; a throughput spread below
   `compare_min_throughput_req_s` req/s (default 1.0) is treated as a
   tiny-denominator artifact, not a real difference (both observed on a slow
   2× T4 where 3-vs-4 requests produced a spurious 22 % "outlier"); and a GPU
   whose load sweep was **truncated** (guidellm derives its rate ladder from a
   short throughput probe, and the probe is chaotic in the overload region —
   seen live as 1467 vs 2807 tok/s on identical L40S cards, flipping between
   runs) suppresses the throughput comparison: its figures are a lower bound,
   not a measurement, and the report labels them as such. Sync latency
   metrics are unaffected and stay compared.
2. **Absolute SLO gates** (`gpu_benchmark.thresholds`): TTFT p95 and ITL p95
   from the *synchronous* run, optional throughput floor from the *saturated*
   run. The defaults (TTFT ≤ 200 ms, ITL ≤ 50 ms) are the reference document's
   chat SLOs. With the representative warm-up in place, a healthy warmed-up
   GPU often meets them even on smaller hardware — but whether a given
   GPU × model combo does is an empirical question, which is what the
   reference table below answers. `null` disables a gate.
3. **NVIDIA health**: GPU count mismatch, uncorrected ECC errors, active
   throttling (benign reason bits — GPU idle, applications-clocks setting,
   sync boost — are whitelisted; anything else flags), degraded PCIe link
   width, PCIe transfer bandwidth below `pcie_bw.min_gbs`, and a failed DCGM
   diagnostic (`dcgm.level`, default 2).
4. **Functional API conformance** (`functional.enabled`): any failed endpoint
   test (chat completions, streaming, max_tokens honored, clean 4xx on
   invalid model / context overflow, concurrent-request isolation) flags the
   model — a misbehaving API matters as much as slow metrics. An unrunnable
   suite is a visible failure, never a silent pass.
5. **Bare-metal baseline breach**: a virtualized metric worse than the
   baseline by more than `baremetal.baseline_tolerance_pct` (with the same
   noise guards, including the `compare_min_ttft_delta_ms` absolute floor on
   sync TTFT).

Informational (never flags): power/thermal profile under load and
tokens-per-watt per GPU, and the provisioning time (VM create → serving).

### Avoiding false WARNs: hardware-calibrated reference SLOs

**There is no public canonical table of per-GPU SLO values** for this load
profile — TTFT/throughput depend on the GPU model × LLM model × engine version
combination. The role therefore supports a curated table,
`gpu_benchmark.reference`, that overrides the global gates per
**(GPU name, model id)** combo:

```yaml
gpu_benchmark:
  reference:
    'NVIDIA L40S':                        # EXACT nvidia-smi name — copy it from
      'Qwen/Qwen2.5-3B-Instruct':         # the report's GPU "Name" column
        ttft_p95_ms: 2000                 # partial dict: unlisted keys (itl,
        min_throughput_req_s: 8.0         # profile) inherit the global values
```

The evaluation records which thresholds were applied (`source` in
`summary.json`) and the report marks such cells with `(ref)`.

Calibration procedure for a NEW GPU model:

1. **Run the benchmark 2–3 times on known-healthy hardware** with the config
   you will use in production (same model list, same VM sizing). A WARN on the
   SLO gates during these runs is fine — it just means the defaults do not fit
   this hardware yet; the measured values are the calibration signal.
2. **Read the measured values** from the report's per-GPU table, or from
   `/tmp/gpu_benchmark/summary.json` on the frontend
   (`<frontend-key>.llm.<model>.per_gpu[].metrics` — the top-level key is the
   frontend inventory hostname, e.g. `fe`):
   - `ttft_p95_ms` — sync-run TTFT p95,
   - `throughput_req_s_mean` — SUSTAINED saturated throughput (output tok/s ÷
     tokens-per-request; stable run-to-run). Note the raw
     `throughput_req_s_peak` is guidellm's short-window burst rate and is NOT
     what to calibrate against,
   - `itl_p95_ms` — sync-run inter-token latency.
3. **Apply margins** over the *worst* healthy measurement:
   - `ttft_p95_ms`: **+30 %** — the sync run only collects ~5 samples in 20 s,
     so its p95 is noisy (±10–15 % between healthy runs is normal);
   - `min_throughput_req_s`: **−25 %** of the measured mean — throughput is
     very stable (±1–2 % between runs), so this still catches real
     degradation;
   - `itl_p95_ms`: usually leave the inherited 50 ms — measured values tend to
     have several× headroom; tighten only if you want a stricter gate.
4. **Add the entry** to `gpu_benchmark.reference` in that site's inventory
   (and to `inventory/reference/group_vars/all.yml` so the next site starts
   from known-good values). Key it by the *exact* nvidia-smi name and the
   *exact* HuggingFace model id.
5. **Re-run**: the SLO column shows `ok (ref)` and the cluster goes PASS. The
   gates stay armed — a real regression (dying card, thermal issue, wrong PCIe
   link) beyond the margins still flags.

Rule of thumb: the reference table catches "this machine is slower than this
hardware should be"; the GPU-to-GPU delta catches "this card is slower than
its siblings". Together they replace the need to compare against GB200-class
absolute numbers.

### Measured values (healthy hardware, guidellm 0.7.1, profile with max_concurrency=128)

| GPU | Model | TTFT p95 sync (ms) | Sustained throughput (req/s) | ITL p95 (ms) | cuBLAS (GFLOP/s) | Gates (validated) |
|---|---|---|---|---|---|---|
| NVIDIA L40S | Qwen/Qwen2.5-3B-Instruct | 36–39 (warm¹; 55–90 at constant rates) | 12.8–15.4 over 4 runs, bare-metal AND virtualized (curve peak 3300–3900 tok/s ÷ 256 tok/req; vLLM 0.17.1, 40 s windows) | 9.7–10.8 | 57 042–57 934 | ttft 200, thr 10.5 — PASS with ~5× TTFT headroom |

Throughput here is the SUSTAINED rate (peak of the load curve ÷
tokens-per-request) measured under the BOUNDED probe (`max_concurrency=128`
in the shared profile). Values measured under earlier profiles are NOT
comparable and must not feed calibration: the pre-2026-08 semantics read the
overload-probe row (historic 5.9 req/s on this GPU), and the unbounded
512-probe era measured ~10.9 req/s with bimodal truncation artifacts.
Re-measure before recalibrating.

¹ Sync TTFT is only meaningful since the first-request exclusion: guidellm's
FIRST request pays ~1.5 s of client-side startup (historic runs read
1491–1537 ms because of it; a server-side warm-up could not remove it). The
benchmark excludes it via `--profile
'kind=sweep,warmup.value=1,warmup.mode=requests'` **plus** the never-binding
`--constraint kind=max_requests,count=100000` — guidellm only computes
request-count warmup when a total-request budget exists; without that
constraint the warmup config is silently ignored (proven by a mock-server A/B
test, and validated on the lab: sync TTFT dropped 1488 → 37.5 ms). Do not
remove either flag without re-checking the sync TTFT column against the
constant-rate rows.

Extend this table (and the reference inventory) as new GPU/model combos are
benchmarked on known-good hardware. Note that changing the **model list**, the
appliance/vLLM version or the VM sizing changes the numbers — recalibrate when
any of those change.

### Artifacts

On the frontend, per run:

- `/tmp/gpu_benchmark/summary.json` — full structured results (the source of
  truth for calibration values);
- `/tmp/gpu_benchmark/<cluster>_<model>_h<host>_g<gpu>_guidellm.json` — raw
  GuideLLM reports (one per GPU);
- `*_failure.log` — auto-collected diagnostics when a benchmark fails;
- `k8s_failure<cluster>.log` — the redacted stdout/stderr tail of a failed
  K8s stack step (survives teardown), referenced from the report.

On the controller: `<inventory_dir>/gpu_baseline.json` (pre phase / live
re-measure) — deliberately kept, it IS the deliverable of the pre phase.

## Cleanup & failure behavior

Resources the post-deploy flow creates, and how they are removed:

- **Benchmark VMs** — `gpu-bench-health-h<host>`, `gpu-bench-<model>-h<host>`
  (`-g<gpu>` with `vm_per_gpu`), each with the cluster name suffix. Every VM
  is registered in the run manifest (type `vm`, disposition `created`)
  **before** instantiation, so even a crash mid-instantiate leaves an entry
  the sweep can resolve by name. Each per-VM block has an `always` that runs
  `tasks/cleanup.yml` (`onevm terminate --hard`, wait for release,
  `onevm recover --delete` as a last resort, plus removal of the rendered
  context file, which may contain the HF token); the per-cluster `always`
  runs it again unconditionally — it is idempotent and double-call safe.
- **Appliance template + image** (vLLM appliance, and `Service Capi` for the
  k8s backend) — exported and manifest-registered by the shared
  `validation_common/ensure_test_template.yml` (types `template` + `image`,
  disposition `created` when this run exported them, `reused` when they
  pre-existed). The final `validation_sweep` play (tagged `always`, so it
  runs even on failures and tag runs) deletes `created` objects and records
  removed/kept/leftover rows in the report; `reused` objects are never swept,
  and `validation.cleanup.keep_exported_images: true` keeps created
  images/templates for cheap re-runs.
- **K8s stack** — torn down in an `always` block (`k8s/teardown.yml`): vLLM
  deployments and verify Jobs, `helm uninstall` of the workload cluster
  (CAPONE removes its VMs), explicit deletion of the chart's
  `resource-policy=keep` CAPI objects and the release's ONE images (both
  proven to linger), the capi VM, and every kubeconfig / rendered values file
  (they contain credentials — removed even with `keep_stack_on_failure`).
  Leftover workload VMs are counted and reported LOUDLY as a comment on the
  `GPU benchmark` row, never silently kept.
  `k8s.keep_stack_on_failure: true` skips the teardown after a FAILED k8s
  backend for post-mortem; the next run adopts the stack (every deploy step
  is idempotent). helm/kubectl binaries installed by this run are
  manifest-registered (type `file`) and removed by the final sweep;
  pre-installed ones are never touched.
- **Failure isolation** — a failure inside one cluster's block is caught by
  the per-cluster `rescue`: it records `status: failed` plus the error into
  `gpu_benchmark_results` and marks the report row `failed`, and the run
  continues (run-to-completion). A k8s-backend failure is isolated in
  `k8s/main.yml`'s own rescue and never costs the appliance results. The
  pre-run `validation_sweep` preclean also removes a previous run's
  unresolved leftovers (e.g. an err-state image) before this role runs.

**Clean-OS guarantee (pre phase / live `baremetal` backend)**: everything the
bare-metal flow adds is tracked and removed in an `always` block — the
venv/model/caches live under `baremetal.workdir` (deleted; sentinel-guarded
so a foreign directory is never adopted or removed), and apt packages
(driver, CUDA toolkit, DCGM, python3-venv, numactl) are purged **only if
this run installed them**; anything pre-existing is used but never touched
(including a DCGM engine that was already running). `apt-get autoremove` runs
only when the host had zero autoremovable packages beforehand. A missing
NVIDIA driver is installed only when `baremetal.allow_driver_install: true`
(default), and purged again at cleanup. The live backend additionally
restores the vfio-pci binding (driverctl override included) and reports an
incomplete restore loudly. Known limitation: if the controller loses the
connection mid-run (UNREACHABLE), ansible cannot run the cleanup — re-run the
pre phase to redo the benchmark; note a driver installed by the interrupted
run is then detected as pre-existing and left in place (remove manually or
reset the host if a pristine OS is required).

**Induced failure**: `-e odv_fail_in=gpu_benchmark` triggers the role's debug
fail hook (first task of the per-cluster block) to verify that cleanup and
honest reporting survive a failure.

## Testing

`make test` runs a shell-lint gate (`test/gpu_benchmark/lint_shell.py`), a
unit suite (`test/gpu_benchmark/test_logic.yml`) over all parsing/evaluation/
comparison logic, and the sweep-plan unit suite (`test/harness/test_logic.yml`). The suite must pass on **both** ansible-core 2.18 (hatch
env) and 2.21.
