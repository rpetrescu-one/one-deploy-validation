[//]: # ( vim: set wrap : )

# one-deploy-validation

This repository provides a toolset for automating the validation of an OpenNebula deployment.

## Requirements

We recommend using Ubuntu 22.04 or 24.04 as the host OS, where the validation is initiated.
The following packages must be installed on the host:

- `git`
- `python3`
- `python3-pip`
- `python3-venv`
- `make`

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

## Playbooks/Roles

The development of the tests should be structured in [playbooks](./playbooks/) and [roles](./roles/) directories, following Ansible.
The available test cases are briefly documented together with their key configuration parameters in [all.yml](./inventory/reference/group_vars/all.yml).

## Inventory/Execution

1. Inventories are kept in the [inventory](./inventory/) directory, please take a look at [example.yml](./inventory/reference/example.yml)

2. Customize the configuration of the validation testcases by setting the enabler flags (`validation.run_*` booleans) in [all.yml](./inventory/reference/group_vars/all.yml). This file contains the recommended configuration that should be tested on most deployments. Always intend to enable all testcases that are relevant for the deployment (for example, if VM HA or FE HA are configured, enable those testcases as well). 
If any testcase is disabled compared to the current [all.yml](./inventory/reference/group_vars/all.yml), please provide justification in addition to the generated HTML reports.

3. Fill in the report details such as customer name, version, abstract etc.. in ./playbooks/report_input_vars.yml.example. Make a copy and reference that copy during the execution step.

4. To execute `ansible-playbook` using the example template you can run

   ```shell
   make I=inventory/reference/example.yml validation ANSIBLE_ARGS="-e @playbooks/report_input_vars.yml.example"
   ```
Ensure that your Python virtual environment is activated before running the playbook.

## Multi-cluster deployments

The validation is cluster aware. Every OpenNebula cluster that has at least
one host is validated in a single run: tests that create VMs (test VM,
connectivity matrix, network validation, storage benchmark, VM HA, OneFlow)
run once per cluster and only use that cluster's hosts, datastores and
virtual networks. Marketplace images are exported once per cluster (suffixed
with the cluster name when more than one cluster is validated) and report
entries are suffixed with ` — cluster <name>`.

Optional inventory settings (`validation.clusters`,
`validation.cluster_overrides`) restrict the cluster list or pin a specific
vnet/image datastore per cluster — see
`inventory/reference/group_vars/all.yml`.

## Validation Results

The execution of the all the tests produces the following output files on the Ansible controller (e.g. laptop):

- `/tmp/cloud_verification_report.html`
- `/tmp/cloud_verification_report.pdf`
- `/tmp/conn-matrix-raw-data.json` (when connectivity matrix validation is enabled; HTML results are included in `/tmp/cloud_verification_report.html`)
- `/tmp/fe_ha_report.html`
