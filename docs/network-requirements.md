# Network requirements & whitelist

External domains each part of the validation may contact. Whitelist the rows for
the tests you enable; everything not listed here is internal to the deployment
(oned/OneFlow/OneGate/FireEdge ports, ssh, node↔node iperf3/ICMP, test-VM IPs).

## Per-role domain dependencies

| Role / area | External domains | How to avoid |
|---|---|---|
| environment setup (controller, one-time) | distro mirrors · `github.com` · `pypi.org` · `files.pythonhosted.org` · `galaxy.ansible.com` | prepare `.venv` + `collections/` on a connected host |
| report render (every run) | `fonts.googleapis.com` · `fonts.gstatic.com` | nothing needed — falls back to system fonts if blocked |
| test_vm | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` | pre-register the template `<market_name><cluster-suffix>` |
| validation (core services) | distro mirrors (frontend: `jq`, `jc`) | preinstall the packages |
| network_validation | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` · `dl-cdn.alpinelinux.org` (in-VM `apk`) · `validation.network.ext_host` (default `google.com`, ICMP) · vnet DNS (default `8.8.8.8`) | pre-register template; image with `bind-tools jq jc` preinstalled; internal `ext_host`/DNS |
| storage-benchmark | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` · `dl-cdn.alpinelinux.org` (in-VM `apk add fio`) · DNS `1.1.1.1`/`8.8.8.8` | pre-register template; `skip_fio_install: true` + fio-preinstalled image |
| network-benchmark | distro mirrors (nodes: `iperf3`, `jq`, `jc`) | preinstall on nodes |
| conn_matrix | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` · distro mirrors (nodes: `jq`, `jc`) | pre-register template; preinstall |
| oneflow_validation | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` (fallback export only) | run test_vm first or pre-register the template |
| ldap_auth | distro mirrors (frontend: `ldap-utils`/`openldap-clients`, `curl`) · your LDAP server (`validation.ldap_auth.server`) | preinstall; LDAP server is site infrastructure |
| vm-ha | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` · optional: the `node_power_on_cmd` endpoint (BMC/IPMI/cloud API, operator-supplied) | pre-register template |
| fe_ha | distro mirrors (frontend: `jq`) | preinstall |
| federation | none — internal only (FE↔FE `:2633` between zones, possibly over WAN) | whitelist FE↔FE 2633 across sites |
| gpu-benchmark (all backends) | `marketplace.opennebula.io` · `d24fmfybwxpuhu.cloudfront.net` · `developer.download.nvidia.com` · `pypi.org` · `files.pythonhosted.org` · `huggingface.co` · `cdn-lfs*.huggingface.co` · `*.xethub.hf.co` | pre-registered appliances; `allow_*: false` flags + preinstalled CUDA/DCGM; local PyPI/HF mirrors |
| gpu-benchmark (k8s backend, additionally) | `raw.githubusercontent.com` · `get.helm.sh` · `dl.k8s.io` / `cdn.dl.k8s.io` · `opennebula.github.io` · `helm.ngc.nvidia.com` · `docker.io` (`registry-1.docker.io`, `auth.docker.io`) · `nvcr.io` · `ghcr.io` · `quay.io` · `registry.rancher.com` · `registry.k8s.io` · `archive.ubuntu.com` · `security.ubuntu.com` | preinstall helm/kubectl; private registry mirror (registries are not repo-configurable) |

Notes:

- **Marketplace rows** apply once per cluster and only when no template named
  `<market_name><cluster-suffix>` exists — the export precheck skips all
  marketplace/CDN access when you pre-register it. `d24fmfybwxpuhu.cloudfront.net`
  is the appliance-download CDN behind the public marketplace; recommend
  whitelisting `*.opennebula.io` plus that host.
- **Distro mirrors** depend on each machine's configured repos (apt/dnf); package
  installs are no-ops when the tool is already present (exception:
  network-benchmark always runs `apt-get update` on Debian-family nodes).
- **DNS IPs** (`8.8.8.8`, `1.1.1.1`) are defaults written into the suite vnet /
  the storage-benchmark VM's resolv.conf; the vnet one is configurable
  (`validation.test_vm.vnet.dns`), the storage ones disappear with
  `skip_fio_install`.
- **gpu-benchmark** k8s registries come baked into the Capi/RKE2/gpu-operator
  stack, not from this repo's inventory — air-gap requires a mirror.

## Minimal air-gapped run (everything except GPU)

1. Pre-register the test template(s) per cluster under the exact expected name —
   removes all marketplace/CDN access.
2. Preinstall: `jq jc` (frontends), `iperf3 jq jc` (nodes), `ldap-utils` +
   `curl` (frontend, if ldap_auth runs).
3. Use a VM image with `fio`, `bind-tools`, `jq`, `jc` preinstalled and set
   `validation.storage_benchmark.skip_fio_install: true`.
4. Point `validation.network.ext_host` and `validation.test_vm.vnet.dns` at
   internal hosts.
5. Fonts need nothing — the report falls back to system fonts.
