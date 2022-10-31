#!/usr/bin/env bash

## This script is meant to be run inside the discslab server
## we assume that spdk & multiprocess qemu have been cloned and built

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

vm_os_image="/nvme-fio/bench_server_config/images/qemu-${vm_name}.qcow"
if [[ ! -f "${vm_os_image}" ]]; then
  qemu-img create -f qcow2 "${vm_os_image}" 10G
fi

# the following is https://github.com/nutanix/libvfio-user/blob/master/docs/spdk.md
if [[ "${vm_name}" == "vfio-user" ]]; then
  # we need spdk to have been built correctly
  # ${spdk_path}/configure --with-vfio-user

  # give control of the nvme to vfio instead of the kernel
  # assign 24GB of hugepages
  HUGEMEM=24000 PCI_ALLOWED="0000:bc:00.0" ${spdk_path}/scripts/setup.sh

  echo "### waiting for 12000 hugepages of 2048KiB to be allocated..."
  until [[ $(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo) -eq "12000" ]]; do
    sleep 3
  done

  # run the nvmeof target process (the one that listens to i/o requests) and pin it to 4 cores
  LD_LIBRARY_PATH="${spdk_path}/build/lib:${spdk_path}/dpdk/build/lib"  \
    ${spdk_path}/build/bin/nvmf_tgt -m '[32, 33, 34, 35]' &

  echo "### waiting until the spdk process is ready..."
  until ${spdk_path}/scripts/rpc.py framework_wait_init > /dev/null; do
    sleep 3
  done

  # remote procedure calls to the nvmf process to configure the bdev to talk to the physical nvme
  rm -f /var/run/{cntrl,bar0}
  ${spdk_path}/scripts/rpc.py nvmf_create_transport -t VFIOUSER
  ${spdk_path}/scripts/rpc.py bdev_nvme_attach_controller -b NVMe0 -t PCIe -a "0000:bc:00.0"
  ${spdk_path}/scripts/rpc.py nvmf_create_subsystem nqn.2019-07.io.spdk:cnode0 -a -s SPDK0
  ${spdk_path}/scripts/rpc.py nvmf_subsystem_add_ns nqn.2019-07.io.spdk:cnode0 NVMe0n1
  ${spdk_path}/scripts/rpc.py nvmf_subsystem_add_listener nqn.2019-07.io.spdk:cnode0 -t VFIOUSER -a /var/run -s 0
elif [[ "${vm_name}" == "scsi" || "${vm_name}" == "dummy-nvme" ]]; then
  # make sure we're using the kernel driver
  PCI_ALLOWED="0000:bc:00.0" ${spdk_path}/scripts/setup.sh reset
  sleep 2

  # give gpt partition label + partition the disk + make it ext4
  parted --align optimal --script /dev/nvme2n1 mklabel gpt
  parted --align optimal --script /dev/nvme2n1 mkpart primary 0% 100%
  sleep 2
  yes | mkfs -t ext4 /dev/nvme2n1p1

  # mount nvme like a normal decent person
  mount /dev/nvme2n1p1 /mnt/jrolon/nvme

  # set up test disk
  test_image="/mnt/jrolon/nvme/test.qcow"
  rm -rf "${test_image}"
  qemu-img create -f qcow2 "${test_image}" 325G # needs to be large or we get rocksdb segfaults
fi

# run the vm
if ! virsh list --all --name | grep "${vm_name}"; then
  echo "### creating VM..."

  # Reload cloud-config settings
  images_path="/nvme-fio/bench_server_config/images"
  rm -rf "${images_path}/user-data.img"
  # ugly sed-replacement cause we need to get the vm name inside somehow
  cloud-localds "${images_path}/user-data.img" <(sed "s/___LIBVIRT_DOMAIN_NAME___/${vm_name}/" "${images_path}/user-data")

  virsh create "/nvme-fio/bench_server_config/ansible/roles/host/files/libvirt_xml/qemu-${vm_name}.xml"

  # required for internet access in the guests
  systemctl restart libvirtd
fi