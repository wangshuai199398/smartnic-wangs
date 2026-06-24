`timescale 1ns/1ps

module ah_table
    import smartnic_pkg::*;
(
    input  logic                         clk,
    input  logic                         rst_n,

    // Create：写入新的 AH entry，不允许 ah_id alias。
    input  logic                         create_valid,
    output logic                         create_ready,
    input  ah_entry_t                    create_entry,
    output logic                         create_rsp_valid,
    input  logic                         create_rsp_ready,
    output ah_table_status_e             create_status,

    // Update：按 ah_id 更新已有 AH entry。
    input  logic                         update_valid,
    output logic                         update_ready,
    input  logic [AH_ID_W-1:0]           update_ah_id,
    input  logic [VF_ID_W-1:0]           update_owner_function,
    input  logic [PD_ID_W-1:0]           update_pd_id,
    input  ah_entry_t                    update_entry,
    output logic                         update_rsp_valid,
    input  logic                         update_rsp_ready,
    output ah_table_status_e             update_status,

    // Lookup：兼容 ud_tx_engine 的 AH lookup 响应。
    input  logic                         lookup_valid,
    output logic                         lookup_ready,
    input  logic [AH_ID_W-1:0]           lookup_ah_id,
    input  logic [VF_ID_W-1:0]           lookup_owner_function,
    input  logic [PD_ID_W-1:0]           lookup_pd_id,
    output logic                         lookup_rsp_valid,
    input  logic                         lookup_rsp_ready,
    output logic                         lookup_hit,
    output ah_entry_t                    lookup_entry,
    output ah_table_status_e             lookup_status,
    output logic [15:0]                  lookup_error_code,

    // Delete：按 ah_id 删除 AH entry。
    input  logic                         delete_valid,
    output logic                         delete_ready,
    input  logic [AH_ID_W-1:0]           delete_ah_id,
    input  logic [VF_ID_W-1:0]           delete_owner_function,
    input  logic [PD_ID_W-1:0]           delete_pd_id,
    output logic                         delete_rsp_valid,
    input  logic                         delete_rsp_ready,
    output ah_table_status_e             delete_status
);

    ah_entry_t table [AH_TABLE_DEPTH];

    logic create_fire;
    logic create_rsp_fire;
    logic update_fire;
    logic update_rsp_fire;
    logic lookup_fire;
    logic lookup_rsp_fire;
    logic delete_fire;
    logic delete_rsp_fire;

    logic create_alias;
    logic create_free_found;
    logic [AH_TABLE_INDEX_W-1:0] create_free_index;
    logic update_found;
    logic update_alias;
    logic [AH_TABLE_INDEX_W-1:0] update_index;
    logic lookup_found;
    logic lookup_alias;
    logic [AH_TABLE_INDEX_W-1:0] lookup_index;
    logic delete_found;
    logic delete_alias;
    logic [AH_TABLE_INDEX_W-1:0] delete_index;

    ah_table_status_e create_status_q;
    ah_table_status_e update_status_q;
    ah_table_status_e lookup_status_q;
    ah_table_status_e delete_status_q;
    ah_entry_t lookup_entry_q;
    logic lookup_hit_q;

    assign create_ready = !create_rsp_valid || create_rsp_ready;
    assign update_ready = !update_rsp_valid || update_rsp_ready;
    assign lookup_ready = !lookup_rsp_valid || lookup_rsp_ready;
    assign delete_ready = !delete_rsp_valid || delete_rsp_ready;

    assign create_fire = create_valid && create_ready;
    assign create_rsp_fire = create_rsp_valid && create_rsp_ready;
    assign update_fire = update_valid && update_ready;
    assign update_rsp_fire = update_rsp_valid && update_rsp_ready;
    assign lookup_fire = lookup_valid && lookup_ready;
    assign lookup_rsp_fire = lookup_rsp_valid && lookup_rsp_ready;
    assign delete_fire = delete_valid && delete_ready;
    assign delete_rsp_fire = delete_rsp_valid && delete_rsp_ready;

    assign create_status = create_status_q;
    assign update_status = update_status_q;
    assign lookup_status = lookup_status_q;
    assign lookup_entry = lookup_entry_q;
    assign lookup_hit = lookup_hit_q;
    assign lookup_error_code = {12'd0, lookup_status_q};
    assign delete_status = delete_status_q;

    function automatic logic entry_min_valid(input ah_entry_t entry);
        begin
            return entry.valid &&
                   (entry.ah_id != '0) &&
                   (entry.dst_mac != 48'd0) &&
                   (entry.dst_ipv4 != 32'd0) &&
                   (entry.qkey != 32'd0);
        end
    endfunction

    function automatic logic owner_allowed(
        input ah_entry_t entry,
        input logic [VF_ID_W-1:0] owner_function,
        input logic [PD_ID_W-1:0] pd_id
    );
        begin
            return (entry.owner_func == owner_function) && (entry.pd_id == pd_id);
        end
    endfunction

    function automatic ah_table_status_e access_status(
        input logic found,
        input logic alias,
        input ah_entry_t entry,
        input logic [VF_ID_W-1:0] owner_function,
        input logic [PD_ID_W-1:0] pd_id
    );
        begin
            if (alias) begin
                return AH_TABLE_STATUS_ALIAS;
            end
            if (!found) begin
                return AH_TABLE_STATUS_MISS;
            end
            if (!owner_allowed(entry, owner_function, pd_id)) begin
                return AH_TABLE_STATUS_PERMISSION;
            end
            return AH_TABLE_STATUS_OK;
        end
    endfunction

    always_comb begin
        create_alias = 1'b0;
        create_free_found = 1'b0;
        create_free_index = '0;
        update_found = 1'b0;
        update_alias = 1'b0;
        update_index = '0;
        lookup_found = 1'b0;
        lookup_alias = 1'b0;
        lookup_index = '0;
        delete_found = 1'b0;
        delete_alias = 1'b0;
        delete_index = '0;

        for (int unsigned i = 0; i < AH_TABLE_DEPTH; i++) begin
            if (!table[i].valid && !create_free_found) begin
                create_free_found = 1'b1;
                create_free_index = AH_TABLE_INDEX_W'(i);
            end

            if (table[i].valid && (table[i].ah_id == create_entry.ah_id)) begin
                create_alias = 1'b1;
            end

            if (table[i].valid && (table[i].ah_id == update_ah_id)) begin
                if (!update_found) begin
                    update_found = 1'b1;
                    update_index = AH_TABLE_INDEX_W'(i);
                end else begin
                    update_alias = 1'b1;
                end
            end

            if (table[i].valid && (table[i].ah_id == lookup_ah_id)) begin
                if (!lookup_found) begin
                    lookup_found = 1'b1;
                    lookup_index = AH_TABLE_INDEX_W'(i);
                end else begin
                    lookup_alias = 1'b1;
                end
            end

            if (table[i].valid && (table[i].ah_id == delete_ah_id)) begin
                if (!delete_found) begin
                    delete_found = 1'b1;
                    delete_index = AH_TABLE_INDEX_W'(i);
                end else begin
                    delete_alias = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            create_rsp_valid <= 1'b0;
            update_rsp_valid <= 1'b0;
            lookup_rsp_valid <= 1'b0;
            delete_rsp_valid <= 1'b0;
            create_status_q <= AH_TABLE_STATUS_OK;
            update_status_q <= AH_TABLE_STATUS_OK;
            lookup_status_q <= AH_TABLE_STATUS_OK;
            delete_status_q <= AH_TABLE_STATUS_OK;
            lookup_entry_q <= '0;
            lookup_hit_q <= 1'b0;
            for (int unsigned i = 0; i < AH_TABLE_DEPTH; i++) begin
                table[i] <= '0;
            end
        end else begin
            if (create_rsp_fire) begin
                create_rsp_valid <= 1'b0;
            end
            if (update_rsp_fire) begin
                update_rsp_valid <= 1'b0;
            end
            if (lookup_rsp_fire) begin
                lookup_rsp_valid <= 1'b0;
            end
            if (delete_rsp_fire) begin
                delete_rsp_valid <= 1'b0;
            end

            if (create_fire) begin
                create_rsp_valid <= 1'b1;
                if (!entry_min_valid(create_entry)) begin
                    create_status_q <= AH_TABLE_STATUS_INVALID;
                end else if (create_alias) begin
                    create_status_q <= AH_TABLE_STATUS_ALIAS;
                end else if (!create_free_found) begin
                    create_status_q <= AH_TABLE_STATUS_FULL;
                end else begin
                    table[create_free_index] <= create_entry;
                    create_status_q <= AH_TABLE_STATUS_OK;
                end
            end

            if (update_fire) begin
                update_rsp_valid <= 1'b1;
                update_status_q <= access_status(update_found, update_alias, table[update_index],
                                                 update_owner_function, update_pd_id);
                if (access_status(update_found, update_alias, table[update_index],
                                  update_owner_function, update_pd_id) == AH_TABLE_STATUS_OK) begin
                    if (entry_min_valid(update_entry) && (update_entry.ah_id == update_ah_id)) begin
                        table[update_index] <= update_entry;
                        update_status_q <= AH_TABLE_STATUS_OK;
                    end else begin
                        update_status_q <= AH_TABLE_STATUS_INVALID;
                    end
                end
            end

            if (lookup_fire) begin
                lookup_rsp_valid <= 1'b1;
                lookup_status_q <= access_status(lookup_found, lookup_alias, table[lookup_index],
                                                 lookup_owner_function, lookup_pd_id);
                lookup_hit_q <= (access_status(lookup_found, lookup_alias, table[lookup_index],
                                               lookup_owner_function, lookup_pd_id) == AH_TABLE_STATUS_OK);
                lookup_entry_q <= (lookup_found && !lookup_alias) ? table[lookup_index] : '0;
            end

            if (delete_fire) begin
                delete_rsp_valid <= 1'b1;
                delete_status_q <= access_status(delete_found, delete_alias, table[delete_index],
                                                 delete_owner_function, delete_pd_id);
                if (access_status(delete_found, delete_alias, table[delete_index],
                                  delete_owner_function, delete_pd_id) == AH_TABLE_STATUS_OK) begin
                    table[delete_index] <= '0;
                    delete_status_q <= AH_TABLE_STATUS_OK;
                end
            end
        end
    end

endmodule
