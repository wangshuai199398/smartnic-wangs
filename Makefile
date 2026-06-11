# RDMA SmartNIC 顶层构建入口。
# 当前阶段只提供可执行的占位目标，用来固定后续 RTL、驱动、用户态库和验证环境的统一入口。

.PHONY: all lint verilator cocotb pcie-test doorbell-test driver userspace regression coverage clean

all: lint driver userspace

lint:
	@echo "[lint] RTL 静态检查占位：后续会接入 Verilator lint、svlint 或厂商工具。"
	@test -f rtl/common/smartnic_pkg.sv

verilator:
	@echo "[verilator] Verilator 仿真构建占位：后续会编译 smartnic_top 和模块级测试平台。"

cocotb:
	@echo "[cocotb] 运行 Cocotb PCIe 控制面和 Doorbell 单元测试入口。"
	@$(MAKE) -C sim/cocotb pcie-control-plane-tests
	@$(MAKE) -C sim/cocotb doorbell-tests

pcie-test:
	@echo "[pcie-test] 运行 PCIe endpoint/control-plane 模块级测试入口。"
	@$(MAKE) -C sim/cocotb pcie-control-plane-tests

doorbell-test:
	@echo "[doorbell-test] 运行 Doorbell path 模块级测试入口。"
	@$(MAKE) -C sim/cocotb doorbell-tests

driver:
	@echo "[driver] 进入 Linux driver 子目录。"
	@$(MAKE) -C drivers/linux

userspace:
	@echo "[userspace] 进入 libsmartnic 用户态库子目录。"
	@$(MAKE) -C lib/libsmartnic

regression: lint verilator cocotb
	@echo "[regression] 已完成 lint、Verilator、Cocotb 组合回归入口。"

coverage:
	@echo "[coverage] 覆盖率报告占位：后续会汇总 Cocotb 功能覆盖率和 Verilator 覆盖率。"

clean:
	@echo "[clean] 清理构建产物占位。"
	@$(MAKE) -C drivers/linux clean
	@$(MAKE) -C lib/libsmartnic clean
	@$(MAKE) -C sim/cocotb clean
	@rm -rf build coverage .pytest_cache
