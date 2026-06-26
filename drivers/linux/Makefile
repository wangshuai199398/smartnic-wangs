# Linux driver 构建入口。
# 如果本机有 Linux kernel headers，则构建 out-of-tree module；
# 否则运行静态检查并跳过真实 Kbuild，方便缺少 kernel headers 的环境继续验证结构。

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(CURDIR)

ccflags-y += -I$(src)/../../include

obj-m := smartnic.o
smartnic-y := smartnic_pci.o smartnic_mbox.o smartnic_chrdev.o smartnic_irq.o smartnic_dma.o smartnic_queue.o
smartnic-$(CONFIG_SMARTNIC_KUNIT) += smartnic_kunit.o

.PHONY: all modules syntax-check static-check checkpatch sparse-check release-check clean

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

static-check: syntax-check
	@echo "[drivers/linux] 静态合同检查完成。"

sparse-check:
	@if [ -f "$(KDIR)/Makefile" ] && command -v sparse >/dev/null 2>&1; then \
		echo "[drivers/linux] 使用 sparse 进行 C=1 检查。"; \
		$(MAKE) -C "$(KDIR)" M="$(PWD)" C=1 modules; \
	else \
		echo "[drivers/linux] sparse 或 Linux kernel headers 不可用，跳过 sparse 检查。"; \
	fi

checkpatch:
	@if [ -x "$(KDIR)/scripts/checkpatch.pl" ]; then \
		echo "[drivers/linux] 运行 checkpatch。"; \
		perl "$(KDIR)/scripts/checkpatch.pl" --no-tree --strict --file smartnic_*.c smartnic_*.h Kconfig Makefile; \
	else \
		echo "[drivers/linux] 未找到 checkpatch.pl，跳过 checkpatch。"; \
	fi

release-check: static-check modules sparse-check checkpatch
	@echo "[drivers/linux] 发布前 driver 检查完成。"

clean:
	@if [ -f "$(KDIR)/Makefile" ]; then \
		$(MAKE) -C "$(KDIR)" M="$(PWD)" clean; \
	else \
		echo "[drivers/linux] 未找到 Linux kernel headers，跳过 Kbuild clean。"; \
	fi
	@rm -f *.o *.ko *.mod *.mod.c *.order *.symvers .*.cmd
