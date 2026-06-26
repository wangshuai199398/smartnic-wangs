`timescale 1ns/1ps

module smartnic_top
    import smartnic_pkg::*;
#(
    parameter logic [47:0] LOCAL_MAC  = 48'h02_00_00_00_00_01,
    parameter logic [47:0] PEER_MAC   = 48'h02_00_00_00_00_02,
    parameter logic [31:0] LOCAL_IPV4 = 32'h0a00_0001,
    parameter logic [31:0] PEER_IPV4  = 32'h0a00_0002
) (
    input  logic                         clk,
    input  logic                         rst_n,

    // 简化 PCIe hard-IP TLP 流接口；完整 BAR/CSR/DMA 连接留给 11.2。
    input  logic                         pcie_rx_valid,
    output logic                         pcie_rx_ready,
    input  logic [PCIE_TLP_DATA_W-1:0]   pcie_rx_data,
    input  logic [PCIE_TLP_KEEP_W-1:0]   pcie_rx_keep,
    input  logic                         pcie_rx_last,
    input  logic [PCIE_TLP_USER_W-1:0]   pcie_rx_user,
    output logic                         pcie_tx_valid,
    input  logic                         pcie_tx_ready,
    output logic [PCIE_TLP_DATA_W-1:0]   pcie_tx_data,
    output logic [PCIE_TLP_KEEP_W-1:0]   pcie_tx_keep,
    output logic                         pcie_tx_last,
    output logic [PCIE_TLP_USER_W-1:0]   pcie_tx_user,

    // BAR2 CSR MMIO 请求接口；后续可由 PCIe TLP/BAR 解码器直接驱动。
    input  logic                         bar2_csr_req_valid,
    output logic                         bar2_csr_req_ready,
    input  logic                         bar2_csr_req_write,
    input  logic [PCIE_BAR_OFFSET_W-1:0] bar2_csr_req_addr,
    input  logic [PCIE_BAR_DATA_W-1:0]   bar2_csr_req_wdata,
    input  logic [PCIE_BAR_BE_W-1:0]     bar2_csr_req_be,
    input  logic [VF_ID_W-1:0]           bar2_csr_req_func_id,
    output logic                         bar2_csr_rsp_valid,
    input  logic                         bar2_csr_rsp_ready,
    output logic [PCIE_BAR_DATA_W-1:0]   bar2_csr_rsp_rdata,
    output pcie_bar_rsp_status_e         bar2_csr_rsp_status,
    output logic [VF_ID_W-1:0]           bar2_csr_rsp_func_id,

    // BAR0 Doorbell 写入接口；SQ/RQ 使用 db_qp_num，CQ_ARM 使用同一字段表示 CQN。
    input  logic                         bar0_db_valid,
    output logic                         bar0_db_ready,
    input  logic [QP_ID_W-1:0]           bar0_db_qp_num,
    input  doorbell_type_e               bar0_db_type,
    input  logic [PCIE_BAR_DATA_W-1:0]   bar0_db_value,
    input  logic [VF_ID_W-1:0]           bar0_db_owner_function,

    // 11.4 最小 RC Send/Recv pipeline 测试入口；真实 SQ/RQ engine 连接留给后续增强。
    input  logic                         rc_send_test_valid,
    output logic                         rc_send_test_ready,
    input  logic [QP_ID_W-1:0]           rc_send_test_qpn,
    input  logic [CQ_ID_W-1:0]           rc_send_test_cqn,
    input  logic [VF_ID_W-1:0]           rc_send_test_owner_function,
    input  logic [PD_ID_W-1:0]           rc_send_test_pd_id,
    input  logic [WR_ID_W-1:0]           rc_send_test_wr_id,
    input  logic [DMA_LEN_W-1:0]         rc_send_test_len,
    input  logic [511:0]                 rc_send_test_payload,
    input  logic                         rc_recv_test_valid,
    output logic                         rc_recv_test_ready,
    input  logic [QP_ID_W-1:0]           rc_recv_test_qpn,
    input  logic [CQ_ID_W-1:0]           rc_recv_test_cqn,
    input  logic [VF_ID_W-1:0]           rc_recv_test_owner_function,
    input  logic [PD_ID_W-1:0]           rc_recv_test_pd_id,
    input  logic [WR_ID_W-1:0]           rc_recv_test_wr_id,
    input  logic [DMA_LEN_W-1:0]         rc_recv_test_len,
    input  logic [511:0]                 rc_recv_test_payload,

    // 11.5 RDMA Write/Read one-sided pipeline 测试入口；真实 SQ WQE fetch 留给后续任务。
    input  logic                         rdma_wr_test_valid,
    output logic                         rdma_wr_test_ready,
    input  rdma_opcode_e                 rdma_wr_test_opcode,
    input  logic [15:0]                  rdma_wr_test_desc_id,
    input  logic [QP_ID_W-1:0]           rdma_wr_test_qpn,
    input  logic [CQ_ID_W-1:0]           rdma_wr_test_cqn,
    input  logic [VF_ID_W-1:0]           rdma_wr_test_owner_function,
    input  logic [PD_ID_W-1:0]           rdma_wr_test_pd_id,
    input  logic [WR_ID_W-1:0]           rdma_wr_test_wr_id,
    input  logic [ADDR_W-1:0]            rdma_wr_test_local_va,
    input  logic [KEY_W-1:0]             rdma_wr_test_lkey,
    input  logic [ADDR_W-1:0]            rdma_wr_test_remote_va,
    input  logic [KEY_W-1:0]             rdma_wr_test_rkey,
    input  logic [DMA_LEN_W-1:0]         rdma_wr_test_len,
    input  logic [511:0]                 rdma_wr_test_payload,
    input  logic                         rdma_read_resp_test_valid,
    output logic                         rdma_read_resp_test_ready,
    input  logic [QP_ID_W-1:0]           rdma_read_resp_test_qpn,
    input  logic [PSN_W-1:0]             rdma_read_resp_test_psn,
    input  logic [DMA_LEN_W-1:0]         rdma_read_resp_test_len,
    input  logic [511:0]                 rdma_read_resp_test_payload,
    input  logic                         rdma_read_resp_test_error,

    // 11.6 UD datapath 测试入口。真实 SQ/RQ WQE fetch 和 AH CSR 管理由后续任务替换。
    input  logic                         ud_ah_create_valid,
    output logic                         ud_ah_create_ready,
    input  ah_entry_t                    ud_ah_create_entry,
    output logic                         ud_ah_create_rsp_valid,
    input  logic                         ud_ah_create_rsp_ready,
    output ah_table_status_e             ud_ah_create_status,
    input  logic                         ud_tx_test_valid,
    output logic                         ud_tx_test_ready,
    input  logic [15:0]                  ud_tx_test_desc_id,
    input  logic [QP_ID_W-1:0]           ud_tx_test_qpn,
    input  logic [CQ_ID_W-1:0]           ud_tx_test_cqn,
    input  logic [VF_ID_W-1:0]           ud_tx_test_owner_function,
    input  logic [PD_ID_W-1:0]           ud_tx_test_pd_id,
    input  logic [WR_ID_W-1:0]           ud_tx_test_wr_id,
    input  logic [AH_ID_W-1:0]           ud_tx_test_ah_id,
    input  logic [QP_ID_W-1:0]           ud_tx_test_dest_qpn,
    input  logic [QKEY_W-1:0]            ud_tx_test_qkey,
    input  logic [PSN_W-1:0]             ud_tx_test_psn,
    input  logic [ADDR_W-1:0]            ud_tx_test_local_va,
    input  logic [KEY_W-1:0]             ud_tx_test_lkey,
    input  logic [511:0]                 ud_tx_test_payload,
    input  logic [15:0]                  ud_tx_test_len,
    input  logic                         ud_rx_rq_available,
    input  logic [WR_ID_W-1:0]           ud_rx_rq_wr_id,
    input  logic [CQ_ID_W-1:0]           ud_rx_rq_cqn,
    input  logic [ADDR_W-1:0]            ud_rx_rq_buffer_addr,
    input  logic [KEY_W-1:0]             ud_rx_rq_lkey,
    input  logic [DMA_LEN_W-1:0]         ud_rx_rq_buffer_len,

    // 简化 Ethernet/RoCEv2 frame 流接口。
    input  logic                         eth_rx_valid,
    output logic                         eth_rx_ready,
    input  logic [511:0]                 eth_rx_data,
    input  logic [15:0]                  eth_rx_len,
    input  logic                         eth_rx_last,
    output logic                         eth_tx_valid,
    input  logic                         eth_tx_ready,
    output logic [511:0]                 eth_tx_data,
    output logic [15:0]                  eth_tx_len,
    output logic                         eth_tx_last,

    // PFC 事件注入接口；真实 MAC control frame 解析留给后续 top/verification。
    input  logic                         pfc_event_valid,
    output logic                         pfc_event_ready,
    input  logic [PFC_PRIORITY_W-1:0]    pfc_priority,
    input  logic                         pfc_pause,
    input  logic                         pfc_resume,
    input  logic [PFC_TIMER_W-1:0]       pfc_pause_quanta,

    output logic [31:0]                  debug_qp_status,
    output logic [31:0]                  debug_cq_status,
    output logic [31:0]                  debug_transport_status,
    output logic [31:0]                  debug_congestion_status
);

    logic rst_sync_1;
    logic rst_sync_2;
    logic core_rst_n;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync_1 <= 1'b0;
            rst_sync_2 <= 1'b0;
        end else begin
            rst_sync_1 <= 1'b1;
            rst_sync_2 <= rst_sync_1;
        end
    end

    assign core_rst_n = rst_sync_2;

    function automatic logic [31:0] apply_csr_be(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  byte_enable
    );
        logic [31:0] result;
        begin
            result = old_value;
            if (byte_enable[0]) result[7:0] = new_value[7:0];
            if (byte_enable[1]) result[15:8] = new_value[15:8];
            if (byte_enable[2]) result[23:16] = new_value[23:16];
            if (byte_enable[3]) result[31:24] = new_value[31:24];
            return result;
        end
    endfunction

    // ------------------------------------------------------------------
    // PCIe subsystem boundary
    // ------------------------------------------------------------------

    assign pcie_rx_ready = 1'b1;
    assign pcie_tx_valid = 1'b0;
    assign pcie_tx_data = '0;
    assign pcie_tx_keep = '0;
    assign pcie_tx_last = 1'b0;
    assign pcie_tx_user = '0;

    pcie_endpoint_wrapper u_pcie_endpoint (
        .pcie_clk(clk),
        .pcie_rst_n(core_rst_n),
        .cfg_req_ready(1'b1),
        .cfg_rsp_valid(1'b0),
        .cfg_rsp_rdata('0),
        .cfg_rsp_status(PCIE_CFG_RSP_OK),
        .pcie_rx_valid(pcie_rx_valid),
        .pcie_rx_ready(),
        .pcie_rx_data(pcie_rx_data),
        .pcie_rx_keep(pcie_rx_keep),
        .pcie_rx_last(pcie_rx_last),
        .pcie_rx_user(pcie_rx_user),
        .ib_tlp_ready(1'b1),
        .ob_tlp_valid(1'b0),
        .ob_tlp_data('0),
        .ob_tlp_keep('0),
        .ob_tlp_last(1'b0),
        .ob_tlp_user('0),
        .ob_tlp_type(PCIE_TLP_MEM_WRITE),
        .ob_tlp_func_id('0),
        .pcie_tx_valid(),
        .pcie_tx_ready(pcie_tx_ready),
        .pcie_tx_data(),
        .pcie_tx_keep(),
        .pcie_tx_last(),
        .pcie_tx_user(),
        .dma_req_valid(1'b0),
        .dma_req_write(1'b0),
        .dma_req_func_id('0),
        .dma_req_tag('0),
        .dma_req_addr('0),
        .dma_req_len('0),
        .dma_req_tc('0),
        .dma_req_attr('0),
        .dma_wdata_valid(1'b0),
        .dma_wdata('0),
        .dma_wdata_keep('0),
        .dma_wdata_last(1'b0),
        .dma_cpl_ready(1'b1),
        .msix_req_valid(1'b0),
        .msix_req_func_id('0),
        .msix_req_vector('0),
        .msix_req_msg_addr('0),
        .msix_req_msg_data('0),
        .msix_req_masked(1'b0)
    );

    // ------------------------------------------------------------------
    // BAR2 CSR control fabric
    // ------------------------------------------------------------------

    logic qp_csr_wr_en;
    logic qp_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] qp_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] qp_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] qp_csr_be;
    logic [VF_ID_W-1:0] qp_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] qp_csr_rdata;

    logic cq_csr_wr_en;
    logic cq_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] cq_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] cq_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] cq_csr_be;
    logic [VF_ID_W-1:0] cq_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] cq_csr_rdata;

    logic mr_csr_wr_en;
    logic mr_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] mr_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] mr_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] mr_csr_be;
    logic [VF_ID_W-1:0] mr_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] mr_csr_rdata;

    logic ah_csr_wr_en;
    logic ah_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] ah_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] ah_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] ah_csr_be;
    logic [VF_ID_W-1:0] ah_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] ah_csr_rdata;

    logic msix_csr_wr_en;
    logic msix_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] msix_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] msix_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] msix_csr_be;
    logic [VF_ID_W-1:0] msix_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] msix_csr_rdata;

    logic sriov_csr_wr_en;
    logic sriov_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] sriov_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] sriov_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] sriov_csr_be;
    logic [VF_ID_W-1:0] sriov_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] sriov_csr_rdata;

    logic congestion_csr_wr_en;
    logic congestion_csr_rd_en;
    logic [PCIE_BAR_OFFSET_W-1:0] congestion_csr_addr;
    logic [PCIE_BAR_DATA_W-1:0] congestion_csr_wdata;
    logic [PCIE_BAR_BE_W-1:0] congestion_csr_be;
    logic [VF_ID_W-1:0] congestion_csr_func_id;
    logic [PCIE_BAR_DATA_W-1:0] congestion_csr_rdata;

    logic [31:0] qp_csr_control_reg;
    logic [31:0] cq_csr_control_reg;
    logic [31:0] mr_csr_control_reg;
    logic [31:0] ah_csr_control_reg;
    logic [31:0] msix_csr_control_reg;
    logic [31:0] sriov_csr_control_reg;
    logic [31:0] congestion_csr_control_reg;

    csr_fabric u_csr_fabric (
        .clk(clk),
        .rst_n(core_rst_n),
        .csr_req_valid(bar2_csr_req_valid),
        .csr_req_ready(bar2_csr_req_ready),
        .csr_req_write(bar2_csr_req_write),
        .csr_req_addr(bar2_csr_req_addr),
        .csr_req_wdata(bar2_csr_req_wdata),
        .csr_req_be(bar2_csr_req_be),
        .csr_req_func_id(bar2_csr_req_func_id),
        .csr_rsp_valid(bar2_csr_rsp_valid),
        .csr_rsp_ready(bar2_csr_rsp_ready),
        .csr_rsp_rdata(bar2_csr_rsp_rdata),
        .csr_rsp_status(bar2_csr_rsp_status),
        .csr_rsp_func_id(bar2_csr_rsp_func_id),
        .qp_csr_wr_en(qp_csr_wr_en),
        .qp_csr_rd_en(qp_csr_rd_en),
        .qp_csr_addr(qp_csr_addr),
        .qp_csr_wdata(qp_csr_wdata),
        .qp_csr_be(qp_csr_be),
        .qp_csr_func_id(qp_csr_func_id),
        .qp_csr_rdata(qp_csr_rdata),
        .cq_csr_wr_en(cq_csr_wr_en),
        .cq_csr_rd_en(cq_csr_rd_en),
        .cq_csr_addr(cq_csr_addr),
        .cq_csr_wdata(cq_csr_wdata),
        .cq_csr_be(cq_csr_be),
        .cq_csr_func_id(cq_csr_func_id),
        .cq_csr_rdata(cq_csr_rdata),
        .mr_csr_wr_en(mr_csr_wr_en),
        .mr_csr_rd_en(mr_csr_rd_en),
        .mr_csr_addr(mr_csr_addr),
        .mr_csr_wdata(mr_csr_wdata),
        .mr_csr_be(mr_csr_be),
        .mr_csr_func_id(mr_csr_func_id),
        .mr_csr_rdata(mr_csr_rdata),
        .ah_csr_wr_en(ah_csr_wr_en),
        .ah_csr_rd_en(ah_csr_rd_en),
        .ah_csr_addr(ah_csr_addr),
        .ah_csr_wdata(ah_csr_wdata),
        .ah_csr_be(ah_csr_be),
        .ah_csr_func_id(ah_csr_func_id),
        .ah_csr_rdata(ah_csr_rdata),
        .msix_csr_wr_en(msix_csr_wr_en),
        .msix_csr_rd_en(msix_csr_rd_en),
        .msix_csr_addr(msix_csr_addr),
        .msix_csr_wdata(msix_csr_wdata),
        .msix_csr_be(msix_csr_be),
        .msix_csr_func_id(msix_csr_func_id),
        .msix_csr_rdata(msix_csr_rdata),
        .sriov_csr_wr_en(sriov_csr_wr_en),
        .sriov_csr_rd_en(sriov_csr_rd_en),
        .sriov_csr_addr(sriov_csr_addr),
        .sriov_csr_wdata(sriov_csr_wdata),
        .sriov_csr_be(sriov_csr_be),
        .sriov_csr_func_id(sriov_csr_func_id),
        .sriov_csr_rdata(sriov_csr_rdata),
        .congestion_csr_wr_en(congestion_csr_wr_en),
        .congestion_csr_rd_en(congestion_csr_rd_en),
        .congestion_csr_addr(congestion_csr_addr),
        .congestion_csr_wdata(congestion_csr_wdata),
        .congestion_csr_be(congestion_csr_be),
        .congestion_csr_func_id(congestion_csr_func_id),
        .congestion_csr_rdata(congestion_csr_rdata)
    );

    always_ff @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            qp_csr_control_reg <= '0;
            cq_csr_control_reg <= '0;
            mr_csr_control_reg <= '0;
            ah_csr_control_reg <= '0;
            msix_csr_control_reg <= '0;
            sriov_csr_control_reg <= '0;
            congestion_csr_control_reg <= '0;
        end else begin
            if (qp_csr_wr_en) begin
                qp_csr_control_reg <= apply_csr_be(qp_csr_control_reg, qp_csr_wdata, qp_csr_be);
            end
            if (cq_csr_wr_en) begin
                cq_csr_control_reg <= apply_csr_be(cq_csr_control_reg, cq_csr_wdata, cq_csr_be);
            end
            if (mr_csr_wr_en) begin
                mr_csr_control_reg <= apply_csr_be(mr_csr_control_reg, mr_csr_wdata, mr_csr_be);
            end
            if (ah_csr_wr_en) begin
                ah_csr_control_reg <= apply_csr_be(ah_csr_control_reg, ah_csr_wdata, ah_csr_be);
            end
            if (msix_csr_wr_en) begin
                msix_csr_control_reg <= apply_csr_be(msix_csr_control_reg, msix_csr_wdata, msix_csr_be);
            end
            if (sriov_csr_wr_en) begin
                sriov_csr_control_reg <= apply_csr_be(sriov_csr_control_reg, sriov_csr_wdata, sriov_csr_be);
            end
            if (congestion_csr_wr_en) begin
                congestion_csr_control_reg <= apply_csr_be(congestion_csr_control_reg, congestion_csr_wdata, congestion_csr_be);
            end
        end
    end

    assign qp_csr_rdata = qp_csr_control_reg;
    assign cq_csr_rdata = cq_csr_control_reg;
    assign mr_csr_rdata = mr_csr_control_reg;
    assign ah_csr_rdata = ah_csr_control_reg;
    assign msix_csr_rdata = msix_csr_control_reg;
    assign sriov_csr_rdata = sriov_csr_control_reg;
    assign congestion_csr_rdata = congestion_csr_control_reg;

    // ------------------------------------------------------------------
    // BAR0 Doorbell control path
    // ------------------------------------------------------------------

    sriov_resource_window_t top_db_resource_window;
    logic db_sq_pi_update_valid;
    logic db_sq_pi_update_ready;
    logic [QP_ID_W-1:0] db_sq_pi_update_qpn;
    logic [VF_ID_W-1:0] db_sq_pi_update_function_id;
    logic [QUEUE_IDX_W-1:0] db_sq_pi_update_new_pi;
    logic db_sq_pi_update_error;
    logic db_sq_pi_update_rsp_valid;
    qp_table_status_e db_sq_pi_update_status;

    logic db_rq_pi_update_valid;
    logic db_rq_pi_update_ready;
    logic [QP_ID_W-1:0] db_rq_pi_update_qpn;
    logic [VF_ID_W-1:0] db_rq_pi_update_function_id;
    logic [QUEUE_IDX_W-1:0] db_rq_pi_update_new_pi;
    logic db_rq_pi_update_error;
    logic db_rq_pi_update_rsp_valid;
    qp_table_status_e db_rq_pi_update_status;

    logic db_cq_arm_valid;
    logic db_cq_arm_ready;
    logic [CQ_ID_W-1:0] db_cq_arm_cqn;
    logic [VF_ID_W-1:0] db_cq_arm_function_id;
    logic [QUEUE_IDX_W-1:0] db_cq_arm_consumer_index;
    logic db_cq_arm_armed;
    logic db_cq_arm_solicited_only;
    logic db_cq_arm_error;
    logic db_cq_arm_rsp_valid;
    cq_table_status_e db_cq_arm_status;

    logic db_sq_scheduler_valid;
    logic [QP_ID_W-1:0] db_sq_scheduler_qpn;
    logic [VF_ID_W-1:0] db_sq_scheduler_function_id;
    logic db_rq_post_valid;
    logic [QP_ID_W-1:0] db_rq_post_qpn;
    logic [VF_ID_W-1:0] db_rq_post_function_id;
    logic db_error_valid;
    doorbell_error_e db_error_code;
    doorbell_type_e db_debug_last_type;
    logic [QP_ID_W-1:0] db_debug_last_qp_num;

    assign top_db_resource_window.qp_base = '0;
    assign top_db_resource_window.qp_limit = {QP_ID_W{1'b1}};
    assign top_db_resource_window.cq_base = '0;
    assign top_db_resource_window.cq_limit = {CQ_ID_W{1'b1}};
    assign top_db_resource_window.mr_base = '0;
    assign top_db_resource_window.mr_limit = {MR_ID_W{1'b1}};
    assign top_db_resource_window.doorbell_base = '0;
    assign top_db_resource_window.doorbell_limit = PCIE_BAR0_SIZE - 1'b1;
    assign top_db_resource_window.msix_vector_base = '0;
    assign top_db_resource_window.msix_vector_limit = {CQ_VECTOR_W{1'b1}};

    doorbell_ctrl u_doorbell_ctrl (
        .clk(clk),
        .rst_n(core_rst_n),
        .db_valid(bar0_db_valid),
        .db_ready(bar0_db_ready),
        .db_qp_num(bar0_db_qp_num),
        .db_type(bar0_db_type),
        .db_value(bar0_db_value),
        .db_owner_function(bar0_db_owner_function),
        .csr_order_ready(1'b1),
        .function_enabled(1'b1),
        .resource_window(top_db_resource_window),
        .qpn_valid_hint(1'b1),
        .cqn_valid_hint(1'b1),
        .current_sq_pi_hint('0),
        .current_rq_pi_hint('0),
        .sq_pi_update_valid(db_sq_pi_update_valid),
        .sq_pi_update_ready(db_sq_pi_update_ready),
        .sq_pi_update_qpn(db_sq_pi_update_qpn),
        .sq_pi_update_function_id(db_sq_pi_update_function_id),
        .sq_pi_update_new_pi(db_sq_pi_update_new_pi),
        .sq_pi_update_error(db_sq_pi_update_error),
        .rq_pi_update_valid(db_rq_pi_update_valid),
        .rq_pi_update_ready(db_rq_pi_update_ready),
        .rq_pi_update_qpn(db_rq_pi_update_qpn),
        .rq_pi_update_function_id(db_rq_pi_update_function_id),
        .rq_pi_update_new_pi(db_rq_pi_update_new_pi),
        .rq_pi_update_error(db_rq_pi_update_error),
        .cq_arm_valid(db_cq_arm_valid),
        .cq_arm_ready(db_cq_arm_ready),
        .cq_arm_cqn(db_cq_arm_cqn),
        .cq_arm_function_id(db_cq_arm_function_id),
        .cq_arm_consumer_index(db_cq_arm_consumer_index),
        .cq_arm_armed(db_cq_arm_armed),
        .cq_arm_solicited_only(db_cq_arm_solicited_only),
        .cq_arm_error(db_cq_arm_error),
        .sq_scheduler_valid(db_sq_scheduler_valid),
        .sq_scheduler_ready(!rc_send_test_valid && rc_send_test_ready),
        .sq_scheduler_qpn(db_sq_scheduler_qpn),
        .sq_scheduler_function_id(db_sq_scheduler_function_id),
        .rq_post_valid(db_rq_post_valid),
        .rq_post_ready(1'b1),
        .rq_post_qpn(db_rq_post_qpn),
        .rq_post_function_id(db_rq_post_function_id),
        .db_error_valid(db_error_valid),
        .db_error_ready(1'b1),
        .db_error_code(db_error_code),
        .debug_last_type(db_debug_last_type),
        .debug_last_qp_num(db_debug_last_qp_num)
    );

    // ------------------------------------------------------------------
    // Minimal RC Send/Recv loop integration for 11.4
    // ------------------------------------------------------------------

    logic rc_dma_read_valid;
    logic [QP_ID_W-1:0] rc_dma_read_qpn;
    logic [DMA_LEN_W-1:0] rc_dma_read_len;
    logic rc_dma_write_valid;
    logic [QP_ID_W-1:0] rc_dma_write_qpn;
    logic [DMA_LEN_W-1:0] rc_dma_write_len;
    logic rc_completion_valid;
    logic rc_completion_ready;
    completion_event_t rc_completion_event;
    logic rc_cq_commit_valid;
    logic rc_cq_commit_ready;
    logic [CQ_ID_W-1:0] rc_cq_commit_cqn;
    logic [VF_ID_W-1:0] rc_cq_commit_owner_function;
    logic rc_cq_commit_solicited;
    cmpl_status_e rc_cq_commit_status;
    logic [PSN_W-1:0] rc_debug_next_psn;
    logic [3:0] rc_debug_state;
    logic rdma_dma_read_valid;
    logic [15:0] rdma_dma_read_desc_id;
    logic [QP_ID_W-1:0] rdma_dma_read_qpn;
    logic [ADDR_W-1:0] rdma_dma_read_local_va;
    logic [KEY_W-1:0] rdma_dma_read_lkey;
    logic [DMA_LEN_W-1:0] rdma_dma_read_len;
    logic rdma_dma_write_valid;
    logic [15:0] rdma_dma_write_desc_id;
    logic [QP_ID_W-1:0] rdma_dma_write_qpn;
    logic [ADDR_W-1:0] rdma_dma_write_local_va;
    logic [KEY_W-1:0] rdma_dma_write_lkey;
    logic [DMA_LEN_W-1:0] rdma_dma_write_len;
    logic rdma_completion_valid;
    logic rdma_completion_ready;
    completion_event_t rdma_completion_event;
    logic rdma_outstanding_read_valid;
    logic [PSN_W-1:0] rdma_debug_next_psn;
    logic [3:0] rdma_debug_state;
    cmpl_status_e rdma_debug_status;
    logic ud_tx_dma_read_valid;
    logic [QP_ID_W-1:0] ud_tx_dma_read_qpn;
    logic [ADDR_W-1:0] ud_tx_dma_read_local_va;
    logic [KEY_W-1:0] ud_tx_dma_read_lkey;
    logic [15:0] ud_tx_dma_read_len;
    logic ud_rx_dma_write_valid;
    rq_dma_write_req_t ud_rx_dma_write_req;
    logic [511:0] ud_rx_dma_write_payload_data;
    logic [15:0] ud_rx_dma_write_payload_len;
    logic ud_rx_dma_write_done_ready;
    logic ud_completion_valid;
    logic ud_completion_ready;
    completion_event_t ud_completion_event;
    logic ud_drop_valid;
    ud_rx_status_e ud_drop_status;
    logic [QP_ID_W-1:0] ud_drop_qpn;
    logic [QP_ID_W-1:0] ud_drop_source_qpn;
    logic [15:0] ud_drop_error_code;
    ud_rx_counters_t ud_rx_counters;
    logic [31:0] ud_ah_lookup_fail_count;
    ud_tx_status_e ud_debug_tx_status;
    ud_rx_status_e ud_debug_rx_status;
    logic [2:0] ud_debug_tx_state;
    logic ud_rx_qp_read_valid;
    logic ud_rx_qp_read_ready;
    logic [QP_ID_W-1:0] ud_rx_qp_read_qpn;
    logic [VF_ID_W-1:0] ud_rx_qp_read_function_id;
    logic ud_rx_qp_read_pf_bypass;
    logic ud_rx_qp_read_rsp_valid;
    logic ud_rx_qp_read_rsp_ready;
    logic ud_rx_qp_read_hit;
    qp_table_status_e ud_rx_qp_read_status;
    qp_context_t ud_rx_qp_read_data;
    logic ud_rx_meta_valid;
    logic ud_rx_meta_ready;
    logic ud_rx_payload_valid;
    logic ud_rx_payload_ready;
    packet_payload_stream_t ud_rx_payload_stream;
    logic ud_rx_rq_consume_valid;
    logic [QP_ID_W-1:0] ud_rx_rq_consume_qpn;
    logic [VF_ID_W-1:0] ud_rx_rq_consume_owner_function;
    logic [QP_ID_W-1:0] ud_rx_rq_consume_source_qpn;

    rc_pipeline_top u_rc_pipeline_top (
        .clk(clk),
        .rst_n(core_rst_n),
        .send_req_valid(rc_send_test_valid || db_sq_scheduler_valid),
        .send_req_ready(rc_send_test_ready),
        .send_qpn(rc_send_test_valid ? rc_send_test_qpn : db_sq_scheduler_qpn),
        .send_cqn(rc_send_test_valid ? rc_send_test_cqn : CQ_ID_W'(db_sq_scheduler_qpn)),
        .send_owner_function(rc_send_test_valid ? rc_send_test_owner_function : db_sq_scheduler_function_id),
        .send_pd_id(rc_send_test_pd_id),
        .send_wr_id(rc_send_test_wr_id),
        .send_payload_len(rc_send_test_len),
        .send_payload_data(rc_send_test_payload),
        .send_solicited(1'b0),
        .recv_req_valid(rc_recv_test_valid),
        .recv_req_ready(rc_recv_test_ready),
        .recv_qpn(rc_recv_test_qpn),
        .recv_cqn(rc_recv_test_cqn),
        .recv_owner_function(rc_recv_test_owner_function),
        .recv_pd_id(rc_recv_test_pd_id),
        .recv_wr_id(rc_recv_test_wr_id),
        .recv_payload_len(rc_recv_test_len),
        .recv_payload_data(rc_recv_test_payload),
        .recv_solicited(1'b0),
        .packet_build_valid(rc_build_valid),
        .packet_build_ready(rc_build_ready),
        .packet_build_req(rc_build_req),
        .dma_read_valid(rc_dma_read_valid),
        .dma_read_ready(1'b1),
        .dma_read_qpn(rc_dma_read_qpn),
        .dma_read_len(rc_dma_read_len),
        .dma_write_valid(rc_dma_write_valid),
        .dma_write_ready(1'b1),
        .dma_write_qpn(rc_dma_write_qpn),
        .dma_write_len(rc_dma_write_len),
        .completion_event_valid(rc_completion_valid),
        .completion_event_ready(rc_completion_ready),
        .completion_event(rc_completion_event),
        .cq_commit_valid(rc_cq_commit_valid),
        .cq_commit_ready(rc_cq_commit_ready),
        .cq_commit_cqn(rc_cq_commit_cqn),
        .cq_commit_owner_function(rc_cq_commit_owner_function),
        .cq_commit_solicited(rc_cq_commit_solicited),
        .cq_commit_status(rc_cq_commit_status),
        .debug_next_psn(rc_debug_next_psn),
        .debug_state(rc_debug_state)
    );

    rdma_write_read_engine #(
        .LOCAL_MAC(LOCAL_MAC),
        .PEER_MAC(PEER_MAC),
        .LOCAL_IPV4(LOCAL_IPV4),
        .PEER_IPV4(PEER_IPV4)
    ) u_rdma_write_read_engine (
        .clk(clk),
        .rst_n(core_rst_n),
        .wr_valid(rdma_wr_test_valid),
        .wr_ready(rdma_wr_test_ready),
        .wr_opcode(rdma_wr_test_opcode),
        .wr_desc_id(rdma_wr_test_desc_id),
        .wr_qpn(rdma_wr_test_qpn),
        .wr_cqn(rdma_wr_test_cqn),
        .wr_owner_function(rdma_wr_test_owner_function),
        .wr_pd_id(rdma_wr_test_pd_id),
        .wr_id(rdma_wr_test_wr_id),
        .wr_local_va(rdma_wr_test_local_va),
        .wr_lkey(rdma_wr_test_lkey),
        .wr_remote_va(rdma_wr_test_remote_va),
        .wr_rkey(rdma_wr_test_rkey),
        .wr_len(rdma_wr_test_len),
        .wr_payload_data(rdma_wr_test_payload),
        .wr_solicited(1'b0),
        .read_resp_valid(rdma_read_resp_test_valid),
        .read_resp_ready(rdma_read_resp_test_ready),
        .read_resp_qpn(rdma_read_resp_test_qpn),
        .read_resp_psn(rdma_read_resp_test_psn),
        .read_resp_len(rdma_read_resp_test_len),
        .read_resp_payload_data(rdma_read_resp_test_payload),
        .read_resp_error(rdma_read_resp_test_error),
        .packet_build_valid(rdma_build_valid),
        .packet_build_ready(rdma_build_ready),
        .packet_build_req(rdma_build_req),
        .dma_read_valid(rdma_dma_read_valid),
        .dma_read_ready(1'b1),
        .dma_read_desc_id(rdma_dma_read_desc_id),
        .dma_read_qpn(rdma_dma_read_qpn),
        .dma_read_local_va(rdma_dma_read_local_va),
        .dma_read_lkey(rdma_dma_read_lkey),
        .dma_read_len(rdma_dma_read_len),
        .dma_write_valid(rdma_dma_write_valid),
        .dma_write_ready(1'b1),
        .dma_write_desc_id(rdma_dma_write_desc_id),
        .dma_write_qpn(rdma_dma_write_qpn),
        .dma_write_local_va(rdma_dma_write_local_va),
        .dma_write_lkey(rdma_dma_write_lkey),
        .dma_write_len(rdma_dma_write_len),
        .completion_event_valid(rdma_completion_valid),
        .completion_event_ready(rdma_completion_ready),
        .completion_event(rdma_completion_event),
        .outstanding_read_valid(rdma_outstanding_read_valid),
        .debug_next_psn(rdma_debug_next_psn),
        .debug_state(rdma_debug_state),
        .debug_status(rdma_debug_status)
    );

    assign ud_rx_meta_valid = marked_valid && (marked_meta.opcode == ROCE_OPCODE_UD_SEND_ONLY);
    assign ud_rx_payload_valid = ud_rx_meta_valid;
    assign ud_rx_payload_stream = '{
        desc_id: marked_meta.desc_id,
        qpn: marked_meta.qpn,
        cqn: marked_meta.cqn,
        owner_function: marked_meta.owner_function,
        pd_id: marked_meta.pd_id,
        opcode: marked_meta.opcode,
        status: PKT_PAYLOAD_OK,
        error_code: 16'd0,
        ecn: marked_meta.ecn,
        ecn_valid: marked_meta.ecn_valid,
        ecn_ce: marked_meta.ecn_ce,
        data: eth_rx_data,
        payload_len: marked_meta.payload_len,
        valid_bytes: marked_meta.payload_len,
        byte_offset: 16'd0,
        first: 1'b1,
        last: 1'b1,
        has_imm: marked_meta.has_imm,
        imm_data: marked_meta.imm_data,
        remote_va: marked_meta.remote_va,
        rkey: marked_meta.rkey,
        dma_length: marked_meta.dma_length,
        dest_qpn: marked_meta.dest_qpn,
        psn: marked_meta.psn
    };

    ud_datapath_top u_ud_datapath_top (
        .clk(clk),
        .rst_n(core_rst_n),
        .ah_create_valid(ud_ah_create_valid),
        .ah_create_ready(ud_ah_create_ready),
        .ah_create_entry(ud_ah_create_entry),
        .ah_create_rsp_valid(ud_ah_create_rsp_valid),
        .ah_create_rsp_ready(ud_ah_create_rsp_ready),
        .ah_create_status(ud_ah_create_status),
        .tx_req_valid(ud_tx_test_valid),
        .tx_req_ready(ud_tx_test_ready),
        .tx_desc_id(ud_tx_test_desc_id),
        .tx_qpn(ud_tx_test_qpn),
        .tx_cqn(ud_tx_test_cqn),
        .tx_owner_function(ud_tx_test_owner_function),
        .tx_pd_id(ud_tx_test_pd_id),
        .tx_wr_id(ud_tx_test_wr_id),
        .tx_ah_id(ud_tx_test_ah_id),
        .tx_dest_qpn(ud_tx_test_dest_qpn),
        .tx_qkey(ud_tx_test_qkey),
        .tx_psn(ud_tx_test_psn),
        .tx_local_va(ud_tx_test_local_va),
        .tx_lkey(ud_tx_test_lkey),
        .tx_payload_data(ud_tx_test_payload),
        .tx_payload_len(ud_tx_test_len),
        .tx_solicited(1'b0),
        .tx_completion_required(1'b1),
        .rx_meta_valid(ud_rx_meta_valid),
        .rx_meta_ready(ud_rx_meta_ready),
        .rx_meta(marked_meta),
        .rx_payload_valid(ud_rx_payload_valid),
        .rx_payload_ready(ud_rx_payload_ready),
        .rx_payload(ud_rx_payload_stream),
        .qp_read_valid(ud_rx_qp_read_valid),
        .qp_read_ready(ud_rx_qp_read_ready),
        .qp_read_qpn(ud_rx_qp_read_qpn),
        .qp_read_function_id(ud_rx_qp_read_function_id),
        .qp_read_pf_bypass(ud_rx_qp_read_pf_bypass),
        .qp_read_rsp_valid(ud_rx_qp_read_rsp_valid),
        .qp_read_rsp_ready(ud_rx_qp_read_rsp_ready),
        .qp_read_hit(ud_rx_qp_read_hit),
        .qp_read_status(ud_rx_qp_read_status),
        .qp_read_data(ud_rx_qp_read_data),
        .rx_rq_wqe_available(ud_rx_rq_available),
        .rx_rq_wqe_wr_id(ud_rx_rq_wr_id),
        .rx_rq_wqe_cqn(ud_rx_rq_cqn),
        .rx_rq_wqe_buffer_addr(ud_rx_rq_buffer_addr),
        .rx_rq_wqe_lkey(ud_rx_rq_lkey),
        .rx_rq_wqe_buffer_len(ud_rx_rq_buffer_len),
        .rx_rq_consume_valid(ud_rx_rq_consume_valid),
        .rx_rq_consume_ready(1'b1),
        .rx_rq_consume_qpn(ud_rx_rq_consume_qpn),
        .rx_rq_consume_owner_function(ud_rx_rq_consume_owner_function),
        .rx_rq_consume_source_qpn(ud_rx_rq_consume_source_qpn),
        .tx_dma_read_valid(ud_tx_dma_read_valid),
        .tx_dma_read_ready(1'b1),
        .tx_dma_read_qpn(ud_tx_dma_read_qpn),
        .tx_dma_read_local_va(ud_tx_dma_read_local_va),
        .tx_dma_read_lkey(ud_tx_dma_read_lkey),
        .tx_dma_read_len(ud_tx_dma_read_len),
        .rx_dma_write_valid(ud_rx_dma_write_valid),
        .rx_dma_write_ready(1'b1),
        .rx_dma_write_req(ud_rx_dma_write_req),
        .rx_dma_write_payload_data(ud_rx_dma_write_payload_data),
        .rx_dma_write_payload_len(ud_rx_dma_write_payload_len),
        .rx_dma_write_done_valid(ud_rx_dma_write_valid),
        .rx_dma_write_done_ready(ud_rx_dma_write_done_ready),
        .rx_dma_write_error(1'b0),
        .packet_valid(ud_build_valid),
        .packet_ready(ud_build_ready),
        .packet_req(ud_build_req),
        .completion_valid(ud_completion_valid),
        .completion_ready(ud_completion_ready),
        .completion_event(ud_completion_event),
        .drop_valid(ud_drop_valid),
        .drop_ready(1'b1),
        .drop_status(ud_drop_status),
        .drop_qpn(ud_drop_qpn),
        .drop_source_qpn(ud_drop_source_qpn),
        .drop_error_code(ud_drop_error_code),
        .rx_counters(ud_rx_counters),
        .ah_lookup_fail_count(ud_ah_lookup_fail_count),
        .debug_tx_status(ud_debug_tx_status),
        .debug_rx_status(ud_debug_rx_status),
        .debug_tx_state(ud_debug_tx_state)
    );

    // ------------------------------------------------------------------
    // Packet ingress, ECN/CNP, and packet builder boundary
    // ------------------------------------------------------------------

    packet_meta_t parser_meta;
    packet_meta_t marked_meta;
    logic parser_meta_valid;
    logic parser_meta_ready;
    logic marked_valid;
    logic marked_ready;
    logic cnp_ce_valid;
    logic cnp_ce_ready;
    logic [15:0] cnp_ce_desc_id;
    logic [QP_ID_W-1:0] cnp_ce_qpn;
    logic [CQ_ID_W-1:0] cnp_ce_cqn;
    logic [VF_ID_W-1:0] cnp_ce_owner;
    logic [PD_ID_W-1:0] cnp_ce_pd;
    roce_opcode_e cnp_ce_opcode;
    packet_build_req_t cnp_build_req;
    logic cnp_build_valid;
    logic cnp_build_ready;
    packet_build_req_t rc_build_req;
    logic rc_build_valid;
    logic rc_build_ready;
    packet_build_req_t rdma_build_req;
    logic rdma_build_valid;
    logic rdma_build_ready;
    packet_build_req_t ud_build_req;
    logic ud_build_valid;
    logic ud_build_ready;
    packet_build_req_t tx_build_req;
    logic tx_build_valid;
    logic tx_build_ready;
    logic cnp_class_event_valid;
    logic cnp_class_event_ready;
    cnp_event_t cnp_class_event;
    logic cnp_marked_ready;

    roce_packet_parser u_packet_parser (
        .clk(clk),
        .rst_n(core_rst_n),
        .frame_valid(eth_rx_valid),
        .frame_ready(eth_rx_ready),
        .frame_data(eth_rx_data),
        .frame_len(eth_rx_len),
        .frame_last(eth_rx_last),
        .desc_id(16'd0),
        .qpn('0),
        .cqn('0),
        .owner_function('0),
        .pd_id('0),
        .meta_valid(parser_meta_valid),
        .meta_ready(parser_meta_ready),
        .meta(parser_meta)
    );

    ecn_ingress_marker u_ecn_marker (
        .clk(clk),
        .rst_n(core_rst_n),
        .meta_valid(parser_meta_valid),
        .meta_ready(parser_meta_ready),
        .meta_in(parser_meta),
        .marked_valid(marked_valid),
        .marked_ready(marked_ready),
        .marked_meta(marked_meta),
        .congestion_mark_valid(cnp_ce_valid),
        .congestion_mark_ready(cnp_ce_ready),
        .congestion_mark_desc_id(cnp_ce_desc_id),
        .congestion_mark_qpn(cnp_ce_qpn),
        .congestion_mark_cqn(cnp_ce_cqn),
        .congestion_mark_owner_function(cnp_ce_owner),
        .congestion_mark_pd_id(cnp_ce_pd),
        .congestion_mark_opcode(cnp_ce_opcode)
    );

    cnp_receive_classifier u_cnp_classifier (
        .clk(clk),
        .rst_n(core_rst_n),
        .meta_valid(marked_valid),
        .meta_ready(cnp_marked_ready),
        .meta_in(marked_meta),
        .qp_lookup_ready(1'b1),
        .qp_lookup_hit(1'b1),
        .qp_lookup_active(1'b1),
        .dcqcn_event_valid(cnp_class_event_valid),
        .dcqcn_event_ready(cnp_class_event_ready),
        .dcqcn_event(cnp_class_event),
        .cnp_drop_ready(1'b1)
    );

    assign marked_ready = cnp_marked_ready &&
                          (!ud_rx_meta_valid || (ud_rx_meta_ready && ud_rx_payload_ready));

    cnp_packet_generator u_cnp_generator (
        .clk(clk),
        .rst_n(core_rst_n),
        .cnp_enable(1'b1),
        .cnp_rate_limit_cycles(16'd16),
        .ce_mark_valid(cnp_ce_valid),
        .ce_mark_ready(cnp_ce_ready),
        .ce_mark_desc_id(cnp_ce_desc_id),
        .ce_mark_qpn(cnp_ce_qpn),
        .ce_mark_cqn(cnp_ce_cqn),
        .ce_mark_owner_function(cnp_ce_owner),
        .ce_mark_pd_id(cnp_ce_pd),
        .ce_mark_opcode(cnp_ce_opcode),
        .queue_congestion_valid(1'b0),
        .queue_congestion_qpn('0),
        .queue_congestion_owner_function('0),
        .port_congestion_valid(1'b0),
        .port_congestion_qpn('0),
        .port_congestion_owner_function('0),
        .local_mac(LOCAL_MAC),
        .peer_mac(PEER_MAC),
        .local_ipv4(LOCAL_IPV4),
        .peer_ipv4(PEER_IPV4),
        .udp_src_port(ROCEV2_UDP_PORT),
        .pkey('0),
        .build_req_valid(cnp_build_valid),
        .build_req_ready(cnp_build_ready),
        .build_req(cnp_build_req)
    );

    assign tx_build_valid = cnp_build_valid || rc_build_valid || rdma_build_valid || ud_build_valid;
    assign tx_build_req = cnp_build_valid ? cnp_build_req :
                          (rc_build_valid ? rc_build_req :
                          (rdma_build_valid ? rdma_build_req : ud_build_req));
    assign cnp_build_ready = tx_build_ready;
    assign rc_build_ready = !cnp_build_valid && tx_build_ready;
    assign rdma_build_ready = !cnp_build_valid && !rc_build_valid && tx_build_ready;
    assign ud_build_ready = !cnp_build_valid && !rc_build_valid && !rdma_build_valid && tx_build_ready;

    roce_packet_builder u_packet_builder (
        .clk(clk),
        .rst_n(core_rst_n),
        .build_req_valid(tx_build_valid),
        .build_req_ready(tx_build_ready),
        .build_req(tx_build_req),
        .icrc_result_valid(1'b0),
        .icrc_result('0),
        .frame_valid(eth_tx_valid),
        .frame_ready(eth_tx_ready),
        .frame_data(eth_tx_data),
        .frame_len(eth_tx_len),
        .frame_last(eth_tx_last),
        .build_error_ready(1'b1)
    );

    // ------------------------------------------------------------------
    // Congestion control and TX scheduler gate
    // ------------------------------------------------------------------

    dcqcn_rate_update_t dcqcn_rate_update;
    logic dcqcn_rate_update_valid;
    logic dcqcn_rate_update_ready;
    pacer_tx_req_t pfc_to_pacer_req;
    pacer_decision_t pacer_decision;
    logic pfc_to_pacer_valid;
    logic pfc_to_pacer_ready;
    logic pacer_decision_valid;
    logic pacer_decision_ready;
    logic [PFC_PRIORITY_COUNT-1:0] pfc_pause_state;
    logic [PFC_COUNTER_W-1:0] pfc_pause_events;
    logic [PFC_COUNTER_W-1:0] pfc_resume_events;
    logic [PFC_COUNTER_W-1:0] pfc_stall_events;
    logic [PACER_COUNTER_W-1:0] pacer_tokens_refilled;
    logic [PACER_COUNTER_W-1:0] pacer_throttled_events;
    logic [PACER_COUNTER_W-1:0] pacer_allowed_packets;

    dcqcn_state_machine u_dcqcn (
        .clk(clk),
        .rst_n(core_rst_n),
        .config_valid(1'b0),
        .config_qpn('0),
        .config_owner_function('0),
        .config_current_rate('0),
        .config_target_rate('0),
        .config_min_rate('0),
        .config_ai_rate('0),
        .config_alpha_g_shift('0),
        .config_initial_alpha('0),
        .cnp_event_valid(cnp_class_event_valid),
        .cnp_event_ready(cnp_class_event_ready),
        .cnp_event(cnp_class_event),
        .recovery_tick_valid(1'b0),
        .recovery_tick_qpn('0),
        .recovery_tick_owner_function('0),
        .rate_update_valid(dcqcn_rate_update_valid),
        .rate_update_ready(dcqcn_rate_update_ready),
        .rate_update(dcqcn_rate_update)
    );

    pfc_pause_scheduler u_pfc_scheduler (
        .clk(clk),
        .rst_n(core_rst_n),
        .pfc_event_valid(pfc_event_valid),
        .pfc_event_ready(pfc_event_ready),
        .pfc_priority(pfc_priority),
        .pfc_pause(pfc_pause),
        .pfc_resume(pfc_resume),
        .pfc_pause_quanta(pfc_pause_quanta),
        .tx_req_valid(1'b0),
        .tx_req('0),
        .tx_qp_priority('0),
        .pacer_req_valid(pfc_to_pacer_valid),
        .pacer_req_ready(pfc_to_pacer_ready),
        .pacer_req(pfc_to_pacer_req),
        .pacer_decision_valid(pacer_decision_valid),
        .pacer_decision_ready(pacer_decision_ready),
        .pacer_decision(pacer_decision),
        .tx_decision_ready(1'b1),
        .pause_state(pfc_pause_state),
        .pfc_pause_events(pfc_pause_events),
        .pfc_resume_events(pfc_resume_events),
        .tx_stalled_due_to_pfc(pfc_stall_events)
    );

    tx_pacer_token_bucket u_tx_pacer (
        .clk(clk),
        .rst_n(core_rst_n),
        .pacer_enable(1'b1),
        .config_valid(1'b0),
        .config_qpn('0),
        .config_owner_function('0),
        .config_bucket_size('0),
        .config_initial_tokens('0),
        .config_time_now('0),
        .rate_update_valid(dcqcn_rate_update_valid),
        .rate_update_ready(dcqcn_rate_update_ready),
        .rate_update(dcqcn_rate_update),
        .pace_req_valid(pfc_to_pacer_valid),
        .pace_req_ready(pfc_to_pacer_ready),
        .pace_req(pfc_to_pacer_req),
        .time_now('0),
        .pace_decision_valid(pacer_decision_valid),
        .pace_decision_ready(pacer_decision_ready),
        .pace_decision(pacer_decision),
        .tokens_refilled(pacer_tokens_refilled),
        .tx_throttled_events(pacer_throttled_events),
        .tx_allowed_packets(pacer_allowed_packets)
    );

    // ------------------------------------------------------------------
    // Resource managers and datapath engines. 11.2-11.6 will replace the
    // tie-offs below with real CSR/Doorbell/DMA/transport connections.
    // ------------------------------------------------------------------

    logic cq_lookup_valid;
    logic cq_lookup_ready;
    logic [CQ_ID_W-1:0] cq_lookup_cqn;
    logic [VF_ID_W-1:0] cq_lookup_function_id;
    logic cq_lookup_rsp_valid;
    logic cq_lookup_rsp_ready;
    logic cq_lookup_hit;
    logic cq_lookup_miss;
    cq_table_status_e cq_lookup_status;
    cq_context_t cq_lookup_context;
    logic cmpl_cqe_write_valid;
    logic [CQ_ID_W-1:0] cmpl_cqe_write_cqn;
    logic [VF_ID_W-1:0] cmpl_cqe_write_owner_function;
    logic [CQE_W-1:0] cmpl_cqe_write_data;
    logic cmpl_cqe_write_solicited;
    cmpl_status_e cmpl_cqe_write_status;
    logic cmpl_cqe_write_error;
    logic top_completion_valid;
    logic top_completion_ready;
    completion_event_t top_completion_event;

    qp_context_table u_qp_table (
        .clk(clk),
        .rst_n(core_rst_n),
        .lookup_valid(1'b0),
        .lookup_qpn('0),
        .lookup_function_id('0),
        .lookup_pf_bypass(1'b0),
        .lookup_rsp_ready(1'b1),
        .context_write_valid(1'b0),
        .context_write_qpn('0),
        .context_write_function_id('0),
        .context_write_pf_bypass(1'b0),
        .context_write_use_index(1'b0),
        .context_write_index('0),
        .context_write_data('0),
        .context_write_rsp_ready(1'b1),
        .context_read_valid(ud_rx_qp_read_valid),
        .context_read_qpn(ud_rx_qp_read_qpn),
        .context_read_function_id(ud_rx_qp_read_function_id),
        .context_read_pf_bypass(ud_rx_qp_read_pf_bypass),
        .context_read_rsp_ready(ud_rx_qp_read_rsp_ready),
        .context_read_ready(ud_rx_qp_read_ready),
        .context_read_rsp_valid(ud_rx_qp_read_rsp_valid),
        .context_read_hit(ud_rx_qp_read_hit),
        .context_read_data(ud_rx_qp_read_data),
        .context_read_status(ud_rx_qp_read_status),
        .sq_pi_update_valid(db_sq_pi_update_valid),
        .sq_pi_update_ready(db_sq_pi_update_ready),
        .sq_pi_update_qpn(db_sq_pi_update_qpn),
        .sq_pi_update_function_id(db_sq_pi_update_function_id),
        .sq_pi_update_new_pi(db_sq_pi_update_new_pi),
        .sq_pi_update_error(db_sq_pi_update_error),
        .sq_pi_update_rsp_valid(db_sq_pi_update_rsp_valid),
        .sq_pi_update_rsp_ready(1'b1),
        .sq_pi_update_status(db_sq_pi_update_status),
        .rq_pi_update_valid(db_rq_pi_update_valid),
        .rq_pi_update_ready(db_rq_pi_update_ready),
        .rq_pi_update_qpn(db_rq_pi_update_qpn),
        .rq_pi_update_function_id(db_rq_pi_update_function_id),
        .rq_pi_update_new_pi(db_rq_pi_update_new_pi),
        .rq_pi_update_error(db_rq_pi_update_error),
        .rq_pi_update_rsp_valid(db_rq_pi_update_rsp_valid),
        .rq_pi_update_rsp_ready(1'b1),
        .rq_pi_update_status(db_rq_pi_update_status)
    );

    cq_context_table u_cq_table (
        .clk(clk),
        .rst_n(core_rst_n),
        .lookup_valid(cq_lookup_valid),
        .lookup_ready(cq_lookup_ready),
        .lookup_cqn(cq_lookup_cqn),
        .lookup_function_id(cq_lookup_function_id),
        .lookup_admin_bypass(1'b0),
        .lookup_rsp_valid(cq_lookup_rsp_valid),
        .lookup_rsp_ready(cq_lookup_rsp_ready),
        .lookup_hit(cq_lookup_hit),
        .lookup_miss(cq_lookup_miss),
        .lookup_status(cq_lookup_status),
        .lookup_context(cq_lookup_context),
        .context_write_valid(1'b0),
        .context_write_cqn('0),
        .context_write_function_id('0),
        .context_write_admin_bypass(1'b0),
        .context_write_use_index(1'b0),
        .context_write_index('0),
        .context_write_data('0),
        .context_write_rsp_ready(1'b1),
        .context_read_valid(1'b0),
        .context_read_cqn('0),
        .context_read_function_id('0),
        .context_read_admin_bypass(1'b0),
        .context_read_rsp_ready(1'b1),
        .cq_arm_valid(db_cq_arm_valid),
        .cq_arm_ready(db_cq_arm_ready),
        .cq_arm_cqn(db_cq_arm_cqn),
        .cq_arm_function_id(db_cq_arm_function_id),
        .cq_arm_consumer_index(db_cq_arm_consumer_index),
        .cq_arm_armed(db_cq_arm_armed),
        .cq_arm_solicited_only(db_cq_arm_solicited_only),
        .cq_arm_error(db_cq_arm_error),
        .cq_arm_rsp_valid(db_cq_arm_rsp_valid),
        .cq_arm_rsp_ready(1'b1),
        .cq_arm_status(db_cq_arm_status),
        .completion_update_valid(1'b0),
        .completion_update_cqn('0),
        .completion_update_owner_function('0),
        .completion_update_new_pi('0),
        .completion_update_rsp_ready(1'b1),
        .overflow_set_valid(1'b0),
        .overflow_set_cqn('0),
        .overflow_set_function_id('0),
        .overflow_set_rsp_ready(1'b1),
        .overflow_clear_valid(1'b0),
        .overflow_clear_cqn('0),
        .overflow_clear_function_id('0),
        .overflow_clear_rsp_ready(1'b1)
    );

    assign top_completion_valid = rc_completion_valid || rdma_completion_valid || ud_completion_valid;
    assign top_completion_event = rc_completion_valid ? rc_completion_event :
                                  (rdma_completion_valid ? rdma_completion_event : ud_completion_event);
    assign rc_completion_ready = top_completion_ready;
    assign rdma_completion_ready = !rc_completion_valid && top_completion_ready;
    assign ud_completion_ready = !rc_completion_valid && !rdma_completion_valid && top_completion_ready;

    completion_engine u_completion_engine (
        .clk(clk),
        .rst_n(core_rst_n),
        .event_valid(top_completion_valid),
        .event_ready(top_completion_ready),
        .event_type(top_completion_event.event_type),
        .qpn(top_completion_event.qpn),
        .cqn(top_completion_event.cqn),
        .owner_function(top_completion_event.owner_function),
        .wr_id(top_completion_event.wr_id),
        .opcode(top_completion_event.opcode),
        .status(top_completion_event.status),
        .byte_len(top_completion_event.byte_len),
        .imm_data(top_completion_event.imm_data),
        .has_imm(top_completion_event.has_imm),
        .solicited(top_completion_event.solicited),
        .vendor_error(top_completion_event.vendor_error),
        .source_engine(top_completion_event.source_engine),
        .cq_lookup_valid(cq_lookup_valid),
        .cq_lookup_ready(cq_lookup_ready),
        .cq_lookup_cqn(cq_lookup_cqn),
        .cq_lookup_function_id(cq_lookup_function_id),
        .cq_lookup_rsp_valid(cq_lookup_rsp_valid),
        .cq_lookup_rsp_ready(cq_lookup_rsp_ready),
        .cq_lookup_hit(cq_lookup_hit),
        .cq_lookup_miss(cq_lookup_miss),
        .cq_lookup_status(cq_lookup_status),
        .cq_lookup_context(cq_lookup_context),
        .cqe_write_valid(cmpl_cqe_write_valid),
        .cqe_write_ready(1'b1),
        .cqe_write_cqn(cmpl_cqe_write_cqn),
        .cqe_write_owner_function(cmpl_cqe_write_owner_function),
        .cqe_write_data(cmpl_cqe_write_data),
        .cqe_write_solicited(cmpl_cqe_write_solicited),
        .cqe_write_status(cmpl_cqe_write_status),
        .cqe_write_error(cmpl_cqe_write_error)
    );

    // 11.4 最小闭环只确认 completion 已进入 CQE formatting/commit 语义。
    // 真实 cqe_write_path + cq_notification top-level 闭环会在 11.7 测试中继续增强。
    assign rc_cq_commit_ready = 1'b1;

    dma_descriptor_dispatcher u_dma_dispatcher (
        .clk(clk),
        .rst_n(core_rst_n),
        .sq_dma_req_valid(1'b0),
        .sq_dma_req('0),
        .rq_dma_req_valid(1'b0),
        .rq_dma_req('0),
        .cqe_dma_req_valid(1'b0),
        .cqe_dma_req('0),
        .wqe_fetch_req_valid(1'b0),
        .wqe_fetch_req('0),
        .sge_fetch_req_valid(1'b0),
        .sge_fetch_req('0),
        .host_read_desc_ready(1'b1),
        .host_write_desc_ready(1'b1),
        .cqe_write_desc_ready(1'b1),
        .fetch_desc_ready(1'b1)
    );

    mr_table u_mr_table (
        .clk(clk),
        .rst_n(core_rst_n),
        .lookup_valid(1'b0),
        .lookup_key('0),
        .lookup_is_remote(1'b0),
        .lookup_owner_function('0),
        .lookup_pd_id('0),
        .lookup_admin_bypass(1'b0),
        .lookup_rsp_ready(1'b1),
        .check_valid(1'b0),
        .check_key('0),
        .check_va('0),
        .check_len('0),
        .check_is_remote(1'b0),
        .check_owner_function('0),
        .check_pd_id('0),
        .check_admin_bypass(1'b0),
        .check_rsp_ready(1'b1),
        .entry_write_valid(1'b0),
        .entry_write_use_index(1'b0),
        .entry_write_index('0),
        .entry_write_key('0),
        .entry_write_is_remote(1'b0),
        .entry_write_owner_function('0),
        .entry_write_admin_bypass(1'b0),
        .entry_write_data('0),
        .entry_write_rsp_ready(1'b1),
        .entry_read_valid(1'b0),
        .entry_read_key('0),
        .entry_read_is_remote(1'b0),
        .entry_read_owner_function('0),
        .entry_read_pd_id('0),
        .entry_read_admin_bypass(1'b0),
        .entry_read_rsp_ready(1'b1),
        .ref_inc_valid(1'b0),
        .ref_dec_valid(1'b0),
        .ref_key('0),
        .ref_is_remote(1'b0),
        .ref_owner_function('0),
        .ref_admin_bypass(1'b0),
        .ref_update_rsp_ready(1'b1)
    );

    logic [PSN_W-1:0] rc_next_psn;
    logic [3:0] rc_outstanding_count;
    rc_send_status_e rc_debug_status;

    rc_send_engine u_rc_send_engine (
        .clk(clk),
        .rst_n(core_rst_n),
        .cfg_valid(1'b0),
        .cfg_qpn('0),
        .cfg_owner_function('0),
        .cfg_pd_id('0),
        .cfg_initial_psn('0),
        .cfg_retry_limit('0),
        .cfg_retry_timeout('0),
        .tx_req_valid(1'b0),
        .tx_req('0),
        .packet_ready(1'b1),
        .ack_valid(1'b0),
        .ack_event('0),
        .timer_tick(1'b0),
        .retry_ready(1'b1),
        .qp_error_req_ready(1'b1),
        .next_psn(rc_next_psn),
        .outstanding_count(rc_outstanding_count),
        .debug_status(rc_debug_status)
    );

    assign debug_qp_status = {31'd0, core_rst_n};
    assign debug_cq_status = {30'd0, cq_lookup_valid, cq_lookup_ready};
    assign debug_transport_status = {rdma_outstanding_read_valid,
                                     rdma_debug_status[6:0],
                                     rdma_debug_state,
                                     rc_outstanding_count,
                                     rc_debug_status,
                                     rc_next_psn[7:0]};
    assign debug_congestion_status = {pfc_pause_state, 8'd0, pacer_throttled_events[7:0], pfc_stall_events[7:0]};

endmodule
