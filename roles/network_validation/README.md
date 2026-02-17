Role Name
=========

OpenNebula cloud verification role.

Requirements
------------

Ansible inventory, used for the cloud deployment should be used with this playbook

Role Variables
--------------


Example Playbook
----------------

This role validates all configured OpenNebula vNets and checks for:
- connection from VM to default GW
- DNS resolution from VM using DNS server specified for the network
- Connectivity to the external host by pinging that host 

Important!!!
These network checks rely on ping for connectivity checks, thus ICMP messages should be allowed on the infrastructure level

This role should be included into the target playbook, like the following:

  - hosts: "{{ frontend_group | d('frontend') }}"
    roles:
      - role: network_validation

License
-------

BSD

Author Information
------------------

OpenNebula team
