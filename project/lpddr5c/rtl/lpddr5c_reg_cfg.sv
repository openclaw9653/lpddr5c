//============================================================================
// Module: lpddr5c_reg_cfg
// Description: LPDDR5 Controller Register Configuration (APB Interface)
// Features:
//   - APB4 compliant interface
//   - Configuration registers for timing, mode, training
//   - Status registers for monitoring
//   - Interrupt generation
//============================================================================

`timescale 1ns/1ps

module lpddr5c_reg_cfg #(
    parameter ADDR_WIDTH    = 16,
    parameter DATA_WIDTH    = 32
) (
    //========================================================================
    // APB Interface
    //========================================================================
    input  wire                     pclk,
    input  wire                     preset_n,
    input  wire                     psel,
    input  wire                     penable,
    input  wire                     pwrite,
    input  wire [ADDR_WIDTH-1:0]    paddr,
    input  wire [DATA_WIDTH-1:0]     pwdata,
    output reg  [DATA_WIDTH-1:0]     prdata,
    output reg                      pready,
    output reg                      pslverr,
    
    //========================================================================
    // Register Outputs (to controller logic)
    //========================================================================
    output reg  [31:0]              reg_ctrl0,
    output reg  [31:0]              reg_ctrl1,
    output reg  [31:0]              reg_ctrl2,
    output reg  [31:0]              reg_ctrl3,
    output reg  [31:0]              reg_timing0,
    output reg  [31:0]              reg_timing1,
    output reg  [31:0]              reg_timing2,
    output reg  [31:0]              reg_timing3,
    output reg  [31:0]              reg_timing4,
    output reg  [31:0]              reg_timing5,
    output reg  [31:0]              reg_ecc_cfg,
    output reg  [31:0]              reg_lp_cfg,
    output reg  [31:0]              reg_train_cfg,
    output reg  [31:0]              reg_test_cfg,
    
    //========================================================================
    // Status Inputs (from controller logic)
    //========================================================================
    input  wire [31:0]              reg_status,
    input  wire                      training_done,
    input  wire                      training_error,
    input  wire                      lp_state,
    input  wire                      refresh_pending,
    input  wire [7:0]                ecc_err_count,
    input  wire [15:0]               refresh_counter,
    
    //========================================================================
    // Interrupt Outputs
    //========================================================================
    output reg                      intr_init_done,
    output reg                      intr_training_error,
    output reg                      intr_refresh_err,
    output reg                      intr_ecc_err
);

    //========================================================================
    // Local Parameters - Register Addresses
    //========================================================================
    
    localparam REG_CTRL0       = 16'h0000;  // Main Control
    localparam REG_CTRL1       = 16'h0004;  // Mode Control
    localparam REG_CTRL2       = 16'h0008;  // Channel/Rank Control
    localparam REG_CTRL3       = 16'h000C;  // Burst Control
    
    localparam REG_TIMING0     = 16'h0010;  // tRCD, tRP, tRAS, tRC
    localparam REG_TIMING1     = 16'h0014;  // tRRD, tCCD, tWTR
    localparam REG_TIMING2     = 16'h0018;  // tRTP, tWR, tFAW
    localparam REG_TIMING3     = 16'h001C;  // tXSR, tXP, tCKE
    localparam REG_TIMING4     = 16'h0020;  // tREFI, tRFC
    localparam REG_TIMING5     = 16'h0024;  // tMOD, tZQ
    
    localparam REG_STATUS0     = 16'h0040;  // Main Status
    localparam REG_STATUS1     = 16'h0044;  // Error Status
    localparam REG_STATUS2     = 16'h0048;  // Counter Status
    localparam REG_STATUS3     = 16'h004C;  // Training Status
    
    localparam REG_ECC_CFG     = 16'h0060;  // ECC Configuration
    localparam REG_LP_CFG      = 16'h0070;  // Low Power Configuration
    localparam REG_TRAIN_CFG   = 16'h0080;  // Training Configuration
    
    localparam REG_INTR_EN     = 16'h00A0;  // Interrupt Enable
    localparam REG_INTR_STAT   = 16'h00A4;  // Interrupt Status
    localparam REG_INTR_CLR    = 16'h00A8;  // Interrupt Clear
    
    localparam REG_TEST_CFG    = 16'h00F0;  // Test/BIST Configuration
    localparam REG_TEST_CTRL   = 16'h00F4;  // Test Control
    localparam REG_TEST_STAT   = 16'h00F8;  // Test Status
    
    //========================================================================
    // Internal Signals
    //========================================================================
    
    // Status registers
    reg [31:0]                    reg_status0;
    reg [31:0]                    reg_status1;
    reg [31:0]                    reg_status2;
    reg [31:0]                    reg_status3;
    
    // Interrupt registers
    reg [31:0]                    reg_intr_en;
    reg [31:0]                    reg_intr_stat;
    
    // Edge detection for interrupts
    reg                            training_done_d1, training_done_rise;
    reg                            training_error_d1, training_error_rise;
    reg                            refresh_pending_d1, refresh_urgent_rise;
    
    //========================================================================
    // APB State Machine
    //========================================================================
    
    typedef enum logic [1:0] {
        APB_IDLE,
        APB_SETUP,
        APB_ACCESS
    } apb_state_t;
    
    apb_state_t apb_state, apb_next;
    
    //========================================================================
    // Default Register Values
    //========================================================================
    
    task automatic set_default_regs;
        begin
            // Control registers (defaults based on LPDDR5-6400)
            reg_ctrl0       <= 32'h0000_0000;  // Disabled, no training
            reg_ctrl1       <= 32'h0000_0018;  // CL=24, CWL=18 (6400)
            reg_ctrl2       <= 32'h0000_0001;  // 2 channels, 1 rank
            reg_ctrl3       <= 32'h0000_0010;  // BL=16, burst chop
            
            // Timing registers (in cycles at 200MHz controller clock)
            reg_timing0     <= 32'h1E_12_12_0C; // tRC=30, tRAS=18, tRP=12, tRCD=12
            reg_timing1     <= 32'h04_02_04_02; // tWTR_L=4, tWTR_S=2, tCCD_L=4, tCCD_S=2
            reg_timing2     <= 32'h10_08_04_08; // tWR=16, tRTP=8, tRRD_L=4, tRRD_S=4
            reg_timing3     <= 32'h64_08_04_02; // tXSR=100, tXP=8, tCKE=4, tMOD=2
            reg_timing4     <= 32'h04B0_015E;    // tREFI=1200 (3900ns), tRFC=350
            reg_timing5     <= 32'h0080_0010;    // tZQ=128, tMOD=16
            
            // ECC, LP, Training, Test
            reg_ecc_cfg     <= 32'h0000_0001;  // ECC enabled, single-bit correction
            reg_lp_cfg      <= 32'h0000_0100;  // Auto-PD enabled, threshold=256
            reg_train_cfg   <= 32'h0000_0000;  // No auto-training
            reg_test_cfg    <= 32'h0000_0000;  // No test mode
        end
    endtask
    
    //========================================================================
    // Sequential Logic
    //========================================================================
    
    always_ff @(posedge pclk or negedge preset_n) begin
        if (!preset_n) begin
            // Reset
            apb_state <= APB_IDLE;
            prdata <= '0;
            pready <= 1'b0;
            pslverr <= 1'b0;
            
            // Set default register values
            set_default_regs();
            
            // Status registers
            reg_status0 <= '0;
            reg_status1 <= '0;
            reg_status2 <= '0;
            reg_status3 <= '0;
            
            // Interrupt registers
            reg_intr_en <= '0;
            reg_intr_stat <= '0;
            
            // Interrupt outputs
            intr_init_done <= 1'b0;
            intr_training_error <= 1'b0;
            intr_refresh_err <= 1'b0;
            intr_ecc_err <= 1'b0;
            
            // Edge detectors
            training_done_d1 <= 1'b0;
            training_error_d1 <= 1'b0;
            refresh_pending_d1 <= 1'b0;
            
        end else begin
            // Defaults
            pready <= 1'b0;
            pslverr <= 1'b0;
            
            // Edge detection for interrupts
            training_done_d1 <= training_done;
            training_error_d1 <= training_error;
            refresh_pending_d1 <= refresh_pending;
            
            training_done_rise <= training_done && !training_done_d1;
            training_error_rise <= training_error && !training_error_d1;
            refresh_urgent_rise <= refresh_pending && !refresh_pending_d1 && 
                                    (refresh_counter < 8'h10);  // Urgent when < 16
            
            //================================================================
            // Update Status Registers
            //================================================================
            
            // Status0: Main Status
            reg_status0[0]    <= training_done;        // Init done
            reg_status0[1]    <= training_error;       // Training error
            reg_status0[2]    <= refresh_pending;      // Refresh pending
            reg_status0[3]    <= lp_state;             // Low power state
            reg_status0[7:4]  <= 4'b0;                 // Reserved
            reg_status0[15:8] <= ecc_err_count;        // ECC error count
            reg_status0[31:16]<= 16'b0;                // Reserved
            
            // Status1: Error Status
            reg_status1[0]    <= training_error;
            reg_status1[1]    <= (ecc_err_count > 0);
            reg_status1[2]    <= refresh_urgent_rise;
            reg_status1[31:3] <= '0;
            
            // Status2: Counter Status
            reg_status2[15:0] <= refresh_counter;
            reg_status2[31:16]<= '0;
            
            // Status3: Training Status
            reg_status3[0]    <= training_done;
            reg_status3[1]    <= training_error;
            reg_status3[31:2] <= '0;
            
            //================================================================
            // Interrupt Generation
            //================================================================
            
            // Set interrupt status on rising edge
            if (training_done_rise)
                reg_intr_stat[0] <= 1'b1;
            if (training_error_rise)
                reg_intr_stat[1] <= 1'b1;
            if (refresh_urgent_rise)
                reg_intr_stat[2] <= 1'b1;
            if (|ecc_err_count)
                reg_intr_stat[3] <= 1'b1;
            
            // Clear interrupt on write to REG_INTR_CLR
            if (apb_state == APB_ACCESS && pwrite && paddr == REG_INTR_CLR) begin
                if (pwdata[0]) reg_intr_stat[0] <= 1'b0;
                if (pwdata[1]) reg_intr_stat[1] <= 1'b0;
                if (pwdata[2]) reg_intr_stat[2] <= 1'b0;
                if (pwdata[3]) reg_intr_stat[3] <= 1'b0;
            end
            
            // Interrupt outputs (level-sensitive, masked)
            intr_init_done    <= reg_intr_stat[0] && reg_intr_en[0];
            intr_training_error<= reg_intr_stat[1] && reg_intr_en[1];
            intr_refresh_err  <= reg_intr_stat[2] && reg_intr_en[2];
            intr_ecc_err      <= reg_intr_stat[3] && reg_intr_en[3];
            
            //================================================================
            // APB FSM
            //================================================================
            
            case (apb_state)
                APB_IDLE: begin
                    if (psel && !penable) begin
                        apb_state <= APB_SETUP;
                    end
                end
                
                APB_SETUP: begin
                    if (psel && penable) begin
                        apb_state <= APB_ACCESS;
                        pready <= 1'b1;
                        
                        // Write
                        if (pwrite) begin
                            case (paddr)
                                REG_CTRL0:       reg_ctrl0       <= pwdata;
                                REG_CTRL1:       reg_ctrl1       <= pwdata;
                                REG_CTRL2:       reg_ctrl2       <= pwdata;
                                REG_CTRL3:       reg_ctrl3       <= pwdata;
                                REG_TIMING0:     reg_timing0     <= pwdata;
                                REG_TIMING1:     reg_timing1     <= pwdata;
                                REG_TIMING2:     reg_timing2     <= pwdata;
                                REG_TIMING3:     reg_timing3     <= pwdata;
                                REG_TIMING4:     reg_timing4     <= pwdata;
                                REG_TIMING5:     reg_timing5     <= pwdata;
                                REG_ECC_CFG:     reg_ecc_cfg     <= pwdata;
                                REG_LP_CFG:      reg_lp_cfg      <= pwdata;
                                REG_TRAIN_CFG:   reg_train_cfg   <= pwdata;
                                REG_INTR_EN:     reg_intr_en     <= pwdata;
                                REG_TEST_CFG:    reg_test_cfg    <= pwdata;
                                // REG_INTR_CLR handled above
                                default:         pslverr         <= 1'b1;
                            endcase
                        end
                        // Read
                        else begin
                            case (paddr)
                                REG_CTRL0:       prdata <= reg_ctrl0;
                                REG_CTRL1:       prdata <= reg_ctrl1;
                                REG_CTRL2:       prdata <= reg_ctrl2;
                                REG_CTRL3:       prdata <= reg_ctrl3;
                                REG_TIMING0:     prdata <= reg_timing0;
                                REG_TIMING1:     prdata <= reg_timing1;
                                REG_TIMING2:     prdata <= reg_timing2;
                                REG_TIMING3:     prdata <= reg_timing3;
                                REG_TIMING4:     prdata <= reg_timing4;
                                REG_TIMING5:     prdata <= reg_timing5;
                                REG_STATUS0:     prdata <= reg_status0;
                                REG_STATUS1:     prdata <= reg_status1;
                                REG_STATUS2:     prdata <= reg_status2;
                                REG_STATUS3:     prdata <= reg_status3;
                                REG_ECC_CFG:     prdata <= reg_ecc_cfg;
                                REG_LP_CFG:      prdata <= reg_lp_cfg;
                                REG_TRAIN_CFG:   prdata <= reg_train_cfg;
                                REG_INTR_EN:     prdata <= reg_intr_en;
                                REG_INTR_STAT:   prdata <= reg_intr_stat;
                                REG_TEST_CFG:    prdata <= reg_test_cfg;
                                default: begin
                                    prdata <= 32'hDEADBEEF;
                                    pslverr <= 1'b1;
                                end
                            endcase
                        end
                    end
                end
                
                APB_ACCESS: begin
                    apb_state <= APB_IDLE;
                    pready <= 1'b0;
                    pslverr <= 1'b0;
                end
                
                default: begin
                    apb_state <= APB_IDLE;
                end
            endcase
        end
    end

endmodule // lpddr5c_reg_cfg
