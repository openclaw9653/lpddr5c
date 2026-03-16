//============================================================================
// Module: lpddr5c_refresh_ctrl
// Description: LPDDR5 Refresh Controller
// Features:
//   - Auto-refresh generation (per tREFI)
//   - Refresh urgency tracking
//   - Per-bank refresh support (optional)
//   - Temperature-compensated refresh (TCR)
//   - Refresh command scheduling integration
//============================================================================

`timescale 1ns/1ps

module lpddr5c_refresh_ctrl #(
    parameter REFRESH_COUNTER_WIDTH  = 16,
    parameter NUM_CHANNELS           = 2,
    parameter NUM_RANKS              = 1,
    parameter NUM_BANKS              = 8
) (
    //========================================================================
    // Clock & Reset
    //========================================================================
    input  wire                         clk,
    input  wire                         rst_n,
    
    //========================================================================
    // Configuration
    //========================================================================
    input  wire [15:0]                  trefi,        // Refresh interval (in cycles)
    input  wire [15:0]                  trfc,         // Refresh cycle time (in cycles)
    input  wire [7:0]                   temp_sensor,  // Temperature sensor reading
    input  wire                         refresh_en,   // Global refresh enable
    input  wire                         temp_comp_en, // Temperature compensation enable
    input  wire                         per_bank_refresh_en,  // Per-bank refresh
    
    //========================================================================
    // Command Scheduler Interface
    //========================================================================
    output wire                         refresh_pending,
    output wire                         refresh_urgent,
    output wire [7:0]                   refresh_row_addr,
    output wire [2:0]                   refresh_bank,
    input  wire                         refresh_ack,
    input  wire                         refresh_done,
    
    //========================================================================
    // Status & Monitoring
    //========================================================================
    output wire [REFRESH_COUNTER_WIDTH-1:0] refresh_counter,
    output wire [15:0]                      refresh_count,
    output wire [7:0]                        urgency_level,
    
    //========================================================================
    // Error Reporting
    //========================================================================
    output wire                         refresh_timeout_err,
    output wire                         refresh_overdue_err
);

    //========================================================================
    // Local Parameters
    //========================================================================
    
    // Temperature compensation lookup (simplified)
    // Adjust tREFI based on temperature per JEDEC
    localparam TEMP_0_45    = 8'h00;  // 0-45°C
    localparam TEMP_45_85   = 8'h2D;  // 45-85°C
    localparam TEMP_85_95   = 8'h5A;  // 85-95°C
    localparam TEMP_95_105  = 8'h6E;  // 95-105°C
    
    // Urgency thresholds
    localparam URGENCY_LOW    = 8'h00;
    localparam URGENCY_MED    = 8'h40;
    localparam URGENCY_HIGH   = 8'h80;
    localparam URGENCY_CRIT   = 8'hC0;
    
    //========================================================================
    // Internal Signals
    //========================================================================
    
    // Temperature-compensated tREFI
    reg [REFRESH_COUNTER_WIDTH-1:0]    trefi_compensated;
    
    // Refresh counters
    reg [REFRESH_COUNTER_WIDTH-1:0]    refresh_counter_reg;
    reg [15:0]                           refresh_count_reg;
    reg [2:0]                            refresh_bank_counter;
    
    // State machine
    typedef enum logic [2:0] {
        REF_IDLE,
        REF_PENDING,
        REF_ISSUED,
        REF_WAIT_DONE,
        REF_ERROR
    } ref_state_t;
    
    ref_state_t ref_state, ref_next;
    
    // Timing tracking
    reg [15:0]                           trfc_counter;
    reg                                  trfc_active;
    
    // Urgency calculation
    reg [7:0]                            urgency_level_reg;
    
    // Error flags
    reg                                  refresh_timeout_err_reg;
    reg                                  refresh_overdue_err_reg;
    
    //========================================================================
    // Temperature Compensation for tREFI
    //========================================================================
    
    always_comb begin
        if (temp_comp_en) begin
            case (temp_sensor) inside
                [8'h00:8'h2D]: trefi_compensated = trefi;           // Normal
                [8'h2E:8'h5A]: trefi_compensated = trefi >> 1;     // 0.5x (higher temp)
                [8'h5B:8'hFF]: trefi_compensated = trefi >> 2;     // 0.25x (very high)
                default:        trefi_compensated = trefi;
            endcase
        end else begin
            trefi_compensated = trefi;
        end
    end
    
    //========================================================================
    // Refresh Counter
    //========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_counter_reg <= '0;
            refresh_count_reg <= '0;
            refresh_bank_counter <= '0;
            urgency_level_reg <= '0;
        end else begin
            if (refresh_en) begin
                // Increment counter
                if (refresh_counter_reg < trefi_compensated) begin
                    refresh_counter_reg <= refresh_counter_reg + 1'b1;
                end
                
                // Calculate urgency level
                if (refresh_counter_reg < (trefi_compensated >> 2))
                    urgency_level_reg <= URGENCY_LOW;
                else if (refresh_counter_reg < (trefi_compensated >> 1))
                    urgency_level_reg <= URGENCY_MED;
                else if (refresh_counter_reg < (trefi_compensated - (trefi_compensated >> 3)))
                    urgency_level_reg <= URGENCY_HIGH;
                else
                    urgency_level_reg <= URGENCY_CRIT;
                
                // Refresh issued: reset counter
                if (refresh_ack) begin
                    refresh_counter_reg <= '0;
                    refresh_count_reg <= refresh_count_reg + 1'b1;
                    
                    if (per_bank_refresh_en) begin
                        refresh_bank_counter <= refresh_bank_counter + 1'b1;
                    end
                end
            end else begin
                // Refresh disabled
                refresh_counter_reg <= '0;
                urgency_level_reg <= '0;
            end
        end
    end
    
    //========================================================================
    // Refresh State Machine
    //========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_state <= REF_IDLE;
            trfc_counter <= '0;
            trfc_active <= 1'b0;
            refresh_timeout_err_reg <= 1'b0;
            refresh_overdue_err_reg <= 1'b0;
        end else begin
            case (ref_state)
                REF_IDLE: begin
                    // Check if refresh needed
                    if (refresh_en && refresh_counter_reg >= trefi_compensated) begin
                        ref_state <= REF_PENDING;
                    end
                    
                    // Check for overdue error (missed refresh)
                    if (refresh_counter_reg > (trefi_compensated + 16'h100)) begin
                        refresh_overdue_err_reg <= 1'b1;
                    end
                end
                
                REF_PENDING: begin
                    if (refresh_ack) begin
                        ref_state <= REF_ISSUED;
                        trfc_active <= 1'b1;
                        trfc_counter <= trfc;
                    end
                end
                
                REF_ISSUED: begin
                    // Count down tRFC
                    if (trfc_counter > 0) begin
                        trfc_counter <= trfc_counter - 1'b1;
                    end else begin
                        trfc_active <= 1'b0;
                        ref_state <= REF_WAIT_DONE;
                    end
                end
                
                REF_WAIT_DONE: begin
                    if (refresh_done) begin
                        ref_state <= REF_IDLE;
                    end
                    
                    // Timeout check
                    if (trfc_counter == 0 && !refresh_done) begin
                        if (trfc_counter < 16'hFFFF)
                            trfc_counter <= trfc_counter + 1'b1;
                        
                        if (trfc_counter > (trfc << 2)) begin
                            refresh_timeout_err_reg <= 1'b1;
                            ref_state <= REF_ERROR;
                        end
                    end
                end
                
                REF_ERROR: begin
                    // Stay in error until cleared
                    if (!refresh_en) begin
                        ref_state <= REF_IDLE;
                        refresh_timeout_err_reg <= 1'b0;
                        refresh_overdue_err_reg <= 1'b0;
                    end
                end
                
                default: begin
                    ref_state <= REF_IDLE;
                end
            endcase
        end
    end
    
    //========================================================================
    // Output Assignments
    //========================================================================
    
    // Refresh request signals
    assign refresh_pending = (ref_state == REF_PENDING) || 
                             (ref_state == REF_IDLE && refresh_counter_reg >= trefi_compensated);
    assign refresh_urgent = (urgency_level_reg >= URGENCY_HIGH);
    
    // Refresh address (simplified - all banks refresh)
    assign refresh_row_addr = refresh_count_reg[7:0];
    assign refresh_bank = refresh_bank_counter;
    
    // Counter outputs
    assign refresh_counter = refresh_counter_reg;
    assign refresh_count = refresh_count_reg;
    assign urgency_level = urgency_level_reg;
    
    // Error outputs
    assign refresh_timeout_err = refresh_timeout_err_reg;
    assign refresh_overdue_err = refresh_overdue_err_reg;

endmodule // lpddr5c_refresh_ctrl
