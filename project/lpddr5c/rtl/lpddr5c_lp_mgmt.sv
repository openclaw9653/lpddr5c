//============================================================================
// Module: lpddr5c_lp_mgmt
// Description: LPDDR5 Low Power Management
// Features:
//   - Power-Down (PD) entry/exit
//   - Self-Refresh (SR) entry/exit
//   - Deep Sleep (DS) entry/exit
//   - Automatic low-power state transition
//   - Dynamic wakeup latency management
//============================================================================

`timescale 1ns/1ps

module lpddr5c_lp_mgmt #(
    parameter NUM_CHANNELS      = 2,
    parameter NUM_RANKS         = 1,
    parameter IDLE_THRESHOLD    = 256,
    parameter SR_THRESHOLD      = 1024
) (
    //========================================================================
    // Clock & Reset
    //========================================================================
    input  wire                         clk,
    input  wire                         rst_n,
    
    //========================================================================
    // Configuration
    //========================================================================
    input  wire [31:0]                  lp_cfg,
    
    //========================================================================
    // Control Interface
    //========================================================================
    input  wire                         lp_req_pd,
    input  wire                         lp_req_sr,
    input  wire                         lp_req_ds,
    output wire                         lp_ack,
    
    //========================================================================
    // Activity Detection
    //========================================================================
    input  wire                         cmd_activity,
    input  wire                         rd_activity,
    input  wire                         wr_activity,
    
    //========================================================================
    // DFI Interface
    //========================================================================
    output wire [NUM_CHANNELS-1:0]       dfi_cke,
    output wire                         dfi_pd_entry,
    output wire                         dfi_pd_exit,
    output wire                         dfi_sr_entry,
    output wire                         dfi_sr_exit,
    
    //========================================================================
    // Status
    //========================================================================
    output wire [3:0]                    lp_state,
    output wire [15:0]                   idle_count,
    output wire [15:0]                   pd_entry_count,
    output wire [15:0]                   sr_entry_count,
    output wire [15:0]                   ds_entry_count,
    
    //========================================================================
    // Wakeup Control
    //========================================================================
    input  wire                         wakeup_req,
    output wire                         wakeup_ack,
    output wire [7:0]                    wakeup_latency
);

    //========================================================================
    // Local Parameters
    //========================================================================
    
    // Low Power States
    typedef enum logic [3:0] {
        LP_NORMAL,          // Normal operation (CKE=1)
        LP_PD_ENTRY,        // Power-Down entry sequence
        LP_PD,              // Power-Down state (CKE=0)
        LP_PD_EXIT,         // Power-Down exit sequence
        LP_SR_ENTRY,        // Self-Refresh entry sequence
        LP_SR,              // Self-Refresh state (CKE=0, auto-refresh)
        LP_SR_EXIT,         // Self-Refresh exit sequence
        LP_DS_ENTRY,        // Deep Sleep entry sequence
        LP_DS,              // Deep Sleep state (lowest power)
        LP_DS_EXIT,         // Deep Sleep exit sequence
        LP_WAKEUP           // Wakeup in progress
    } lp_state_t;
    
    lp_state_t state, next_state;
    
    //========================================================================
    // Configuration Register Fields
    //========================================================================
    
    wire                               auto_pd_en      = lp_cfg[0];
    wire                               auto_sr_en      = lp_cfg[1];
    wire                               auto_ds_en      = lp_cfg[2];
    wire [15:0]                        pd_threshold    = lp_cfg[31:16];
    wire [15:0]                        sr_threshold    = lp_cfg[15:0];
    wire [7:0]                         t_xp            = 8'd8;      // Power-down exit latency
    wire [7:0]                         t_xsr           = 8'd100;    // Self-refresh exit latency
    wire [7:0]                         t_dpd           = 8'd200;    // Deep sleep exit latency
    
    //========================================================================
    // Internal Signals
    //========================================================================
    
    // Activity & Idle counters
    reg [15:0]                          idle_counter;
    reg [15:0]                          pd_entry_counter;
    reg [15:0]                          sr_entry_counter;
    reg [15:0]                          ds_entry_counter;
    
    // State timers
    reg [7:0]                           state_timer;
    reg [3:0]                           current_state_reg;
    
    // CKE control
    reg [NUM_CHANNELS-1:0]              cke_reg;
    reg                                 cke_override;
    
    // Activity detection
    wire                                any_activity;
    reg                                 activity_prev;
    
    // Acknowledge
    reg                                 lp_ack_reg;
    reg                                 wakeup_ack_reg;
    
    //========================================================================
    // Activity Detection
    //========================================================================
    
    assign any_activity = cmd_activity || rd_activity || wr_activity;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idle_counter <= '0;
            activity_prev <= 1'b0;
        end else begin
            activity_prev <= any_activity;
            
            if (any_activity && !activity_prev) begin
                // Activity detected - reset idle counter
                idle_counter <= '0;
            end else if (!any_activity) begin
                // No activity - increment idle counter
                if (idle_counter < 16'hFFFF) begin
                    idle_counter <= idle_counter + 1'b1;
                end
            end
        end
    end
    
    //========================================================================
    // Low Power State Machine
    //========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= LP_NORMAL;
            current_state_reg <= 4'b0001;
            cke_reg <= {NUM_CHANNELS{1'b1}};
            cke_override <= 1'b0;
            state_timer <= '0;
            lp_ack_reg <= 1'b0;
            wakeup_ack_reg <= 1'b0;
            pd_entry_counter <= '0;
            sr_entry_counter <= '0;
            ds_entry_counter <= '0;
        end else begin
            // Defaults
            lp_ack_reg <= 1'b0;
            wakeup_ack_reg <= 1'b0;
            
            case (state)
                //================================================================
                // Normal Operation
                //================================================================
                LP_NORMAL: begin
                    cke_reg <= {NUM_CHANNELS{1'b1}};
                    state_timer <= '0;
                    
                    // Check for manual low-power requests
                    if (lp_req_pd) begin
                        state <= LP_PD_ENTRY;
                        lp_ack_reg <= 1'b1;
                    end else if (lp_req_sr) begin
                        state <= LP_SR_ENTRY;
                        lp_ack_reg <= 1'b1;
                    end else if (lp_req_ds) begin
                        state <= LP_DS_ENTRY;
                        lp_ack_reg <= 1'b1;
                    end
                    // Check for auto low-power
                    else if (auto_pd_en && idle_counter >= pd_threshold) begin
                        state <= LP_PD_ENTRY;
                        pd_entry_counter <= pd_entry_counter + 1'b1;
                    end else if (auto_sr_en && idle_counter >= sr_threshold) begin
                        state <= LP_SR_ENTRY;
                        sr_entry_counter <= sr_entry_counter + 1'b1;
                    end
                end
                
                //================================================================
                // Power-Down Sequence
                //================================================================
                LP_PD_ENTRY: begin
                    // Wait for all banks to precharge
                    if (state_timer < 4) begin
                        state_timer <= state_timer + 1'b1;
                    end else begin
                        // Drop CKE to enter power-down
                        cke_reg <= '0;
                        state <= LP_PD;
                        state_timer <= '0;
                    end
                end
                
                LP_PD: begin
                    cke_reg <= '0;
                    
                    // Check for wakeup condition
                    if (wakeup_req || any_activity || lp_req_pd == 0) begin
                        state <= LP_PD_EXIT;
                        wakeup_ack_reg <= 1'b1;
                    end
                end
                
                LP_PD_EXIT: begin
                    // Assert CKE and wait tXP
                    cke_reg <= {NUM_CHANNELS{1'b1}};
                    
                    if (state_timer < t_xp) begin
                        state_timer <= state_timer + 1'b1;
                    end else begin
                        state <= LP_WAKEUP;
                        state_timer <= '0;
                    end
                end
                
                //================================================================
                // Self-Refresh Sequence
                //================================================================
                LP_SR_ENTRY: begin
                    // Issue refresh command first
                    if (state_timer < 8) begin
                        state_timer <= state_timer + 1'b1;
                    end else begin
                        // Drop CKE to enter self-refresh
                        cke_reg <= '0;
                        state <= LP_SR;
                        state_timer <= '0;
                    end
                end
                
                LP_SR: begin
                    cke_reg <= '0;
                    
                    // Check for wakeup
                    if (wakeup_req || lp_req_sr == 0) begin
                        state <= LP_SR_EXIT;
                        wakeup_ack_reg <= 1'b1;
                    end
                end
                
                LP_SR_EXIT: begin
                    // Assert CKE and wait tXSR
                    cke_reg <= {NUM_CHANNELS{1'b1}};
                    
                    if (state_timer < t_xsr) begin
                        state_timer <= state_timer + 1'b1;
                    end else begin
                        state <= LP_WAKEUP;
                        state_timer <= '0;
                    end
                end
                
                //================================================================
                // Deep Sleep Sequence (Simplified)
                //================================================================
                LP_DS_ENTRY: begin
                    // Similar to SR but lower power
                    cke_reg <= '0;
                    state <= LP_DS;
                    ds_entry_counter <= ds_entry_counter + 1'b1;
                end
                
                LP_DS: begin
                    cke_reg <= '0;
                    
                    if (wakeup_req || lp_req_ds == 0) begin
                        state <= LP_DS_EXIT;
                        wakeup_ack_reg <= 1'b1;
                    end
                end
                
                LP_DS_EXIT: begin
                    // Longer wakeup time from deep sleep
                    cke_reg <= {NUM_CHANNELS{1'b1}};
                    
                    if (state_timer < t_dpd) begin
                        state_timer <= state_timer + 1'b1;
                    end else begin
                        state <= LP_WAKEUP;
                        state_timer <= '0;
                    end
                end
                
                //================================================================
                // Wakeup
                //================================================================
                LP_WAKEUP: begin
                    cke_reg <= {NUM_CHANNELS{1'b1}};
                    
                    // Short stabilization period
                    if (state_timer < 4) begin
                        state_timer <= state_timer + 1'b1;
                    end else begin
                        state <= LP_NORMAL;
                        state_timer <= '0;
                        idle_counter <= '0;
                    end
                end
                
                default: begin
                    state <= LP_NORMAL;
                end
            endcase
            
            // Update state register for output
            case (state)
                LP_NORMAL:    current_state_reg <= 4'b0001;
                LP_PD:        current_state_reg <= 4'b0010;
                LP_SR:        current_state_reg <= 4'b0100;
                LP_DS:        current_state_reg <= 4'b1000;
                default:      current_state_reg <= 4'b0001;
            endcase
        end
    end
    
    //========================================================================
    // Output Assignments
    //========================================================================
    
    // DFI outputs
    assign dfi_cke = cke_reg;
    
    assign dfi_pd_entry = (state == LP_PD_ENTRY);
    assign dfi_pd_exit   = (state == LP_PD_EXIT);
    assign dfi_sr_entry  = (state == LP_SR_ENTRY);
    assign dfi_sr_exit   = (state == LP_SR_EXIT);
    
    // Status outputs
    assign lp_state = current_state_reg;
    assign idle_count = idle_counter;
    assign pd_entry_count = pd_entry_counter;
    assign sr_entry_count = sr_entry_counter;
    assign ds_entry_count = ds_entry_counter;
    
    // Wakeup latency based on current state
    always_comb begin
        case (state)
            LP_PD:      wakeup_latency = t_xp;
            LP_PD_EXIT: wakeup_latency = t_xp - state_timer;
            LP_SR:      wakeup_latency = t_xsr;
            LP_SR_EXIT: wakeup_latency = t_xsr - state_timer;
            LP_DS:      wakeup_latency = t_dpd;
            LP_DS_EXIT: wakeup_latency = t_dpd - state_timer;
            default:    wakeup_latency = 8'd0;
        endcase
    end
    
    // Acknowledges
    assign lp_ack = lp_ack_reg;
    assign wakeup_ack = wakeup_ack_reg;

endmodule // lpddr5c_lp_mgmt
