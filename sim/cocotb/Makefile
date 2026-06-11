# RDMA SmartNIC Cocotb PCIe 控制面单元测试入口。
#
# 这些测试是模块级最小行为测试，不建模完整 PCIe 协议。若本机尚未安装
# cocotb 或 Verilator，默认 pcie-control-plane-tests 目标会提示跳过。

SIM ?= verilator
TOPLEVEL_LANG ?= verilog
WAVES ?= 0

RTL_COMMON := ../../rtl/common/smartnic_pkg.sv

.PHONY: pcie-control-plane-tests doorbell-tests test-pcie-cfg test-pcie-bar test-csr-mailbox test-msix test-sriov test-sq-doorbell test-rq-doorbell test-cq-arm-doorbell clean

pcie-control-plane-tests:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 cocotb，跳过 PCIe 控制面单元测试。"; \
	elif ! command -v verilator >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 Verilator，跳过 PCIe 控制面单元测试。"; \
	else \
		$(MAKE) test-pcie-cfg; \
		$(MAKE) test-pcie-bar; \
		$(MAKE) test-csr-mailbox; \
		$(MAKE) test-msix; \
		$(MAKE) test-sriov; \
	fi

doorbell-tests:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 cocotb，跳过 Doorbell 单元测试。"; \
	elif ! command -v verilator >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 Verilator，跳过 Doorbell 单元测试。"; \
	else \
		$(MAKE) test-sq-doorbell; \
		$(MAKE) test-rq-doorbell; \
		$(MAKE) test-cq-arm-doorbell; \
	fi

test-pcie-cfg:
	$(MAKE) TOPLEVEL=pcie_cfg_space MODULE=test_pcie_cfg_space \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/pcie/pcie_cfg_space.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-pcie-bar:
	$(MAKE) TOPLEVEL=pcie_bar_decoder MODULE=test_pcie_bar_decoder \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/pcie/pcie_bar_decoder.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-csr-mailbox:
	$(MAKE) TOPLEVEL=pcie_csr_mailbox MODULE=test_csr_mailbox \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/reg/pcie_csr_mailbox.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-msix:
	$(MAKE) TOPLEVEL=pcie_msix MODULE=test_msix \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/pcie/pcie_msix.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-sriov:
	$(MAKE) TOPLEVEL=pcie_function_manager MODULE=test_sriov_function_manager \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/pcie/pcie_function_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-sq-doorbell:
	$(MAKE) TOPLEVEL=sq_doorbell_handler MODULE=test_sq_doorbell \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/doorbell/sq_doorbell_handler.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-rq-doorbell:
	$(MAKE) TOPLEVEL=rq_doorbell_handler MODULE=test_rq_doorbell \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/doorbell/rq_doorbell_handler.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-cq-arm-doorbell:
	$(MAKE) TOPLEVEL=cq_arm_doorbell_handler MODULE=test_cq_arm_doorbell \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/doorbell/cq_arm_doorbell_handler.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

clean:
	rm -rf sim_build results.xml __pycache__ .pytest_cache
