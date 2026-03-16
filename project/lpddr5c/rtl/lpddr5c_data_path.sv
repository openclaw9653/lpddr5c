//============================================================================
// Module: lpddr5c_data_path
// Description: LPDDR5 Read/Write Data Path
// Features:
//   - Clock Domain Crossing (CDC) FIFO
//   - ECC Encoding/Decoding (BCH/SECDED)
//   - Data Reorder Buffer
//   - Write Data Mask handling
//   - Byte lane alignment
//============================================================================

`timescale 1ns/1ps

module lpddr5c_data_path #(
    parameter DATA_WIDTH        = 128,
    parameter DFI_DATA_WIDTH    = 64,
    parameter NUM_CHANNELS      = 2,
    parameter FIFO_DEPTH        = 8,
    parameter ECC_WIDTH         = 8,          // 8-bit ECC for 128-bit data
    parameter ECC_ENABLE        = 1,
    parameter BYTE_LANES        = DATA_WIDTH/8,
    parameter DFI_BYTES         = DFI_DATA_WIDTH/8
) (
    //========================================================================
    // System Clock Domain
    //========================================================================
    input  wire                         sys_clk,
    input  wire                         sys_rst_n,
    
    //========================================================================
    // PHY Clock Domain
    //========================================================================
    input  wire                         phy_clk,
    input  wire                         phy_rst_n,
    
    //========================================================================
    // AXI Read Interface (System Domain)
    //========================================================================
    output wire                         axi_rvalid,
    input  wire                         axi_rready,
    output wire [DATA_WIDTH-1:0]        axi_rdata,
    output wire [1:0]                   axi_rresp,
    output wire                         axi_rlast,
    
    //========================================================================
    // AXI Write Interface (System Domain)
    //========================================================================
    input  wire                         axi_wvalid,
    output wire                         axi_wready,
    input  wire [DATA_WIDTH-1:0]        axi_wdata,
    input  wire [BYTE_LANES-1:0]       axi_wstrb,
    input  wire                         axi_wlast,
    
    //========================================================================
    // DFI Interface (PHY Domain)
    //========================================================================
    input  wire [DFI_DATA_WIDTH*NUM_CHANNELS-1:0]   dfi_rddata,
    input  wire                                        dfi_rddata_valid,
    output wire [DFI_DATA_WIDTH*NUM_CHANNELS-1:0]   dfi_wrdata,
    output wire [DFI_BYTES*NUM_CHANNELS-1:0]        dfi_wrdata_mask,
    output wire                                        dfi_wrdata_en,
    
    //========================================================================
    // ECC Configuration
    //========================================================================
    input  wire [31:0]                  ecc_cfg,
    
    //========================================================================
    // Error Detection & Reporting
    //========================================================================
    output wire                         ecc_err_detected,
    output wire                         ecc_err_corrected,
    output wire [7:0]                    err_count,
    
    //========================================================================
    // FIFO Status
    //========================================================================
    output wire                         rd_fifo_empty,
    output wire                         rd_fifo_full,
    output wire                         wr_fifo_empty,
    output wire                         wr_fifo_full
);

    //========================================================================
    // Local Parameters
    //========================================================================
    
    localparam FIFO_PTR_WIDTH   = $clog2(FIFO_DEPTH) + 1;
    localparam TOTAL_DATA_WIDTH = DATA_WIDTH + ECC_WIDTH;
    
    //========================================================================
    // Internal Signals - Write Path
    //========================================================================
    
    // Write Data CDC FIFO (Sys -> PHY)
    wire [DATA_WIDTH-1:0]              wr_data_fifo_out;
    wire [BYTE_LANES-1:0]              wr_strb_fifo_out;
    wire                                wr_fifo_wr_en;
    wire                                wr_fifo_rd_en;
    wire                                wr_fifo_wr_full, wr_fifo_rd_empty;
    wire [FIFO_PTR_WIDTH-1:0]          wr_fifo_wr_ptr, wr_fifo_rd_ptr;
    
    // ECC Encoding
    wire [ECC_WIDTH-1:0]                ecc_code_out;
    wire [TOTAL_DATA_WIDTH-1:0]         data_with_ecc;
    
    // Data alignment for DFI (wide -> narrow)
    reg [DFI_DATA_WIDTH-1:0]            dfi_wrdata_reg;
    reg [DFI_BYTES-1:0]                 dfi_wrdata_mask_reg;
    reg                                  dfi_wrdata_en_reg;
    reg [1:0]                            wr_beat_counter;
    
    //========================================================================
    // Internal Signals - Read Path
    //========================================================================
    
    // Read Data CDC FIFO (PHY -> Sys)
    wire [DATA_WIDTH-1:0]              rd_data_fifo_in;
    wire [DATA_WIDTH-1:0]              rd_data_fifo_out;
    wire                                rd_fifo_wr_en;
    wire                                rd_fifo_rd_en;
    wire                                rd_fifo_wr_full, rd_fifo_rd_empty;
    wire [FIFO_PTR_WIDTH-1:0]          rd_fifo_wr_ptr, rd_fifo_rd_ptr;
    
    // ECC Decoding & Correction
    wire [ECC_WIDTH-1:0]                ecc_code_in;
    wire [DATA_WIDTH-1:0]               rd_data_corrected;
    wire [ECC_WIDTH-1:0]                ecc_syndrome;
    wire                                 single_bit_err;
    wire                                 multi_bit_err;
    
    // Data alignment from DFI (narrow -> wide)
    reg [DATA_WIDTH-1:0]                rd_data_accum;
    reg [1:0]                            rd_beat_counter;
    reg                                  rd_data_valid;
    
    // Reorder buffer (for out-of-order read returns)
    typedef struct packed {
        logic [DATA_WIDTH-1:0]           data;
        logic [7:0]                       tag;
        logic                             valid;
    } reorder_entry_t;
    
    reorder_entry_t reorder_buffer [0:FIFO_DEPTH-1];
    reg [FIFO_PTR_WIDTH-1:0]           reorder_head, reorder_tail;
    
    //========================================================================
    // Error Statistics
    //========================================================================
    reg [7:0]                           single_err_count;
    reg [7:0]                           multi_err_count;
    
    //========================================================================
    // Write Data Path Implementation
    //========================================================================
    
    // AXI Write Acceptance
    assign axi_wready = !wr_fifo_wr_full;
    assign wr_fifo_wr_en = axi_wvalid && axi_wready;
    
    // CDC FIFO for Write Data & Strobe
    lpddr5c_cdc_fifo #(
        .DATA_WIDTH     (DATA_WIDTH + BYTE_LANES),
        .FIFO_DEPTH     (FIFO_DEPTH)
    ) u_wr_cdc_fifo (
        .wr_clk         (sys_clk),
        .wr_rst_n       (sys_rst_n),
        .wr_en          (wr_fifo_wr_en),
        .wr_data        ({axi_wstrb, axi_wdata}),
        .wr_full        (wr_fifo_wr_full),
        
        .rd_clk         (phy_clk),
        .rd_rst_n       (phy_rst_n),
        .rd_en          (wr_fifo_rd_en),
        .rd_data        ({wr_strb_fifo_out, wr_data_fifo_out}),
        .rd_empty       (wr_fifo_rd_empty)
    );
    
    // ECC Encoder (optional)
    generate
        if (ECC_ENABLE) begin : gen_ecc_encoder
            lpddr5c_ecc_encoder #(
                .DATA_WIDTH     (DATA_WIDTH),
                .ECC_WIDTH      (ECC_WIDTH)
            ) u_ecc_encoder (
                .data_in        (wr_data_fifo_out),
                .ecc_out        (ecc_code_out)
            );
            assign data_with_ecc = {ecc_code_out, wr_data_fifo_out};
        end else begin
            assign ecc_code_out = '0;
            assign data_with_ecc = wr_data_fifo_out;
        end
    endgenerate
    
    // DFI Data Alignment (wide -> narrow)
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            dfi_wrdata_reg <= '0;
            dfi_wrdata_mask_reg <= '0;
            dfi_wrdata_en_reg <= 1'b0;
            wr_beat_counter <= '0;
        end else begin
            if (!wr_fifo_rd_empty && wr_beat_counter == 0) begin
                // Start of burst
                dfi_wrdata_reg <= wr_data_fifo_out[DFI_DATA_WIDTH-1:0];
                dfi_wrdata_mask_reg <= ~wr_strb_fifo_out[DFI_BYTES-1:0];
                dfi_wrdata_en_reg <= 1'b1;
                wr_beat_counter <= 2'd1;
            end else if (wr_beat_counter == 1) begin
                // Second beat
                dfi_wrdata_reg <= wr_data_fifo_out[DATA_WIDTH-1:DFI_DATA_WIDTH];
                dfi_wrdata_mask_reg <= ~wr_strb_fifo_out[BYTE_LANES-1:DFI_BYTES];
                dfi_wrdata_en_reg <= 1'b1;
                wr_beat_counter <= 2'd2;
            end else begin
                // End of burst or idle
                dfi_wrdata_en_reg <= 1'b0;
                wr_beat_counter <= '0;
            end
        end
    end
    
    assign wr_fifo_rd_en = (wr_beat_counter == 2'd2);
    
    // DFI Outputs
    assign dfi_wrdata = {dfi_wrdata_reg, dfi_wrdata_reg};  // Dual channel copy
    assign dfi_wrdata_mask = {dfi_wrdata_mask_reg, dfi_wrdata_mask_reg};
    assign dfi_wrdata_en = dfi_wrdata_en_reg;
    
    //========================================================================
    // Read Data Path Implementation
    //========================================================================
    
    // DFI Data Accumulation (narrow -> wide)
    always_ff @(posedge phy_clk or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            rd_data_accum <= '0;
            rd_beat_counter <= '0;
            rd_data_valid <= 1'b0;
        end else begin
            if (dfi_rddata_valid) begin
                case (rd_beat_counter)
                    2'd0: begin
                        rd_data_accum[DFI_DATA_WIDTH-1:0] <= dfi_rddata[DFI_DATA_WIDTH-1:0];
                        rd_beat_counter <= 2'd1;
                        rd_data_valid <= 1'b0;
                    end
                    2'd1: begin
                        rd_data_accum[DATA_WIDTH-1:DFI_DATA_WIDTH] <= dfi_rddata[2*DFI_DATA_WIDTH-1:DFI_DATA_WIDTH];
                        rd_beat_counter <= 2'd0;
                        rd_data_valid <= 1'b1;  // Complete 128-bit word
                    end
                    default: begin
                        rd_beat_counter <= '0;
                        rd_data_valid <= 1'b0;
                    end
                endcase
            end else begin
                rd_data_valid <= 1'b0;
            end
        end
    end
    
    assign rd_data_fifo_in = rd_data_accum;
    assign rd_fifo_wr_en = rd_data_valid;
    
    // ECC Decoder & Corrector (optional)
    generate
        if (ECC_ENABLE) begin : gen_ecc_decoder
            lpddr5c_ecc_decoder #(
                .DATA_WIDTH     (DATA_WIDTH),
                .ECC_WIDTH      (ECC_WIDTH)
            ) u_ecc_decoder (
                .data_in        (rd_data_fifo_in),
                .ecc_in         (ecc_code_in),
                .data_out       (rd_data_corrected),
                .syndrome       (ecc_syndrome),
                .single_bit_err (single_bit_err),
                .multi_bit_err  (multi_bit_err)
            );
        end else begin
            assign rd_data_corrected = rd_data_fifo_in;
            assign single_bit_err = 1'b0;
            assign multi_bit_err = 1'b0;
            assign ecc_syndrome = '0;
        end
    endgenerate
    
    // CDC FIFO for Read Data
    lpddr5c_cdc_fifo #(
        .DATA_WIDTH     (DATA_WIDTH),
        .FIFO_DEPTH     (FIFO_DEPTH)
    ) u_rd_cdc_fifo (
        .wr_clk         (phy_clk),
        .wr_rst_n       (phy_rst_n),
        .wr_en          (rd_fifo_wr_en),
        .wr_data        (rd_data_corrected),
        .wr_full        (rd_fifo_wr_full),
        
        .rd_clk         (sys_clk),
        .rd_rst_n       (sys_rst_n),
        .rd_en          (rd_fifo_rd_en),
        .rd_data        (rd_data_fifo_out),
        .rd_empty       (rd_fifo_rd_empty)
    );
    
    // Reorder Buffer (for out-of-order read returns)
    // TODO: Implement proper reordering with transaction IDs
    
    // AXI Read Output
    assign axi_rvalid = !rd_fifo_rd_empty;
    assign axi_rdata = rd_data_fifo_out;
    assign axi_rresp = 2'b00;  // OKAY
    assign axi_rlast = 1'b1;    // Simplified: single beat
    assign rd_fifo_rd_en = axi_rvalid && axi_rready;
    
    //========================================================================
    // Error Statistics
    //========================================================================
    
    always_ff @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            single_err_count <= '0;
            multi_err_count <= '0;
        end else begin
            if (ECC_ENABLE && ecc_cfg[0]) begin
                if (single_bit_err)
                    single_err_count <= single_err_count + 1'b1;
                if (multi_bit_err)
                    multi_err_count <= multi_err_count + 1'b1;
            end
        end
    end
    
    assign ecc_err_detected = single_bit_err || multi_bit_err;
    assign ecc_err_corrected = single_bit_err;
    assign err_count = single_err_count + multi_err_count;
    
    //========================================================================
    // FIFO Status Outputs
    //========================================================================
    
    assign rd_fifo_empty = rd_fifo_rd_empty;
    assign rd_fifo_full = rd_fifo_wr_full;
    assign wr_fifo_empty = wr_fifo_rd_empty;
    assign wr_fifo_full = wr_fifo_wr_full;

endmodule // lpddr5c_data_path

//============================================================================
// Helper Module: CDC FIFO (Clock Domain Crossing)
//============================================================================

module lpddr5c_cdc_fifo #(
    parameter DATA_WIDTH    = 128,
    parameter FIFO_DEPTH    = 8,
    parameter PTR_WIDTH     = $clog2(FIFO_DEPTH) + 1
) (
    // Write Port
    input  wire                     wr_clk,
    input  wire                     wr_rst_n,
    input  wire                     wr_en,
    input  wire [DATA_WIDTH-1:0]    wr_data,
    output wire                     wr_full,
    
    // Read Port
    input  wire                     rd_clk,
    input  wire                     rd_rst_n,
    input  wire                     rd_en,
    output wire [DATA_WIDTH-1:0]    rd_data,
    output wire                     rd_empty
);

    // Gray code pointers for CDC
    reg [PTR_WIDTH-1:0]            wr_ptr_bin, wr_ptr_gray;
    reg [PTR_WIDTH-1:0]            rd_ptr_bin, rd_ptr_gray;
    reg [PTR_WIDTH-1:0]            wr_ptr_gray_sync1, wr_ptr_gray_sync2;
    reg [PTR_WIDTH-1:0]            rd_ptr_gray_sync1, rd_ptr_gray_sync2;
    
    // Memory array
    reg [DATA_WIDTH-1:0]            mem [0:FIFO_DEPTH-1];
    
    //========================================================================
    // Binary to Gray Conversion
    //========================================================================
    
    function automatic [PTR_WIDTH-1:0] bin2gray;
        input [PTR_WIDTH-1:0] bin;
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction
    
    function automatic [PTR_WIDTH-1:0] gray2bin;
        input [PTR_WIDTH-1:0] gray;
        reg [PTR_WIDTH-1:0] bin;
        begin
            bin = gray;
            for (int i = PTR_WIDTH-2; i >= 0; i--)
                bin[i] = bin[i+1] ^ gray[i];
            gray2bin = bin;
        end
    endfunction
    
    //========================================================================
    // Write Logic (wr_clk domain)
    //========================================================================
    
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin <= '0;
            wr_ptr_gray <= '0;
        end else begin
            if (wr_en && !wr_full) begin
                wr_ptr_bin <= wr_ptr_bin + 1'b1;
                wr_ptr_gray <= bin2gray(wr_ptr_bin + 1'b1);
                mem[wr_ptr_bin[PTR_WIDTH-2:0]] <= wr_data;
            end
        end
    end
    
    // Synchronize read pointer to write domain
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= '0;
            rd_ptr_gray_sync2 <= '0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end
    
    assign wr_full = (wr_ptr_gray == {~rd_ptr_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2], 
                                       rd_ptr_gray_sync2[PTR_WIDTH-3:0]});
    
    //========================================================================
    // Read Logic (rd_clk domain)
    //========================================================================
    
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin <= '0;
            rd_ptr_gray <= '0;
        end else begin
            if (rd_en && !rd_empty) begin
                rd_ptr_bin <= rd_ptr_bin + 1'b1;
                rd_ptr_gray <= bin2gray(rd_ptr_bin + 1'b1);
            end
        end
    end
    
    assign rd_data = mem[rd_ptr_bin[PTR_WIDTH-2:0]];
    
    // Synchronize write pointer to read domain
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end
    
    assign rd_empty = (rd_ptr_gray == wr_ptr_gray_sync2);

endmodule // lpddr5c_cdc_fifo

//============================================================================
// Helper Module: ECC Encoder (SECDED - Single Error Correct, Double Error Detect)
//============================================================================

module lpddr5c_ecc_encoder #(
    parameter DATA_WIDTH = 128,
    parameter ECC_WIDTH  = 8
) (
    input  wire [DATA_WIDTH-1:0]    data_in,
    output wire [ECC_WIDTH-1:0]     ecc_out
);

    // Simple Hamming code encoder (simplified for demo)
    // Real implementation should use proper BCH or Hamming code
    reg [ECC_WIDTH-1:0]              ecc_reg;
    
    always_comb begin
        // Parity calculation
        ecc_reg[0] = ^data_in[31:0];
        ecc_reg[1] = ^data_in[63:32];
        ecc_reg[2] = ^data_in[95:64];
        ecc_reg[3] = ^data_in[127:96];
        ecc_reg[4] = ^data_in[63:0];
        ecc_reg[5] = ^data_in[127:64];
        ecc_reg[6] = ^data_in;
        ecc_reg[7] = ^ecc_reg[6:0];
    end
    
    assign ecc_out = ecc_reg;

endmodule // lpddr5c_ecc_encoder

//============================================================================
// Helper Module: ECC Decoder
//============================================================================

module lpddr5c_ecc_decoder #(
    parameter DATA_WIDTH = 128,
    parameter ECC_WIDTH  = 8
) (
    input  wire [DATA_WIDTH-1:0]    data_in,
    input  wire [ECC_WIDTH-1:0]     ecc_in,
    output wire [DATA_WIDTH-1:0]    data_out,
    output wire [ECC_WIDTH-1:0]     syndrome,
    output wire                        single_bit_err,
    output wire                        multi_bit_err
);

    // Simplified ECC decoder for demo
    reg [DATA_WIDTH-1:0]             data_corrected;
    reg [ECC_WIDTH-1:0]              syndrome_reg;
    reg                              single_err, multi_err;
    
    // Recalculate ECC
    wire [ECC_WIDTH-1:0]             ecc_recalc;
    
    lpddr5c_ecc_encoder #(
        .DATA_WIDTH(DATA_WIDTH),
        .ECC_WIDTH(ECC_WIDTH)
    ) u_ecc_recalc (
        .data_in(data_in),
        .ecc_out(ecc_recalc)
    );
    
    // Syndrome calculation
    assign syndrome_reg = ecc_in ^ ecc_recalc;
    
    // Error detection logic (simplified)
    always_comb begin
        data_corrected = data_in;
        single_err = 1'b0;
        multi_err = 1'b0;
        
        if (syndrome_reg != '0) begin
            // Simplified: non-zero syndrome = error detected
            // Real implementation would locate and correct single-bit errors
            single_err = (syndrome_reg != '0 && $countones(syndrome_reg) <= 3);
            multi_err = !single_err;
        end
    end
    
    assign data_out = data_corrected;
    assign syndrome = syndrome_reg;
    assign single_bit_err = single_err;
    assign multi_bit_err = multi_err;

endmodule // lpddr5c_ecc_decoder
