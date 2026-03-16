//============================================================================
// Module: lpddr5c_cmd_scheduler
// Description: LPDDR5 Command Scheduler
// Features:
//   - Age-based priority scheduling
//   - Bank state tracking
//   - Timing constraint checking (tRCD, tRP, tRAS, tRC, etc.)
//   - Refresh priority handling
//   - Read/Write command optimization
//   - QoS support (optional)
//============================================================================

`timescale 1ns/1ps

module lpddr5c_cmd_scheduler #(
    parameter ADDR_WIDTH        = 32,
    parameter DATA_WIDTH        = 128,
    parameter NUM_CHANNELS      = 2,
    parameter NUM_RANKS         = 1,
    parameter NUM_BANKS         = 8,
    parameter NUM_BANK_GROUPS   = 2,
    parameter ROW_WIDTH         = 16,
    parameter COL_WIDTH         = 10,
    parameter BA_WIDTH          = 3,        // Bank address width
    parameter BG_WIDTH          = 1,        // Bank group width
    parameter CMD_QUEUE_DEPTH   = 16,
    parameter CMD_ID_WIDTH      = 8
) (
    //========================================================================
    // Clock & Reset
    //========================================================================
    input  wire                         clk,
    input  wire                         rst_n,
    
    //========================================================================
    // Configuration
    //========================================================================
    input  wire [31:0]                  timing_params,
    input  wire [3:0]                   sched_policy,
    input  wire [1:0]                   qos_en,
    
    //========================================================================
    // Command Input Interface
    //========================================================================
    input  wire [ADDR_WIDTH-1:0]        cmd_addr,
    input  wire [3:0]                    cmd_type,
    input  wire                         cmd_valid,
    output wire                         cmd_ready,
    input  wire [CMD_ID_WIDTH-1:0]      cmd_id,
    
    //========================================================================
    // Refresh Interface
    //========================================================================
    input  wire                         refresh_req,
    output wire                         refresh_ack,
    input  wire                         refresh_urgent,
    input  wire [7:0]                    refresh_row,
    
    //========================================================================
    // Bank State Tracking
    //========================================================================
    output wire [NUM_CHANNELS-1:0]      bank_active [0:NUM_BANKS-1],
    output wire [NUM_CHANNELS-1:0]      row_open,
    output wire [ROW_WIDTH-1:0]         open_row [0:NUM_CHANNELS-1],
    
    //========================================================================
    // DFI Command Output
    //========================================================================
    output wire [NUM_RANKS-1:0]          dfi_cs_n,
    output wire [NUM_CHANNELS-1:0]       dfi_cke,
    output wire [5:0]                    dfi_ca,
    output wire                         dfi_rw
);

    //========================================================================
    // Local Parameters
    //========================================================================
    
    // Command Types
    localparam CMD_NOP          = 4'b0000;
    localparam CMD_READ         = 4'b0001;
    localparam CMD_WRITE        = 4'b0010;
    localparam CMD_ACTIVATE     = 4'b0011;
    localparam CMD_PRECHARGE    = 4'b0100;
    localparam CMD_REFRESH      = 4'b0101;
    localparam CMD_MRW          = 4'b0110;  // Mode Register Write
    localparam CMD_MRR          = 4'b0111;  // Mode Register Read
    localparam CMD_PDOWN_ENTRY  = 4'b1000;
    localparam CMD_PDOWN_EXIT   = 4'b1001;
    localparam CMD_SR_ENTRY     = 4'b1010;  // Self-Refresh Entry
    localparam CMD_SR_EXIT      = 4'b1011;  // Self-Refresh Exit
    
    // LPDDR5 CA Commands
    localparam CA_NOP           = 6'b000000;
    localparam CA_RD            = 6'b000001;
    localparam CA_WR            = 6'b000010;
    localparam CA_ACT           = 6'b000011;
    localparam CA_PRE           = 6'b000100;
    localparam CA_PREA          = 6'b000101;  // Precharge All
    localparam CA_REF           = 6'b000110;
    localparam CA_MRW           = 6'b000111;
    localparam CA_MRR           = 6'b001000;
    localparam CA_SRE           = 6'b001001;  // Self-Refresh Entry
    localparam CA_SRX           = 6'b001010;  // Self-Refresh Exit
    localparam CA_PDE           = 6'b001011;  // Power-Down Entry
    localparam CA_PDX           = 6'b001100;  // Power-Down Exit
    
    // Timing Parameters (from timing_params register)
    wire [7:0]                     tRCD;        // 15:0
    wire [7:0]                     tRP;         // 23:16
    wire [7:0]                     tRAS;        // 31:24
    wire [7:0]                     tRC;         // Derived: tRAS + tRP
    wire [7:0]                     tRRD_L;      // Row-to-Row delay (same BG)
    wire [7:0]                     tRRD_S;      // Row-to-Row delay (different BG)
    wire [7:0]                     tCCD_L;      // Column-to-Column delay (same BG)
    wire [7:0]                     tCCD_S;      // Column-to-Column delay (different BG)
    wire [7:0]                     tWTR_L;      // Write-to-Read (same BG)
    wire [7:0]                     tWTR_S;      // Write-to-Read (different BG)
    wire [7:0]                     tRTRS;       // Read-to-Read (different rank)
    wire [7:0]                     tFAW;        // Four Activate Window
    wire [7:0]                     tRTP;        // Read to Precharge
    wire [7:0]                     tWR;         // Write Recovery
    wire [7:0]                     tWRS;        // Write Recovery (same bank)
    wire [7:0]                     tXSR;        // Self-Refresh Exit
    wire [7:0]                     tXP;         // Power-Down Exit
    
    assign tRCD  = timing_params[7:0];
    assign tRP   = timing_params[15:8];
    assign tRAS  = timing_params[23:16];
    assign tRC   = timing_params[31:24];
    assign tRRD_L = 8'd4;   // Default: 4 cycles
    assign tRRD_S = 8'd2;   // Default: 2 cycles
    assign tCCD_L = 8'd4;   // Default: 4 cycles
    assign tCCD_S = 8'd2;   // Default: 2 cycles
    assign tWTR_L = 8'd10;  // Default: 10 cycles
    assign tWTR_S = 8'd4;   // Default: 4 cycles
    assign tRTP  = 8'd8;    // Default: 8 cycles
    assign tWR   = 8'd16;   // Default: 16 cycles
    assign tXSR  = 8'd100;  // Default: 100 cycles
    assign tXP   = 8'd8;    // Default: 8 cycles
    
    //========================================================================
    // Command Queue
    //========================================================================
    
    typedef struct packed {
        logic [ADDR_WIDTH-1:0]     addr;
        logic [3:0]                cmd_type;
        logic [CMD_ID_WIDTH-1:0]   cmd_id;
        logic [15:0]               age;
        logic [1:0]                qos;
        logic                       valid;
    } cmd_queue_entry_t;
    
    cmd_queue_entry_t cmd_queue [0:CMD_QUEUE_DEPTH-1];
    logic [$clog2(CMD_QUEUE_DEPTH)-1:0]  cmd_queue_wptr;
    logic [$clog2(CMD_QUEUE_DEPTH)-1:0]  cmd_queue_rptr;
    logic [$clog2(CMD_QUEUE_DEPTH)-1:0]  cmd_queue_entries;
    logic                                 cmd_queue_full;
    logic                                 cmd_queue_empty;
    
    //========================================================================
    // Address Decoding
    //========================================================================
    
    function automatic [BA_WIDTH-1:0] get_bank_addr;
        input [ADDR_WIDTH-1:0] addr;
        begin
            // Example mapping: addr[11:9] for 8 banks
            get_bank_addr = addr[11:9];
        end
    endfunction
    
    function automatic [BG_WIDTH-1:0] get_bankgroup_addr;
        input [ADDR_WIDTH-1:0] addr;
        begin
            // Example mapping: addr[12] for 2 bank groups
            get_bankgroup_addr = addr[12];
        end
    endfunction
    
    function automatic [ROW_WIDTH-1:0] get_row_addr;
        input [ADDR_WIDTH-1:0] addr;
        begin
            // Example mapping: addr[31:16] for 16-bit row
            get_row_addr = addr[31:16];
        end
    endfunction
    
    function automatic [COL_WIDTH-1:0] get_col_addr;
        input [ADDR_WIDTH-1:0] addr;
        begin
            // Example mapping: addr[15:8] for 8-bit column (adjust)
            get_col_addr = addr[15:8];
        end
    endfunction
    
    //========================================================================
    // Bank State Tracking
    //========================================================================
    
    typedef struct packed {
        logic                       active;
        logic [ROW_WIDTH-1:0]       open_row;
        logic [15:0]                ras_counter;  // tRAS countdown
        logic [15:0]                rp_counter;   // tRP countdown
        logic [15:0]                rcd_counter;  // tRCD countdown
        logic                       timing_met;
    } bank_state_t;
    
    bank_state_t bank_state [0:NUM_CHANNELS-1][0:NUM_BANKS-1];
    
    // Per-channel activation tracking for tFAW
    logic [3:0]                      activate_tracker [0:NUM_CHANNELS-1];
    logic [15:0]                     faw_counter [0:NUM_CHANNELS-1];
    
    //========================================================================
    // Timing Constraint Check
    //========================================================================
    
    function automatic logic check_bank_timing;
        input integer channel;
        input integer bank;
        input [3:0] cmd_type;
        begin
            automatic bank_state_t state = bank_state[channel][bank];
            automatic logic timing_ok = 1'b1;
            
            case (cmd_type)
                CMD_ACTIVATE: begin
                    // Check tRP (precharge to activate)
                    if (!state.active && state.rp_counter > 0)
                        timing_ok = 1'b0;
                    // Check if bank is already active
                    if (state.active)
                        timing_ok = 1'b0;
                end
                
                CMD_READ, CMD_WRITE: begin
                    // Check tRCD (activate to column)
                    if (state.rcd_counter > 0)
                        timing_ok = 1'b0;
                    // Bank must be active
                    if (!state.active)
                        timing_ok = 1'b0;
                end
                
                CMD_PRECHARGE: begin
                    // Check tRAS (activate to precharge)
                    if (state.ras_counter > 0)
                        timing_ok = 1'b0;
                    // Bank must be active
                    if (!state.active)
                        timing_ok = 1'b0;
                end
                
                default: begin
                    timing_ok = 1'b1;
                end
            endcase
            
            check_bank_timing = timing_ok;
        end
    endfunction
    
    function automatic logic check_faw_timing;
        input integer channel;
        begin
            // Check if 4 activates in tFAW window
            check_faw_timing = (activate_tracker[channel] < 4);
        end
    endfunction
    
    //========================================================================
    // Scheduler Selection Logic
    //========================================================================
    
    logic [$clog2(CMD_QUEUE_DEPTH)-1:0] best_candidate_idx;
    cmd_queue_entry_t best_candidate;
    logic [31:0]                       candidate_score [0:CMD_QUEUE_DEPTH-1];
    logic                               candidate_valid [0:CMD_QUEUE_DEPTH-1];
    
    always_comb begin
        // Reset
        best_candidate_idx = '0;
        best_candidate = '0;
        
        // Calculate scores for all valid entries
        for (int i = 0; i < CMD_QUEUE_DEPTH; i++) begin
            candidate_score[i] = 32'd0;
            candidate_valid[i] = 1'b0;
            
            if (cmd_queue[i].valid) begin
                // Age-based priority
                candidate_score[i] = {16'd0, cmd_queue[i].age};
                
                // Page hit bonus (same row already open)
                automatic integer bank = get_bank_addr(cmd_queue[i].addr);
                automatic integer channel = 0;  // TODO: Multi-channel support
                if (bank_state[channel][bank].active &&
                    bank_state[channel][bank].open_row == get_row_addr(cmd_queue[i].addr)) begin
                    candidate_score[i] += 32'd1000;  // Page hit bonus
                end
                
                // QoS priority
                if (qos_en) begin
                    candidate_score[i] += {cmd_queue[i].qos, 28'd0};
                end
                
                candidate_valid[i] = check_bank_timing(
                    channel, bank, cmd_queue[i].cmd_type
                );
            end
        end
        
        // Find best candidate (highest score)
        for (int i = 0; i < CMD_QUEUE_DEPTH; i++) begin
            if (candidate_valid[i]) begin
                if (best_candidate_idx == '0 || 
                    candidate_score[i] > candidate_score[best_candidate_idx]) begin
                    best_candidate_idx = i;
                    best_candidate = cmd_queue[i];
                end
            end
        end
    end
    
    //========================================================================
    // Refresh Priority Handling
    //========================================================================
    
    logic refresh_in_progress;
    logic refresh_state;
    
    //========================================================================
    // Main Sequential Logic
    //========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset
            cmd_queue_wptr <= '0;
            cmd_queue_rptr <= '0;
            cmd_queue_entries <= '0;
            cmd_queue_full <= 1'b0;
            cmd_queue_empty <= 1'b1;
            
            // Clear command queue
            for (int i = 0; i < CMD_QUEUE_DEPTH; i++) begin
                cmd_queue[i] <= '0;
            end
            
            // Reset bank states
            for (int c = 0; c < NUM_CHANNELS; c++) begin
                for (int b = 0; b < NUM_BANKS; b++) begin
                    bank_state[c][b] <= '0;
                    bank_active[b][c] <= 1'b0;
                end
                row_open[c] <= 1'b0;
                open_row[c] <= '0;
                activate_tracker[c] <= '0;
                faw_counter[c] <= '0;
            end
            
            // DFI outputs
            dfi_cs_n <= {NUM_RANKS{1'b1}};
            dfi_cke <= '0;
            dfi_ca <= CA_NOP;
            dfi_rw <= 1'b0;
            
            refresh_in_progress <= 1'b0;
            refresh_state <= 1'b0;
            
        end else begin
            //================================================================
            // Command Queue Push
            //================================================================
            if (cmd_valid && cmd_ready) begin
                cmd_queue[cmd_queue_wptr].addr     <= cmd_addr;
                cmd_queue[cmd_queue_wptr].cmd_type <= cmd_type;
                cmd_queue[cmd_queue_wptr].cmd_id   <= cmd_id;
                cmd_queue[cmd_queue_wptr].age      <= 16'd0;
                cmd_queue[cmd_queue_wptr].qos      <= cmd_addr[1:0];  // Example QoS from address
                cmd_queue[cmd_queue_wptr].valid    <= 1'b1;
                
                cmd_queue_wptr <= cmd_queue_wptr + 1'b1;
                cmd_queue_entries <= cmd_queue_entries + 1'b1;
            end
            
            //================================================================
            // Age Increment for all queue entries
            //================================================================
            for (int i = 0; i < CMD_QUEUE_DEPTH; i++) begin
                if (cmd_queue[i].valid) begin
                    cmd_queue[i].age <= cmd_queue[i].age + 1'b1;
                end
            end
            
            //================================================================
            // Bank Timing Counters
            //================================================================
            for (int c = 0; c < NUM_CHANNELS; c++) begin
                for (int b = 0; b < NUM_BANKS; b++) begin
                    if (bank_state[c][b].ras_counter > 0)
                        bank_state[c][b].ras_counter <= bank_state[c][b].ras_counter - 1'b1;
                    if (bank_state[c][b].rp_counter > 0)
                        bank_state[c][b].rp_counter <= bank_state[c][b].rp_counter - 1'b1;
                    if (bank_state[c][b].rcd_counter > 0)
                        bank_state[c][b].rcd_counter <= bank_state[c][b].rcd_counter - 1'b1;
                end
                
                // tFAW counter
                if (faw_counter[c] > 0)
                    faw_counter[c] <= faw_counter[c] - 1'b1;
                if (faw_counter[c] == 1)
                    activate_tracker[c] <= '0;
            end
            
            //================================================================
            // Command Issue / Refresh Handling
            //================================================================
            if (refresh_req && !refresh_in_progress) begin
                // High priority: Issue Refresh command
                dfi_cs_n <= {NUM_RANKS{1'b0}};
                dfi_ca   <= CA_REF;
                dfi_rw   <= 1'b0;
                refresh_ack <= 1'b1;
                refresh_in_progress <= 1'b1;
                
            end else if (best_candidate.valid && candidate_valid[best_candidate_idx]) begin
                // Issue best candidate command
                automatic integer bank = get_bank_addr(best_candidate.addr);
                automatic integer channel = 0;
                
                case (best_candidate.cmd_type)
                    CMD_ACTIVATE: begin
                        dfi_ca <= CA_ACT;
                        // Update bank state
                        bank_state[channel][bank].active <= 1'b1;
                        bank_state[channel][bank].open_row <= get_row_addr(best_candidate.addr);
                        bank_state[channel][bank].ras_counter <= tRAS;
                        bank_state[channel][bank].rcd_counter <= tRCD;
                        // tFAW tracking
                        activate_tracker[channel] <= activate_tracker[channel] + 1'b1;
                        if (activate_tracker[channel] == 0)
                            faw_counter[channel] <= tFAW;
                    end
                    
                    CMD_READ: begin
                        dfi_ca <= CA_RD;
                        dfi_rw <= 1'b0;
                        // Set tRTP counter if needed
                    end
                    
                    CMD_WRITE: begin
                        dfi_ca <= CA_WR;
                        dfi_rw <= 1'b1;
                        // Set tWR counter if needed
                    end
                    
                    CMD_PRECHARGE: begin
                        dfi_ca <= CA_PRE;
                        bank_state[channel][bank].active <= 1'b0;
                        bank_state[channel][bank].rp_counter <= tRP;
                    end
                    
                    default: begin
                        dfi_ca <= CA_NOP;
                    end
                endcase
                
                dfi_cs_n <= {NUM_RANKS{1'b0}};
                dfi_cke <= {NUM_CHANNELS{1'b1}};
                
                // Remove from queue
                cmd_queue[best_candidate_idx].valid <= 1'b0;
                cmd_queue_entries <= cmd_queue_entries - 1'b1;
                
            end else begin
                // No command to issue: NOP
                dfi_cs_n <= {NUM_RANKS{1'b1}};
                dfi_ca <= CA_NOP;
                dfi_rw <= 1'b0;
            end
            
            //================================================================
            // Refresh ACK deassert
            //================================================================
            if (refresh_ack) begin
                refresh_ack <= 1'b0;
                refresh_in_progress <= 1'b0;
            end
        end
    end
    
    //========================================================================
    // Output Assignments
    //========================================================================
    
    assign cmd_ready = !cmd_queue_full && (cmd_queue_entries < CMD_QUEUE_DEPTH);
    
    // Bank status outputs
    always_comb begin
        for (int c = 0; c < NUM_CHANNELS; c++) begin
            for (int b = 0; b < NUM_BANKS; b++) begin
                bank_active[b][c] = bank_state[c][b].active;
            end
            row_open[c] = |bank_state[c];  // Any bank active in channel
            if (bank_state[c][0].active)
                open_row[c] = bank_state[c][0].open_row;
        end
    end

endmodule // lpddr5c_cmd_scheduler
