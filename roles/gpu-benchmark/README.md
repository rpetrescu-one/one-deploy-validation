gpu-benchmark
=============

GPU / LLM inference benchmark for AI Factory validation. It measures the same
hardware in up to three environments — **bare-metal host**, the **vLLM
appliance VM** (GPU passthrough) and a **Kubernetes cluster** deployed per the
OpenNebula AI-ready K8s guide — with one shared load profile, and reports the
virtualization overhead of each against the physical numbers, with noise
guards so that only real regressions flag. Per GPU-bearing host it runs:

- a **GPU health phase**: nvidia-smi inventory (VRAM, PCIe width, ECC,
  throttling, compute capability, VBIOS, power limit, clocks, temperature), a
  **cuBLAS SGEMM** compute benchmark on every GPU, a **PCIe H2D/D2H bandwidth**
  test per GPU (pinned-memory cudaMemcpy — validates the passthrough data
  path, which can be slow even at a negotiated x16), and **NVIDIA DCGM
  diagnostics** (`dcgmi diag`, the vendor-standard GPU acceptance tool);
- an **LLM inference phase**: the ONEAI *vLLM Inference Engine* appliance is
  instantiated with all of the host's GPUs, and **each GPU is benchmarked
  individually** (`CUDA_VISIBLE_DEVICES` pinning, tensor-parallel 1) with a
  fixed GuideLLM load profile (sweep, 512 prompt / 256 output tokens,
  `guidellm_max_duration_s` per rate, default 20) — always the same profile, so
  results are comparable across GPUs and
  runs. Power draw / SM clock / temperature are sampled during the benchmark
  (yielding avg/max power, max temp, min clock and **tokens-per-watt**), the
  **provisioning time** (VM create → model serving) is recorded, and a
  **functional API conformance suite** runs against the served endpoint (chat
  completions, streaming, max_tokens honored, clean 4xx on invalid model and
  context overflow, concurrent-request isolation).

Results land in the HTML/PDF verification report (hardware inventory, KPI
cards, per-GPU metrics, load-sweep tables and charts) and in
`/tmp/gpu_benchmark/summary.json` + raw GuideLLM JSONs on the frontend.

Enabling
--------

```yaml
validation:
  run_gpu_benchmark: true

gpu_benchmark:            # partial dict, merged recursively over role defaults
  vnet_name: nat          # VM network; needs egress for model/toolkit download
  llm_backends: ['baremetal', 'appliance', 'k8s']   # any subset; default ['appliance']
```

`inventory/reference/group_vars/all.yml` is the **complete, commented knob
reference** (every key the role reads, at its default value); the rationale
behind each default lives next to it in `defaults/main.yml`. Secrets such as
`hf_token` must come from the environment
(`"{{ lookup('env', 'HF_TOKEN') }}"`), never from a committed file.

Configuration reference (grouped)
---------------------------------

| Group | Keys | Notes |
|---|---|---|
| What runs | `phase`, `llm_backends`, `appliance_market_name`, `vnet_name`, `models`, `hf_token`, `gpu_count` | `llm_backends` accepts `baremetal`, `appliance`, `k8s` in any combination |
| Bare-metal | `baremetal.{hosts, workdir, vllm_version, allow_driver_install, baseline_tolerance_pct, baseline_file, allow_on_deployed, numa_pin}` | phase=pre AND the live `baremetal` backend; pin `vllm_version` to the appliance |
| VM sizing | `vm.{vcpu, memory_mb, disk_mb, pin_policy}`, `vm_per_gpu`, `vm_apt_https`, `serve_timeout_s`, `vllm_context.{api_port, gpu_mem_util, model_max_length}` | 32 vCPU / 64 GiB + `vm_per_gpu: true` validated on L40S |
| Kubernetes | `k8s.{capi_app_name, release_name, capone_chart_version, gpu_operator_version, router_image_url, node_image_url, worker_disk_mb, one_xmlrpc_ip, deploy_timeout_s, bootstrap_timeout_s, unwedge_apiserver_cache, keep_stack_on_failure, hw_probe, cuda_devel_image, hw_probe_timeout_s}` | versions/URLs pinned to the guide; `node_image_url` kernel must still have headers in the archive |
| Load profile | `guidellm_profile`, `guidellm_status`, `guidellm_max_duration_s`, `llm_retry_unsaturated` | shared by every backend — changing it re-defines the measurement (re-record the baseline) |
| SLO gates | `thresholds.{profile, ttft_p95_ms, itl_p95_ms, min_throughput_req_s}`, `reference` | `reference` = per-GPU-name x model overrides |
| Comparisons | `llm_variance_pct`, `compare_min_samples`, `compare_min_throughput_req_s`, `compare_min_ttft_delta_ms`, `fail_on_flag` | the noise guards (see "How results are judged") |
| Hardware diag | `cublas.{enabled, n, iters, variance_pct, allow_toolkit_install}`, `dcgm.{enabled, level, timeout_s, allow_install, run_in_vm}`, `pcie_bw.{enabled, size_mb, iters, min_gbs}`, `pcie_expected_width`, `functional.enabled`, `power_sampling.{enabled, interval_s}` | all on by default |

Bare-metal baseline (pre-deploy phase)
--------------------------------------

Before the OpenNebula deploy, the same benchmark can run **directly on a node
host's OS** — no OpenNebula, no VM — to record the hardware's raw capability
as the reference the virtualized deployment is later judged against:

```bash
# BEFORE the deploy (clean host):
make validation I=inventory/<env>/hosts.yaml ANSIBLE_ARGS='-e gpu_benchmark_phase=pre'
# ... deploy OpenNebula ...
# AFTER the deploy (normal run — loads the baseline automatically):
make validation I=inventory/<env>/hosts.yaml
```

`phase=pre` skips every other validation play (they need OpenNebula), runs the
hardware tests + the LLM benchmark (venv with vLLM pinned to the appliance's
version + the **same** GuideLLM profile) on the selected node host(s) —
default: the first host of the `node` group; `gpu_benchmark.baremetal.hosts`
takes a list or `'all'`; `gpu_count` limits GPUs as usual — and saves
`<inventory_dir>/gpu_baseline.json`. The post-deploy run then adds a
**"Virtualization overhead vs bare-metal baseline"** section to the report
(per metric: bare-metal vs virtualized vs overhead %, flagged beyond
`baremetal.baseline_tolerance_pct`, default 10%, with the same noise guards
as the GPU-to-GPU comparison).

**Clean-OS guarantee**: everything the pre phase adds is tracked and removed
in an `always` block — the venv/model/caches live under
`baremetal.workdir` (deleted; sentinel-guarded so a foreign directory is
never adopted or removed), and apt packages (driver, CUDA toolkit, DCGM,
python3-venv) are purged **only if this run installed them**; anything
pre-existing is used but never touched (including a DCGM engine that was
already running). `apt-get autoremove` runs only when the host had zero
autoremovable packages beforehand. A missing NVIDIA driver is installed
only when `baremetal.allow_driver_install: true` (default), and purged again
at cleanup. Needs egress (NVIDIA repo + pip + HF).

**Known limitation**: if the controller loses the connection mid-run
(UNREACHABLE), ansible cannot run the cleanup — re-run the pre phase to
redo the benchmark; note a driver installed by the interrupted run is then
detected as pre-existing and left in place (remove manually or reset the
host if a pristine OS is required).

NUMA-correct benchmarking (multi-socket hosts)
----------------------------------------------

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

Live bare-metal re-measure in the post run
------------------------------------------

Adding `'baremetal'` to `gpu_benchmark.llm_backends` makes the post run
refresh the physical numbers FIRST, on the deployed node, before the
appliance/k8s backends run: the node's GPUs are temporarily released from
`vfio-pci` (the persistent driverctl override is lifted), the NVIDIA
driver is installed, the exact pre-phase benchmark runs on the host
(hardware + LLM, NUMA-pinned, with the unsaturated-sweep retry), the
fresh numbers replace `gpu_baseline.json`, and cleanup restores the vfio
binding — override persistence included — before any VM is created. The
comparison then uses SAME-DAY, SAME-DRIVER physical data, eliminating the
"driver differs between runs" caveat.

Safety: a GPU attached to a running VM aborts the release with the
address named (terminate those VMs first); `nvidia-persistenced` is
stopped around every vfio (re)bind (a running persistenced wedges the
bind forever — hit live during a one-deploy install); an incomplete
restore is surfaced loudly in the report, since a node without vfio on
its GPUs cannot serve passthrough VMs. Cost: ~35-45 min per run (driver
install + model download on the host). The two-phase flow (pre before
deploy, post after) remains the default and needs none of this.

Kubernetes backend (bare-metal vs vLLM appliance vs K8s)
--------------------------------------------------------

`gpu_benchmark.llm_backends` selects which post-deploy backends run the
benchmark (default `['appliance']` — behavior identical to before the knob
existed). With `['k8s']` or `['appliance', 'k8s']` the role deploys an
RKE2 cluster **exactly per the OpenNebula 7.4 "AI-ready Kubernetes"
guide**: the `Service Capi` appliance (k3s management cluster with the
CAPONE provider), the `capone/capone-rke2` chart (0.1.7) with 1
control-plane + **one GPU worker per benchmarked GPU** (PCI passthrough by
vendor/class, device id auto-filled when uniform), the NVIDIA
`gpu-operator` (v25.3.2, the guide's containerd env for RKE2), and the
guide's CUDA verification Job on every worker as a hard gate. helm and
kubectl are installed on the frontend if missing (the guide's install
commands) and stay installed.

The one piece the guide stops short of — LLM serving — is a vLLM pod per
worker pinned to the SAME vLLM version as the baseline
(`vllm/vllm-openai:v<baremetal.vllm_version>`), with guidellm running
INSIDE the container against localhost using the shared profile: the same
tests, the same metrics, the same SLO gates, the same bare-metal
comparison. K8s results are keyed `<model> · k8s` and their overhead rows
are labeled `[k8s]`; with both backends in one run the report's overhead
table grows an environment column per backend (bare-metal | vLLM
appliance | Kubernetes), with a combined `Overhead % (vm / k8s)` column
and a Status column naming the breaching environment.

The hardware micro-benchmarks also run in-cluster (`k8s.hw_probe`,
default `true`): a one-shot Job per GPU worker with a CUDA **devel**
image (`k8s.cuda_devel_image`) compiles and runs the SAME
`cublas_sgemm.cu` + `pcie_bandwidth.cu` sources used by the health flow
and the results fill the Kubernetes cells of the cuBLAS / PCIe H2D /
PCIe D2H rows. Since K8s workers cannot be NUMA-pinned, the in-pod PCIe
number is the signal that attributes (or clears) NUMA placement when a
`[k8s]` LLM row breaches tolerance. The probe honors `cublas.enabled` /
`pcie_bw.enabled`, is bounded by `k8s.hw_probe_timeout_s`, and is
best-effort: a failure becomes a report caveat, never a lost benchmark.

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
`vm.vcpu`/`vm.memory_mb` (role defaults 8 vCPU/16 GiB; the validated
vgpu2 sizing raises them to 32 vCPU/64 GiB in its inventory), NOT the
guide's 12–16/32 examples; K8s workers are **not NUMA-pinned** (the chart
shares one worker template — the report states this caveat); the
functional API suite and power sampling are appliance/bare-metal-only in
v1. Everything is torn down afterwards (vLLM pods, workload cluster via
`helm uninstall`, the capi VM); the exported Service Capi template/image
stay for cheap re-runs. Budget ~30–45 min extra for the K8s stack.

Measurement honesty — the guidellm client is bimodal
----------------------------------------------------

The load generator itself (guidellm, pip-installed fresh in every VM/pod)
has two stable modes, proven live on identical hardware minutes apart: in
the slow mode the client wastes ~1.4 s per request slot, the capped
throughput probe under-measures by ~15%, and the rate ladder derived from
it stops BELOW the throughput knee — the whole run then under-reports
capacity by the same ~15% while the server-side token speed (ITL) is
byte-identical in both modes. The role defends in two layers:

* `parse_guidellm` detects the **unsaturated ladder** (the last constant
  rungs still climb linearly while the peak sits on the ladder tail) and
  marks the result `sweep_unsaturated` — treated everywhere exactly like
  a truncated sweep: a LOWER BOUND. SLO breaches become `inconclusive`
  (`*` in the report), GPU-to-GPU and bare-vs-virt gaps against the
  affected side are not flagged, and the report carries a caveat.
* `llm_retry_unsaturated` (default `true`) re-runs the sweep ONCE on the
  affected GPU and keeps the better curve. Capacity is a max-capability
  metric, so best-of-two removes the downward bias and cannot inflate
  the result; a failed retry never discards the first attempt.

Noise guards on every comparison: low sample counts, sub-floor throughput,
truncated/unsaturated sweeps (lower bounds), and sync-TTFT deltas below
`compare_min_ttft_delta_ms` (default 25 ms — the p95 of ~a dozen requests
jitters 10-20 ms on identical hardware; a relative spread/breach only flags
when the absolute delta is material too).

How results are judged
----------------------

Three independent signals; any of them turns the cluster status to `flag`
(reported as WARN — the role never hard-fails unless `fail_on_flag: true`):

1. **GPU-to-GPU comparison** (multi-GPU hosts only): every GPU runs the same
   benchmark; a card whose throughput drops below `best × (1 − llm_variance_pct/100)`
   or whose latency rises above `best × (1 + llm_variance_pct/100)` relative to
   the best card is flagged (default 20 %). cuBLAS has its own
   `cublas.variance_pct` (default 25 %). This is hardware-independent — the
   cards are their own reference. A single-GPU host has nothing to compare and
   shows no comparison. **Three noise guards** stop a false outlier when the
   data can't support the call: if the weakest GPU completed fewer than
   `compare_min_samples` successful requests (default 30) the whole comparison
   is marked low-confidence and nothing is flagged; a throughput spread
   below `compare_min_throughput_req_s` req/s (default 1.0) is treated as a
   tiny-denominator artifact, not a real difference (both observed on a slow
   2× T4 where 3-vs-4 requests produced a spurious 22 % "outlier"); and a
   GPU whose load sweep was **truncated** (guidellm derives its rate ladder
   from a short throughput probe, and the probe is chaotic in the overload
   region — seen live as 1467 vs 2807 tok/s on identical L40S cards, flipping
   between runs) suppresses the throughput comparison: its figures are a
   lower bound, not a measurement, and the report labels them as such. Sync
   latency metrics are unaffected and stay compared.
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
   width, PCIe transfer bandwidth below `pcie_bw.min_gbs`, and a failed
   DCGM diagnostic (`dcgm.level`, default 2).
4. **Functional API conformance** (`functional.enabled`): any failed endpoint
   test flags the model — a misbehaving API matters as much as slow metrics.
   An unrunnable suite is a visible failure, never a silent pass.

Informational (never flags): power/thermal profile under load and
tokens-per-watt per GPU, and the provisioning time (VM create → serving).

Avoiding false WARNs: hardware-calibrated reference SLOs
--------------------------------------------------------

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

### Calibration procedure for a NEW GPU model

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
tokens-per-request) measured under the BOUNDED probe
(`max_concurrency=128` in the shared profile). Values measured under
earlier profiles are NOT comparable and must not feed calibration: the
pre-2026-08 semantics read the overload-probe row (historic 5.9 req/s on
this GPU), and the unbounded 512-probe era measured ~10.9 req/s with
bimodal truncation artifacts. Re-measure before recalibrating.

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

Artifacts
---------

On the frontend, per run:

- `/tmp/gpu_benchmark/summary.json` — full structured results (the source of
  truth for calibration values);
- `/tmp/gpu_benchmark/<cluster>_<model>_h<host>_g<gpu>_guidellm.json` — raw
  GuideLLM reports (one per GPU);
- `*_failure.log` — auto-collected diagnostics when a benchmark fails;
- `k8s_failure<cluster>.log` — the redacted stdout/stderr tail of a failed
  K8s stack step (survives teardown), referenced from the report.

Testing
-------

`make test` runs a shell-lint gate (`test/gpu_benchmark/lint_shell.py`) and a
unit suite (`test/gpu_benchmark/test_logic.yml`) over all parsing/evaluation/
comparison logic. The suite must pass on **both** ansible-core 2.18 (hatch
env) and 2.21.
