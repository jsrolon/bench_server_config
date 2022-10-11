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

if [[ "${vm_name}" == "vfio-user" ]]; then
  # stop the spdk process
  pkill --signal TERM --oldest --full 'nvmf_tgt'
fi

# destroy vm
until virsh destroy "qemu-${vm_name}"; do
  pkill --signal TERM --oldest --full "qemu-${vm_name}"
  sleep 3 # wait until it's dead
done

# had to wait until after qemu is done using the mountpoint
if [[ "${vm_name}" == "scsi" ]]; then
  umount /dev/nvme2n1p1

  # clear nvme partition table
  wipefs -a /dev/nvme2n1
fi

# return nvme control to the kernel
HUGEMEM=24000 PCI_ALLOWED="0000:bc:00.0" ${spdk_path}/scripts/setup.sh reset
