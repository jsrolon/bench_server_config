#!/usr/bin/env bash

bench-fio --fio-path "/nutanix-nvme-bench/src/fio/fio" \
	--target /dev/nvme2n1p1 \
	--size 4g \
	--type device \
	--output="/nvme-fio/${runtime}results-$(date +%Y_%m_%d_%H_%M_%S)" \
	--mode read write randread randwrite \
	--iodepth 1 2 4 8 16 32 \
	--numjobs 1 2 4 8 16 24 31 \
	--engine io_uring \
	--time-based
