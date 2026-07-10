gpu-benchmark
=============

GPU / LLM inference benchmark for AI Factory validation. Per GPU-bearing host
it runs:

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
```

See `defaults/main.yml` for every knob and
`inventory/reference/group_vars/all.yml` for a documented example.

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
   shows no comparison. **Two noise guards** stop a false outlier when the data
   can't support the call: if the weakest GPU completed fewer than
   `compare_min_samples` successful requests (default 30) the whole comparison
   is marked low-confidence and nothing is flagged; and a throughput spread
   below `compare_min_throughput_req_s` req/s (default 1.0) is treated as a
   tiny-denominator artifact, not a real difference (both observed on a slow
   2× T4 where 3-vs-4 requests produced a spurious 22 % "outlier").
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
        min_throughput_req_s: 4.5         # profile) inherit the global values
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

### Measured values (healthy hardware, vLLM 0.10.2 / guidellm 0.7.1)

| GPU | Model | TTFT p95 sync (ms) | Throughput (req/s) | ITL p95 (ms) | cuBLAS (GFLOP/s) | Gates (validated) |
|---|---|---|---|---|---|---|
| NVIDIA L40S | Qwen/Qwen2.5-3B-Instruct | 37.5 (warm¹; 50–69 at constant rates) | 5.9 (stable, 6 runs) | 10.6–10.8 | 56 827–57 354 | ttft 200, thr 4.5 — PASS with ~5× TTFT headroom |

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
- `*_failure.log` — auto-collected diagnostics when a benchmark fails.

Testing
-------

`make test` runs a shell-lint gate (`test/gpu_benchmark/lint_shell.py`) and a
unit suite (`test/gpu_benchmark/test_logic.yml`) over all parsing/evaluation/
comparison logic. The suite must pass on **both** ansible-core 2.18 (hatch
env) and 2.21.
