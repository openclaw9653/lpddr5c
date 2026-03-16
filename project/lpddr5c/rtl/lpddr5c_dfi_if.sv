//============================================================================
// Module: lpddr5c_dfi_if
// Description: LPDDR5 DFI 5.0 Interface Adapter
// Features:
//   - DFI 5.0 compliant interface
//   - Clock domain crossing (controller <-> PHY)
//   - Command/Address mapping
//   - Data path bridging
//   - Training signal synchronization
//============================================================================

`timescale 1ns/1ps

module lpddr5c_dfi_if #(
    parameter DATA_WIDTH        = 128,
    parameter DFI_DATA_WIDTH    = 64,
    parameter NUM_CHANNELS      = 2,
    parameter NUM_RANKS         = 1,
    parameter DQ_WIDTH          = 16,
    parameter CA_WIDTH          = 6,
    parameter CS_WIDTH          = 1,
    parameter CKE_WIDTH         = 1,
    parameter DQS_WIDTH         = 2,
    parameter DM_WIDTH          = 2
) (
    //========================================================================
    // Controller Clock Domain
    //========================================================================
    input  wire                         ctl_clk,
    input  wire                         ctl_rst_n,
    
    //========================================================================
    // PHY Clock Domain
    //========================================================================
    input  wire                         phy_clk,
    input  wire                         phy_rst_n,
    
    //========================================================================
    // Controller Interface (ctl_clk domain)
    //========================================================================
    // Command Interface
    input  wire [CS_WIDTH-1:0]          ctl_cs_n,
    input  wire [CKE_WIDTH-1:0]         ctl_cke,
    input  wire [CA_WIDTH-1:0]          ctl_ca,
    input  wire                         ctl_rw,
    input  wire                         ctl_cmd_valid,
    
    // Data Interface - Write
    input  wire [DFI_DATA_WIDTH-1:0]    ctl_wrdata,
    input  wire [DFI_DATA_WIDTH/8-1:0]  ctl_wrdata_mask,
    input  wire                         ctl_wrdata_en,
    
    // Data Interface - Read
    output wire [DFI_DATA_WIDTH-1:0]    ctl_rddata,
    output wire                         ctl_rddata_valid,
    
    // Training Interface
    input  wire                         ctl_rdlvl_en,
    input  wire                         ctl_wrlvl_en,
    output wire                         ctl_rdlvl_req,
    output wire                         ctl_wrlvl_req,
    input  wire                         ctl_phymstr_ack,
    output wire                         ctl_phymstr_req,
    input  wire                         ctl_phymstr_cs,
    
    //========================================================================
    // PHY Interface (phy_clk domain)
    //========================================================================
    // DFI Clock & Reset
    output wire                         dfi_clk,
    output wire                         dfi_rst_n,
    
    // DFI Command Interface
    output wire [CS_WIDTH-1:0]          dfi_cs_n,
    output wire [CKE_WIDTH-1:0]         dfi_cke,
    output wire [CA_WIDTH-1:0]          dfi_ca,
    output wire                         dfi_rw,
    
    // DFI Data Interface - Read
    input  wire [DFI_DATA_WIDTH-1:0]    dfi_rddata,
    input  wire                         dfi_rddata_valid,
    
    // DFI Data Interface - Write
    output wire [DFI_DATA_WIDTH-1:0]    dfi_wrdata,
    output wire [DFI_DATA_WIDTH/8-1:0]  dfi_wrdata_mask,
    output wire                         dfi_wrdata_en,
    
    // DFI Training Interface
    input  wire                         dfi_phymstr_req,
    output wire                         dfi_phymstr_ack,
    output wire                         dfi_phymstr_cs,
    input  wire                         dfi_rdlvl_req,
    output wire                         dfi_rdlvl_en,
    input  wire                         dfi_wrlvl_req,
    output wire                         dfi_wrlvl_en,
    
    //========================================================================
    // Status & Debug
    //========================================================================
    output wire [3:0]                    ctl2phy_sync_cnt,
    output wire [3:0]                    phy2ctl_sync_cnt,
    output wire                         ctl2phy_overrun,
    output wire                         phy2ctl_overrun
);

    //========================================================================
    // Local Parameters
    //========================================================================
    
    localparam SYNC_FIFO_DEPTH   = 4;
    localparam SYNC_PTR_WIDTH    = $clog2(SYNC_FIFO_DEPTH) + 1;
    
    //========================================================================
    // DFI Clock & Reset Generation
    //========================================================================
    
    // Pass through PHY clock & reset
    assign dfi_clk = phy_clk;
    assign dfi_rst_n = phy_rst_n;
    
    //========================================================================
    // Internal Signals - Command Path (Controller -> PHY)
    //========================================================================
    
    // Command FIFO signals
    typedef struct packed {
        logic [CS_WIDTH-1:0]     cs_n;
        logic [CKE_WIDTH-1:0]    cke;
        logic [CA_WIDTH-1:0]     ca;
        logic                    rw;
        logic                    valid;
    } ctl_cmd_t;
    
    ctl_cmd_t ctl_cmd_fifo [0:SYNC_FIFO_DEPTH-1];
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_wr_ptr_bin;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_wr_ptr_gray;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_rd_ptr_bin;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_rd_ptr_gray;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_wr_ptr_gray_sync1;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_wr_ptr_gray_sync2;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_rd_ptr_gray_sync1;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_cmd_rd_ptr_gray_sync2;
    wire                             ctl_cmd_fifo_full;
    wire                             ctl_cmd_fifo_empty;
    
    // Write data FIFO signals
    typedef struct packed {
        logic [DFI_DATA_WIDTH-1:0]   data;
        logic [DFI_DATA_WIDTH/8-1:0] mask;
        logic                       en;
    } ctl_wrdata_t;
    
    ctl_wrdata_t ctl_wrdata_fifo [0:SYNC_FIFO_DEPTH-1];
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_wr_ptr_bin;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_wr_ptr_gray;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_rd_ptr_bin;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_rd_ptr_gray;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_wr_ptr_gray_sync1;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_wr_ptr_gray_sync2;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_rd_ptr_gray_sync1;
    reg [SYNC_PTR_WIDTH-1:0]        ctl_wr_rd_ptr_gray_sync2;
    wire                             ctl_wr_fifo_full;
    wire                             ctl_wr_fifo_empty;
    
    //========================================================================
    // Internal Signals - Data Path (PHY -> Controller)
    //========================================================================
    
    // Read data FIFO signals
    typedef struct packed {
        logic [DFI_DATA_WIDTH-1:0]   data;
        logic                       valid;
    } phy_rddata_t;
    
    phy_rddata_t phy_rddata_fifo [0:SYNC_FIFO_DEPTH-1];
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_wr_ptr_bin;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_wr_ptr_gray;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_rd_ptr_bin;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_rd_ptr_gray;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_wr_ptr_gray_sync1;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_wr_ptr_gray_sync2;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_rd_ptr_gray_sync1;
    reg [SYNC_PTR_WIDTH-1:0]        phy_rd_rd_ptr_gray_sync2;
    wire                             phy_rd_fifo_full;
    wire                             phy_rd_fifo_empty;
    
    //========================================================================
    // Internal Signals - Training Path
    //========================================================================
    
    // Training signals (2-flop synchronizers)
    reg                              ctl_rdlvl_en_sync1, ctl_rdlvl_en_sync2;
    reg                              ctl_wrlvl_en_sync1, ctl_wrlvl_en_sync2;
    reg                              dfi_rdlvl_req_sync1, dfi_rdlvl_req_sync2;
    reg                              dfi_wrlvl_req_sync1, dfi_wrlvl_req_sync2;
    reg                              dfi_phymstr_req_sync1, dfi_phymstr_req_sync2;
    reg                              ctl_phymstr_ack_sync1, ctl_phymstr_ack_sync2;
    reg                              ctl_phymstr_cs_sync1, ctl_phymstr_cs_sync2;
    
    //========================================================================
    // Binary <-> Gray Code Conversion Functions
    //========================================================================
    
    function automatic [SYNC_PTR_WIDTH-1:0] bin2gray;
        input [SYNC_PTR_WIDTH-1:0] bin;
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction
    
    function automatic [SYNC_PTR_WIDTH-1:0] gray2bin;
        input [SYNC_PTR_WIDTH-1:0] gray;
        reg [SYNC_PTR_WIDTH-1:0] bin;
        begin
            bin = gray;
            for (int i = SYNC_PTR_WIDTH-2; i >= 0; i--)
                bin[i] = bin[i+1] ^ gray[i];
            gray2bin = bin;
        end
    endfunction
    
    //========================================================================
    // Controller -> PHY Command Path
    //========================================================================
    
    // Write side (ctl_clk domain)
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            ctl_cmd_wr_ptr_bin <= '0;
            ctl_cmd_wr_ptr_gray <= '0;
        end else begin
            if (ctl_cmd_valid && !ctl_cmd_fifo_full) begin
                // Push to FIFO
                ctl_cmd_fifo[ctl_cmd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].cs_n  <= ctl_cs_n;
                ctl_cmd_fifo[ctl_cmd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].cke   <= ctl_cke;
                ctl_cmd_fifo[ctl_cmd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].ca    <= ctl_ca;
                ctl_cmd_fifo[ctl_cmd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].rw    <= ctl_rw;
                ctl_cmd_fifo[ctl_cmd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].valid <= 1'b1;
                
                ctl_cmd_wr_ptr_bin <= ctl_cmd_wr_ptr_bin + 1'b1;
                ctl_cmd_wr_ptr_gray <= bin2gray(ctl_cmd_wr_ptr_bin + 1'b1);
            end
        end
    end
    
    // Synchronize read pointer to write domain
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            ctl_cmd_rd_ptr_gray_sync1 <= '0;
            ctl_cmd_rd_ptr_gray_sync2 <= '0;
        end else begin
            ctl_cmd_rd_ptr_gray_sync1 <= ctl_cmd_rd_ptr_gray;
            ctl_cmd_rd_ptr_gray_sync2 <= ctl_cmd_rd_ptr_gray_sync1;
        end
    end
    
    assign ctl_cmd_fifo_full = (ctl_cmd_wr_ptr_gray == 
                                {~ctl_cmd_rd_ptr_gray_sync2[SYNC_PTR_WIDTH-1:SYNC_PTR_WIDTH-2],
                                 ctl_cmd_rd_ptr_gray_sync2[SYNC_PTR_WIDTH-3:0]});
    
    // Read side (phy_clk domain)
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            ctl_cmd_rd_ptr_bin <= '0;
            ctl_cmd_rd_ptr_gray <= '0;
        end else begin
            if (!ctl_cmd_fifo_empty) begin
                // Pop from FIFO and drive DFI outputs
                dfi_cs_n  <= ctl_cmd_fifo[ctl_cmd_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].cs_n;
                dfi_cke   <= ctl_cmd_fifo[ctl_cmd_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].cke;
                dfi_ca    <= ctl_cmd_fifo[ctl_cmd_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].ca;
                dfi_rw    <= ctl_cmd_fifo[ctl_cmd_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].rw;
                
                ctl_cmd_rd_ptr_bin <= ctl_cmd_rd_ptr_bin + 1'b1;
                ctl_cmd_rd_ptr_gray <= bin2gray(ctl_cmd_rd_ptr_bin + 1'b1);
            end else begin
                // NOP when FIFO empty
                dfi_cs_n <= {CS_WIDTH{1'b1}};
                dfi_ca <= 6'b000000;
            end
        end
    end
    
    // Synchronize write pointer to read domain
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            ctl_cmd_wr_ptr_gray_sync1 <= '0;
            ctl_cmd_wr_ptr_gray_sync2 <= '0;
        end else begin
            ctl_cmd_wr_ptr_gray_sync1 <= ctl_cmd_wr_ptr_gray;
            ctl_cmd_wr_ptr_gray_sync2 <= ctl_cmd_wr_ptr_gray_sync1;
        end
    end
    
    assign ctl_cmd_fifo_empty = (ctl_cmd_rd_ptr_gray == ctl_cmd_wr_ptr_gray_sync2);
    
    //========================================================================
    // Controller -> PHY Write Data Path
    //========================================================================
    
    // Write side (ctl_clk domain)
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            ctl_wr_wr_ptr_bin <= '0;
            ctl_wr_wr_ptr_gray <= '0;
        end else begin
            if (ctl_wrdata_en && !ctl_wr_fifo_full) begin
                ctl_wrdata_fifo[ctl_wr_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].data <= ctl_wrdata;
                ctl_wrdata_fifo[ctl_wr_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].mask <= ctl_wrdata_mask;
                ctl_wrdata_fifo[ctl_wr_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].en   <= 1'b1;
                
                ctl_wr_wr_ptr_bin <= ctl_wr_wr_ptr_bin + 1'b1;
                ctl_wr_wr_ptr_gray <= bin2gray(ctl_wr_wr_ptr_bin + 1'b1);
            end
        end
    end
    
    // Synchronize read pointer
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            ctl_wr_rd_ptr_gray_sync1 <= '0;
            ctl_wr_rd_ptr_gray_sync2 <= '0;
        end else begin
            ctl_wr_rd_ptr_gray_sync1 <= ctl_wr_rd_ptr_gray;
            ctl_wr_rd_ptr_gray_sync2 <= ctl_wr_rd_ptr_gray_sync1;
        end
    end
    
    assign ctl_wr_fifo_full = (ctl_wr_wr_ptr_gray ==
                                {~ctl_wr_rd_ptr_gray_sync2[SYNC_PTR_WIDTH-1:SYNC_PTR_WIDTH-2],
                                 ctl_wr_rd_ptr_gray_sync2[SYNC_PTR_WIDTH-3:0]});
    
    // Read side (phy_clk domain)
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            ctl_wr_rd_ptr_bin <= '0;
            ctl_wr_rd_ptr_gray <= '0;
        end else begin
            if (!ctl_wr_fifo_empty) begin
                dfi_wrdata      <= ctl_wrdata_fifo[ctl_wr_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].data;
                dfi_wrdata_mask <= ctl_wrdata_fifo[ctl_wr_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].mask;
                dfi_wrdata_en   <= ctl_wrdata_fifo[ctl_wr_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].en;
                
                ctl_wr_rd_ptr_bin <= ctl_wr_rd_ptr_bin + 1'b1;
                ctl_wr_rd_ptr_gray <= bin2gray(ctl_wr_rd_ptr_bin + 1'b1);
            end else begin
                dfi_wrdata_en <= 1'b0;
            end
        end
    end
    
    // Synchronize write pointer
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            ctl_wr_wr_ptr_gray_sync1 <= '0;
            ctl_wr_wr_ptr_gray_sync2 <= '0;
        end else begin
            ctl_wr_wr_ptr_gray_sync1 <= ctl_wr_wr_ptr_gray;
            ctl_wr_wr_ptr_gray_sync2 <= ctl_wr_wr_ptr_gray_sync1;
        end
    end
    
    assign ctl_wr_fifo_empty = (ctl_wr_rd_ptr_gray == ctl_wr_wr_ptr_gray_sync2);
    
    //========================================================================
    // PHY -> Controller Read Data Path
    //========================================================================
    
    // Write side (phy_clk domain)
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            phy_rd_wr_ptr_bin <= '0;
            phy_rd_wr_ptr_gray <= '0;
        end else begin
            if (dfi_rddata_valid && !phy_rd_fifo_full) begin
                phy_rddata_fifo[phy_rd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].data  <= dfi_rddata;
                phy_rddata_fifo[phy_rd_wr_ptr_bin[SYNC_PTR_WIDTH-2:0]].valid <= 1'b1;
                
                phy_rd_wr_ptr_bin <= phy_rd_wr_ptr_bin + 1'b1;
                phy_rd_wr_ptr_gray <= bin2gray(phy_rd_wr_ptr_bin + 1'b1);
            end
        end
    end
    
    // Synchronize read pointer
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            phy_rd_rd_ptr_gray_sync1 <= '0;
            phy_rd_rd_ptr_gray_sync2 <= '0;
        end else begin
            phy_rd_rd_ptr_gray_sync1 <= phy_rd_rd_ptr_gray;
            phy_rd_rd_ptr_gray_sync2 <= phy_rd_rd_ptr_gray_sync1;
        end
    end
    
    assign phy_rd_fifo_full = (phy_rd_wr_ptr_gray ==
                                {~phy_rd_rd_ptr_gray_sync2[SYNC_PTR_WIDTH-1:SYNC_PTR_WIDTH-2],
                                 phy_rd_rd_ptr_gray_sync2[SYNC_PTR_WIDTH-3:0]});
    
    // Read side (ctl_clk domain)
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            phy_rd_rd_ptr_bin <= '0;
            phy_rd_rd_ptr_gray <= '0;
        end else begin
            if (!phy_rd_fifo_empty) begin
                ctl_rddata       <= phy_rddata_fifo[phy_rd_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].data;
                ctl_rddata_valid <= phy_rddata_fifo[phy_rd_rd_ptr_bin[SYNC_PTR_WIDTH-2:0]].valid;
                
                phy_rd_rd_ptr_bin <= phy_rd_rd_ptr_bin + 1'b1;
                phy_rd_rd_ptr_gray <= bin2gray(phy_rd_rd_ptr_bin + 1'b1);
            end else begin
                ctl_rddata_valid <= 1'b0;
            end
        end
    end
    
    // Synchronize write pointer
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            phy_rd_wr_ptr_gray_sync1 <= '0;
            phy_rd_wr_ptr_gray_sync2 <= '0;
        end else begin
            phy_rd_wr_ptr_gray_sync1 <= phy_rd_wr_ptr_gray;
            phy_rd_wr_ptr_gray_sync2 <= phy_rd_wr_ptr_gray_sync1;
        end
    end
    
    assign phy_rd_fifo_empty = (phy_rd_rd_ptr_gray == phy_rd_wr_ptr_gray_sync2);
    
    //========================================================================
    // Training Interface Synchronization
    //========================================================================
    
    // Controller -> PHY
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            ctl_rdlvl_en_sync1 <= 1'b0;
            ctl_rdlvl_en_sync2 <= 1'b0;
            ctl_wrlvl_en_sync1 <= 1'b0;
            ctl_wrlvl_en_sync2 <= 1'b0;
        end else begin
            ctl_rdlvl_en_sync1 <= ctl_rdlvl_en;
            ctl_rdlvl_en_sync2 <= ctl_rdlvl_en_sync1;
            ctl_wrlvl_en_sync1 <= ctl_wrlvl_en;
            ctl_wrlvl_en_sync2 <= ctl_wrlvl_en_sync1;
        end
    end
    
    assign dfi_rdlvl_en = ctl_rdlvl_en_sync2;
    assign dfi_wrlvl_en = ctl_wrlvl_en_sync2;
    
    // PHY -> Controller
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            dfi_rdlvl_req_sync1 <= 1'b0;
            dfi_rdlvl_req_sync2 <= 1'b0;
            dfi_wrlvl_req_sync1 <= 1'b0;
            dfi_wrlvl_req_sync2 <= 1'b0;
            dfi_phymstr_req_sync1 <= 1'b0;
            dfi_phymstr_req_sync2 <= 1'b0;
        end else begin
            dfi_rdlvl_req_sync1 <= dfi_rdlvl_req;
            dfi_rdlvl_req_sync2 <= dfi_rdlvl_req_sync1;
            dfi_wrlvl_req_sync1 <= dfi_wrlvl_req;
            dfi_wrlvl_req_sync2 <= dfi_wrlvl_req_sync1;
            dfi_phymstr_req_sync1 <= dfi_phymstr_req;
            dfi_phymstr_req_sync2 <= dfi_phymstr_req_sync1;
        end
    end
    
    assign ctl_rdlvl_req = dfi_rdlvl_req_sync2;
    assign ctl_wrlvl_req = dfi_wrlvl_req_sync2;
    assign ctl_phymstr_req = dfi_phymstr_req_sync2;
    
    // Controller -> PHY (PHY Master signals)
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            ctl_phymstr_ack_sync1 <= 1'b0;
            ctl_phymstr_ack_sync2 <= 1'b0;
            ctl_phymstr_cs_sync1 <= 1'b0;
            ctl_phymstr_cs_sync2 <= 1'b0;
        end else begin
            ctl_phymstr_ack_sync1 <= ctl_phymstr_ack;
            ctl_phymstr_ack_sync2 <= ctl_phymstr_ack_sync1;
            ctl_phymstr_cs_sync1 <= ctl_phymstr_cs;
            ctl_phymstr_cs_sync2 <= ctl_phymstr_cs_sync1;
        end
    end
    
    assign dfi_phymstr_ack = ctl_phymstr_ack_sync2;
    assign dfi_phymstr_cs = ctl_phymstr_cs_sync2;
    
    //========================================================================
    // Status & Debug Outputs
    //========================================================================
    
    // Sync counters (for debug)
    reg [3:0] ctl2phy_cnt_reg;
    reg [3:0] phy2ctl_cnt_reg;
    
    always_ff @(posedge ctl_clk or negedge ctl_rst_n) begin
        if (!ctl_rst_n) begin
            ctl2phy_cnt_reg <= '0;
        end else begin
            if (ctl_cmd_valid && !ctl_cmd_fifo_full)
                ctl2phy_cnt_reg <= ctl2phy_cnt_reg + 1'b1;
        end
    end
    
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            phy2ctl_cnt_reg <= '0;
        end else begin
            if (dfi_rddata_valid && !phy_rd_fifo_full)
                phy2ctl_cnt_reg <= phy2ctl_cnt_reg + 1'b1;
        end
    end
    
    assign ctl2phy_sync_cnt = ctl2phy_cnt_reg;
    assign phy2ctl_sync_cnt = phy2ctl_cnt_reg;
    
    // Overrun detection
    assign ctl2phy_overrun = ctl_cmd_fifo_full && ctl_cmd_valid;
    assign phy2ctl_overrun = phy_rd_fifo_full && dfi_rddata_valid;

endmodule // lpddr5c_dfi_if
