#!/usr/bin/env bash

set -e

if [[ "${EUID}" -ne 0 ]]
  then echo "Please run as root"
  exit 1
fi

for guest_name in baremetal hostdev vfio-user dummy-nvme; do
  echo "### Currently running ${guest_name}"
  ./run_vm.sh "${guest_name}"
  ./cleanup_vm.sh "${guest_name}"
done
