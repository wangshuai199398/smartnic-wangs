# Linux driver 构建入口。
# 如果本机有 Linux kernel headers，则构建 out-of-tree module；
# 否则运行静态检查并跳过真实 Kbuild，方便缺少 kernel headers 的环境继续验证结构。

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(CURDIR)

ccflags-y += -I$(src)/../../include

obj-m := smartnic.o
smartnic-y := smartnic_pci.o smartnic_mbox.o smartnic_chrdev.o smartnic_irq.o smartnic_dma.o smartnic_queue.o
smartnic-$(CONFIG_SMARTNIC_KUNIT) += smartnic_kunit.o

.PHONY: all modules syntax-check clean

all: syntax-check modules

modules:
	@if [ -f "$(KDIR)/Makefile" ]; then \
		echo "[drivers/linux] 构建 SmartNIC out-of-tree kernel module。"; \
		$(MAKE) -C "$(KDIR)" M="$(PWD)" modules; \
	else \
		echo "[drivers/linux] 未找到 Linux kernel headers，跳过真实 Kbuild。"; \
	fi

syntax-check:
	@python3 tests/test_smartnic_pci_driver_static.py
	@python3 tests/test_smartnic_driver_lifecycle_static.py
	@python3 tests/test_smartnic_driver_error_paths_static.py

clean:
	@if [ -f "$(KDIR)/Makefile" ]; then \
		$(MAKE) -C "$(KDIR)" M="$(PWD)" clean; \
	else \
		echo "[drivers/linux] 未找到 Linux kernel headers，跳过 Kbuild clean。"; \
	fi
	@rm -f *.o *.ko *.mod *.mod.c *.order *.symvers .*.cmd
