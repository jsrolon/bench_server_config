# Repo for VM NVMe performance testing

The objective of this repo is to run as few commands as possible to trigger all the configured test scenarios.

### 1. Ansible host provisioning

From the local machine, run ansible-playbook to get the server ready to start performing benchmarks:

```commandline
ansible-playbook playbook.yml -i hosts 
```
