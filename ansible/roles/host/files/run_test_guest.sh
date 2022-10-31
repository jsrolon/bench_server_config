#!/usr/bin/env bash

set -e

if [[ "${EUID}" -ne 0 ]]
  then echo "Please run as root"
  exit 1
fi

dhclient # for the stupid no-internet thing with qemu (won't work if libvirtd on the host hasn't been restarted)
apt update
apt install -yqq libgflags-dev libsnappy-dev zlib1g-dev libbz2-dev liblz4-dev libzstd-dev libnuma-dev libssl-dev libaio-dev uuid-dev libjson-c-dev

clear

if [[ ! -f "/nutanix-src/dpdk-kmods/linux/igb_uio/igb_uio.ko" ]]; then
  cd "/nutanix-src/dpdk-kmods/linux/igb_uio/"
  make clean && make
fi

clear

# igb_uio won't init if we don't do this
modprobe uio

# add nvme configuration for rocksdb
mkdir -p /usr/local/etc/spdk/

# allocate enough hugepages and enable igb_uio driver
HUGEMEM=5120 PCI_ALLOWED="0000:$(lspci | awk '/Non-Volatile/ { print $1 }')" DRIVER_OVERRIDE="/nutanix-src/dpdk-kmods/linux/igb_uio/igb_uio.ko" /nutanix-src/spdk/scripts/setup.sh

rm -rf /nutanix-src/output
clear

# test script
/nutanix-src/spdk/test/blobfs/rocksdb/rocksdb.sh

results_target_location="/nvme-fio/results/rocksdb/$(cat /etc/libvirt_domain_name)_$(date +%Y_%b_%d_%H%M%S)"
mkdir -p "${results_target_location}"
mv /nutanix-src/output/* "${results_target_location}"
rm -rf /nutanix-src/output/
