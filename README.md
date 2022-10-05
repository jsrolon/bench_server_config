# Repo for VM NVMe performance testing

The objective of this repo is to run a single command to trigger all the configured test scenarios.

The execution flow is meant to be:

```
Ansible Host Provisioning -> VM Setup Script -> cloud-init VM Provisioning -> Benchmarking Script
```

VMs are set up and benchmarking is run for them individually.
