# Standard two-phase kbuild Makefile: DKMS invokes the else-branch with an
# explicit KVER so the build never depends on the builder's running kernel.
ifneq ($(KERNELRELEASE),)
obj-m := try_omarchy_battery.o
try_omarchy_battery-y := try-omarchy-battery.o
else
KVER ?= $(shell uname -r)
KDIR ?= /usr/lib/modules/$(KVER)/build

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
endif
