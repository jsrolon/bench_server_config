#!/usr/bin/env bash

## This script is meant to be run inside the discslab server
## we assume that spdk & multiprocess qemu have been cloned and built

set -e

if [[ "${EUID}" -ne 0 ]]
  then echo "Please run as root"
  exit 1
fi

run_test_guest="true"
while getopts "n:dt" opt; do
  case $opt in
    n)
      vm_name=${OPTARG}
      ;;
    d)
      run_test_guest="false"
      ;;
    t)
      tracing_string="-e all"
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      ;;
  esac
done

if [[ -z ${vm_name} ]]; then
  echo "-n VM_NAME -d To disable running tests inside guest -t For enabling tracing"
  exit 1
fi

# we need to verify that we're running using the same versions of everything always
spdk_path="/nutanix-src/spdk"
spdk_req_version="v22.01.x"
spdk_req_origin="git@github.com:jsrolon/spdk.git"
spdk_version=$(git -C "${spdk_path}" rev-parse --abbrev-ref HEAD)
spdk_origin=$(git -C "${spdk_path}" remote get-url origin)
if ${run_test_guest} && [[ "${spdk_version}" != "${spdk_req_version}" || "${spdk_origin}" != "${spdk_req_origin}" ]]; then
  echo "Current SPDK ${spdk_version} from ${spdk_origin} is not expected, required is ${spdk_req_version} from ${spdk_req_origin}"
  exit 2
fi

qemu_req_version="QEMU emulator version 6.2.0 (Debian 1:6.2+dfsg-2ubuntu8~20.04.sav0)"
qemu_ver=$(qemu-system-x86_64 --version | head -n1)
if [[ "${qemu_ver}" != "${qemu_req_version}" ]]; then
  echo "Current qemu-system-x86_64 ${qemu_ver} is not expected, required is ${qemu_req_version}"
  exit 2
fi

# drop all caches just to make sure
sync; echo 3 > /proc/sys/vm/drop_caches

vm_os_image="/nvme-fio/bench_server_config/images/qemu-${vm_name}.qcow"
if [[ "${vm_name}" != "baremetal" && ! -f "${vm_os_image}" ]]; then
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
    ${spdk_path}/build/bin/nvmf_tgt ${tracing_string} -m '[32, 33, 34, 35]' &
  nvmf_tgt_pid="$!"

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

  if [[ ! -z "${tracing_string}" ]]; then
    record_trace_path="/tmp/spdk_nvmf_record.trace.$(date +%s)"
    ${spdk_path}/build/bin/spdk_trace_record -q -s nvmf -p "${nvmf_tgt_pid}" -f "${record_trace_path}"
    echo "Writing trace to ${record_trace_path}"
  fi
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

if [[ "${vm_name}" != "baremetal" ]]; then
  # run the vm
  if ! virsh list --all --name | grep "${vm_name}"; then
    echo "### creating VM..."

    # Reload cloud-config settings
    images_path="/nvme-fio/bench_server_config/images"
    rm -rf "${images_path}/user-data.img"
    # ugly sed-replacement cause we need to modify the user data
    cloud-localds "${images_path}/user-data.img" <(sed -e "s/___LIBVIRT_DOMAIN_NAME___/${vm_name}/" -e "s/___RUN_TEST_GUEST___/${run_test_guest}/" "${images_path}/user-data")

    virsh create "/nvme-fio/bench_server_config/ansible/roles/host/files/libvirt_xml/qemu-${vm_name}.xml"

    # required for internet access in the guests, paired with running dhclient inside the guest
    systemctl restart libvirtd

    if ${run_test_guest}; then
      # control has been given to the scripts inside the guest, we'll wait until it reports that it has finished
      done_file_location="/nutanix-src/test_done"
      while [[ ! -f "${done_file_location}" ]]; do
        sleep 30
      done
      rm -f "${done_file_location}"
    fi
  fi
else
  # apparently json config file doesnt generate correctly if this doesnt run first
  PCI_ALLOWED="0000:bc:00.0" ${spdk_path}/scripts/setup.sh

  BAREMETAL=1 ${spdk_path}/test/blobfs/rocksdb/rocksdb.sh

  # move results into /nvme-fio
  results_target_location="/nvme-fio/results/rocksdb/baremetal_$(date --utc +%Y_%m_%d_%H%M%S)"
  echo "### Moving test results to ${results_target_location}..."
  mkdir -p "${results_target_location}"
  mv /nutanix-src/output/* "${results_target_location}"
  chown -R jrolon:nogroup "${results_target_location}" # needed for syncthing
  rm -rf /nutanix-src/output/
fi
