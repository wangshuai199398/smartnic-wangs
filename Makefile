# RDMA SmartNIC 顶层构建入口。
# 当前阶段只提供可执行的占位目标，用来固定后续 RTL、驱动、用户态库和验证环境的统一入口。

.PHONY: all lint verilator cocotb pcie-test doorbell-test qp-test cq-test mr-test dma-test packet-test transport-test driver userspace regression coverage clean

all: lint driver userspace

lint:
	@echo "[lint] RTL 静态检查占位：后续会接入 Verilator lint、svlint 或厂商工具。"
	@test -f rtl/common/smartnic_pkg.sv

verilator:
	@echo "[verilator] Verilator 仿真构建占位：后续会编译 smartnic_top 和模块级测试平台。"

cocotb:
	@echo "[cocotb] 运行 Cocotb PCIe 控制面、Doorbell、QP、CQ、MR、DMA、Packet parser 和 Transport 单元测试入口。"
	@$(MAKE) -C sim/cocotb pcie-control-plane-tests
	@$(MAKE) -C sim/cocotb doorbell-tests
	@$(MAKE) -C sim/cocotb qp-tests
	@$(MAKE) -C sim/cocotb cq-tests
	@$(MAKE) -C sim/cocotb mr-tests
	@$(MAKE) -C sim/cocotb dma-tests
	@$(MAKE) -C sim/cocotb packet-tests
	@$(MAKE) -C sim/cocotb transport-tests

pcie-test:
	@echo "[pcie-test] 运行 PCIe endpoint/control-plane 模块级测试入口。"
	@$(MAKE) -C sim/cocotb pcie-control-plane-tests

doorbell-test:
	@echo "[doorbell-test] 运行 Doorbell path 模块级测试入口。"
	@$(MAKE) -C sim/cocotb doorbell-tests

qp-test:
	@echo "[qp-test] 运行 QP manager 模块级测试入口。"
	@$(MAKE) -C sim/cocotb qp-tests

cq-test:
	@echo "[cq-test] 运行 CQ manager 模块级测试入口。"
	@$(MAKE) -C sim/cocotb cq-tests

mr-test:
	@echo "[mr-test] 运行 MR manager 模块级测试入口。"
	@$(MAKE) -C sim/cocotb mr-tests

dma-test:
	@echo "[dma-test] 运行 DMA engine 模块级测试入口。"
	@$(MAKE) -C sim/cocotb dma-tests

packet-test:
	@echo "[packet-test] 运行 RoCEv2 packet parser 模块级测试入口。"
	@$(MAKE) -C sim/cocotb packet-tests

transport-test:
	@echo "[transport-test] 运行 RoCEv2 transport 模块级测试入口。"
	@$(MAKE) -C sim/cocotb transport-tests

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
