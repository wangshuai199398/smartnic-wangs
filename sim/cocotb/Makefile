# RDMA SmartNIC Cocotb PCIe 控制面单元测试入口。
#
# 这些测试是模块级最小行为测试，不建模完整 PCIe 协议。若本机尚未安装
# cocotb 或 Verilator，默认 pcie-control-plane-tests 目标会提示跳过。

SIM ?= verilator
TOPLEVEL_LANG ?= verilog
WAVES ?= 0

RTL_COMMON := ../../rtl/common/smartnic_pkg.sv

.PHONY: pcie-control-plane-tests doorbell-tests qp-tests cq-tests mr-tests dma-tests test-pcie-cfg test-pcie-bar test-csr-mailbox test-msix test-sriov test-doorbell-decoder test-doorbell-access test-sq-doorbell test-rq-doorbell test-cq-arm-doorbell test-qp-context test-qp-state-validator test-qp-lifecycle test-sq-engine test-rq-engine test-qp-cleanup test-qp-integration test-cq-context test-completion-engine test-cqe-write-path test-cq-index-manager test-cq-notification test-cq-integration test-mr-table test-mr-registration test-mr-deregistration test-mr-key-checker test-mr-access-checker test-mr-pd-checker test-memory-window test-mr-integration test-dma-descriptor-dispatcher test-dma-wqe-sge-fetcher clean

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
		$(MAKE) test-doorbell-decoder; \
		$(MAKE) test-doorbell-access; \
		$(MAKE) test-sq-doorbell; \
		$(MAKE) test-rq-doorbell; \
		$(MAKE) test-cq-arm-doorbell; \
	fi

qp-tests:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 cocotb，跳过 QP 单元测试。"; \
	elif ! command -v verilator >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 Verilator，跳过 QP 单元测试。"; \
	else \
		$(MAKE) test-qp-context; \
		$(MAKE) test-qp-state-validator; \
		$(MAKE) test-qp-lifecycle; \
		$(MAKE) test-sq-engine; \
		$(MAKE) test-rq-engine; \
		$(MAKE) test-qp-cleanup; \
		$(MAKE) test-qp-integration; \
	fi

cq-tests:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 cocotb，跳过 CQ 单元测试。"; \
	elif ! command -v verilator >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 Verilator，跳过 CQ 单元测试。"; \
	else \
		$(MAKE) test-cq-context; \
		$(MAKE) test-completion-engine; \
		$(MAKE) test-cqe-write-path; \
		$(MAKE) test-cq-index-manager; \
		$(MAKE) test-cq-notification; \
		$(MAKE) test-cq-integration; \
	fi

mr-tests:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 cocotb，跳过 MR 单元测试。"; \
	elif ! command -v verilator >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 Verilator，跳过 MR 单元测试。"; \
	else \
		$(MAKE) test-mr-table; \
		$(MAKE) test-mr-registration; \
		$(MAKE) test-mr-deregistration; \
		$(MAKE) test-mr-key-checker; \
		$(MAKE) test-mr-access-checker; \
		$(MAKE) test-mr-pd-checker; \
		$(MAKE) test-memory-window; \
		$(MAKE) test-mr-integration; \
	fi

dma-tests:
	@if ! command -v cocotb-config >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 cocotb，跳过 DMA 单元测试。"; \
	elif ! command -v verilator >/dev/null 2>&1; then \
		echo "[cocotb] 未安装 Verilator，跳过 DMA 单元测试。"; \
	else \
		$(MAKE) test-dma-descriptor-dispatcher; \
		$(MAKE) test-dma-wqe-sge-fetcher; \
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

test-doorbell-decoder:
	$(MAKE) TOPLEVEL=doorbell_decoder MODULE=test_doorbell_decoder \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/doorbell/doorbell_decoder.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-doorbell-access:
	$(MAKE) TOPLEVEL=doorbell_access_check MODULE=test_doorbell_access_check \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/doorbell/doorbell_access_check.sv" \
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

test-qp-context:
	$(MAKE) TOPLEVEL=qp_context_table MODULE=test_qp_context_table \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/qp_context_table.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-qp-state-validator:
	$(MAKE) TOPLEVEL=qp_state_validator MODULE=test_qp_state_validator \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/qp_state_validator.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-qp-lifecycle:
	$(MAKE) TOPLEVEL=qp_lifecycle_manager MODULE=test_qp_lifecycle \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/qp_context_table.sv ../../rtl/qp/qp_state_validator.sv ../../rtl/qp/qp_lifecycle_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-sq-engine:
	$(MAKE) TOPLEVEL=sq_engine MODULE=test_sq_engine \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/sq_engine.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-rq-engine:
	$(MAKE) TOPLEVEL=rq_engine MODULE=test_rq_engine \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/rq_engine.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-qp-cleanup:
	$(MAKE) TOPLEVEL=qp_cleanup_manager MODULE=test_qp_cleanup \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/qp_cleanup_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-qp-integration:
	$(MAKE) TOPLEVEL=qp_lifecycle_manager MODULE=test_qp_integration \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/qp/qp_context_table.sv ../../rtl/qp/qp_state_validator.sv ../../rtl/qp/qp_lifecycle_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-cq-context:
	$(MAKE) TOPLEVEL=cq_context_table MODULE=test_cq_context_table \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/cq/cq_context_table.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-completion-engine:
	$(MAKE) TOPLEVEL=completion_engine MODULE=test_completion_engine \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/cq/completion_engine.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-cqe-write-path:
	$(MAKE) TOPLEVEL=cqe_write_path MODULE=test_cqe_write_path \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/cq/cq_index_manager.sv ../../rtl/cq/cqe_write_path.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-cq-index-manager:
	$(MAKE) TOPLEVEL=cq_index_manager MODULE=test_cq_index_manager \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/cq/cq_index_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-cq-notification:
	$(MAKE) TOPLEVEL=cq_notification MODULE=test_cq_notification \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/cq/cq_notification.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-cq-integration:
	$(MAKE) TOPLEVEL=cq_integration_tb MODULE=test_cq_integration \
		VERILOG_SOURCES="cq_integration_tb.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-table:
	$(MAKE) TOPLEVEL=mr_table MODULE=test_mr_table \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_table.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-registration:
	$(MAKE) TOPLEVEL=mr_registration_manager MODULE=test_mr_registration \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_registration_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-deregistration:
	$(MAKE) TOPLEVEL=mr_deregistration_manager MODULE=test_mr_deregistration \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_deregistration_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-key-checker:
	$(MAKE) TOPLEVEL=mr_key_checker MODULE=test_mr_key_checker \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_key_checker.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-access-checker:
	$(MAKE) TOPLEVEL=mr_access_checker MODULE=test_mr_access_checker \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_access_checker.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-pd-checker:
	$(MAKE) TOPLEVEL=mr_pd_checker MODULE=test_mr_pd_checker \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_pd_checker.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-memory-window:
	$(MAKE) TOPLEVEL=mr_memory_window_manager MODULE=test_memory_window \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/mr/mr_memory_window_manager.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-mr-integration:
	$(MAKE) TOPLEVEL=mr_integration_tb MODULE=test_mr_integration \
		VERILOG_SOURCES="mr_integration_tb.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-dma-descriptor-dispatcher:
	$(MAKE) TOPLEVEL=dma_descriptor_dispatcher MODULE=test_dma_descriptor_dispatcher \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/dma/dma_descriptor_dispatcher.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

test-dma-wqe-sge-fetcher:
	$(MAKE) TOPLEVEL=dma_wqe_sge_fetcher MODULE=test_dma_wqe_sge_fetcher \
		VERILOG_SOURCES="$(RTL_COMMON) ../../rtl/dma/dma_wqe_sge_fetcher.sv" \
		-f $$(cocotb-config --makefiles)/Makefile.sim

clean:
	rm -rf sim_build results.xml __pycache__ .pytest_cache
