#!/usr/bin/env bash

set -e

if [[ "${EUID}" -ne 0 ]]
  then echo "Please run as root"
  exit 1
fi

vm_name="${1}"
if [[ -z "${vm_name}" ]]; then
  echo "Need vm name"
  exit 1
fi

spdk_path="/nutanix-src/spdk"

# stop the spdk process
pkill --signal INT --oldest --full 'nvmf_tgt'

# destroy vm
pkill --signal INT --oldest --full "qemu-${vm_name}"

# return nvme control to the kernel
HUGEMEM=24000 PCI_ALLOWED="0000:bc:00.0" ${spdk_path}/scripts/setup.sh reset
