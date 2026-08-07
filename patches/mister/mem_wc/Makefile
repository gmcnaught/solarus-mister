# Out-of-tree build for the mem_wc write-combining /dev/mem driver.
#
# Build against the MiSTer kernel source, cross-compiled with the same Arm
# 10.2-2020.11 toolchain the kernel itself was built with (check /proc/version
# on the device):
#
#   make KDIR=/path/to/Linux-Kernel_MiSTer
#
# KDIR must be a kernel tree that has had `make modules_prepare` run against the
# DEVICE'S OWN /proc/config.gz, so vermagic matches exactly. The running kernel
# has CONFIG_MODVERSIONS and CONFIG_MODULE_SIG off, so no symbol-CRC matching
# and no signing are needed -- only the vermagic string. See README.md.

obj-m := mem_wc.o

# Kernel source / build tree. Override on the command line as needed.
KDIR ?= /lib/modules/$(shell uname -r)/build

ARCH          ?= arm
CROSS_COMPILE ?= /opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-

PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

# Promote a fresh build into the committed set, named for the vermagic it will
# be checked against, with debug info stripped -- that is 128 KB of the 133 KB
# and none of it reaches the kernel. deploy.py picks from prebuilt/ by the
# device's `uname -r` when there is no local build, so a MiSTer kernel bump is
# "run this again on the new kernel and commit the new file", never "the old
# object silently fails to insmod in the field".
#
#   make prebuilt KDIR=/path/to/Linux-Kernel_MiSTer
prebuilt: all
	@rel=$$(strings mem_wc.ko | sed -n 's/^vermagic=\([^ ]*\).*/\1/p'); \
	test -n "$$rel" || { echo "could not read vermagic from mem_wc.ko"; exit 1; }; \
	mkdir -p prebuilt; \
	$(CROSS_COMPILE)strip --strip-debug mem_wc.ko -o prebuilt/mem_wc-$$rel.ko; \
	ls -l prebuilt/mem_wc-$$rel.ko

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) clean

.PHONY: all prebuilt clean
