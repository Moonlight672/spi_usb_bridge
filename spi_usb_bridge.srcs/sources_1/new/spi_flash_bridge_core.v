`timescale 1ns / 1ps
// =======================================================
// spi_flash_bridge_core.v
// 帧格式：字节流 (USB -> FPGA)
//   byte0..3 : MAGIC = 0xDEAD_BEAF (big-endian)
//   byte4    : [7:4] spi_tx_size, [3:2] line_mode, [1:0] spi_mode
//   byte5..8 : TX_LEN (32bit, big-endian)，总共需要做多少次 spi_txrx
//   byte9    : FLAGS，bit0=READ_BACK，其他保留
//   byte10.. : payload[0..TX_LEN-1]
//
// 行为：
//   1. 搜索 magic → 收 header → 拉低 CS
//   2. 对 payload 中每个字节：
//      - 启动 spi_master_byte 做一次 spi_txrx
//      - 如 READ_BACK=1，则把 MISO 字节写到 out_* 流中
//   3. 总计做完 TX_LEN 次后，拉高 CS，回到搜索 magic 状态
//
//   - 只实现 spi_mode=00 (Mode 0)
//   - line_mode 暂未使用，所有字节都单线发送
// =======================================================
module spi_flash_bridge_core #(
    parameter MAGIC = 32'hDEAD_BEAF
)(
    input  wire       clk,
    input  wire       rst_n,

    // 输入字节流（USB → FPGA）
    input  wire       in_valid,
    input  wire [7:0] in_data,
    output reg        in_ready,

    // 输出字节流（FPGA → USB）
    output reg        out_valid,
    output reg [7:0]  out_data,
    input  wire       out_ready,

    // SPI
    output reg        spi_cs_n,
    output wire       spi_sck,
    output wire       spi_mosi,
    input  wire       spi_miso
);

    // ---------------- header 寄存器 ----------------
    reg [31:0] magic_shift;
    reg [3:0]  spi_tx_size;
    reg [1:0]  line_mode;
    reg [1:0]  spi_mode;
    reg [31:0] tx_len;
    reg        read_back;

    reg [31:0] tx_count;

    // ---------------- SPI master ----------------
    reg        spi_start;
    reg [7:0]  spi_tx_data;
    wire [7:0] spi_rx_data;
    wire       spi_busy;
    wire       spi_done;

    spi_master_byte #(
        .CLK_DIV(4)       // 根据需要调 SPI 速度
    ) u_spi_master_byte (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (spi_start),
        .tx_data  (spi_tx_data),
        .rx_data  (spi_rx_data),
        .busy     (spi_busy),
        .done     (spi_done),
        .spi_sck  (spi_sck),
        .spi_mosi (spi_mosi),
        .spi_miso (spi_miso)
    );

    // ---------------- 状态机 ----------------
    localparam S_SEARCH_MAGIC = 0;
    localparam S_HDR_CFG      = 1;
    localparam S_HDR_TL3      = 2;
    localparam S_HDR_TL2      = 3;
    localparam S_HDR_TL1      = 4;
    localparam S_HDR_TL0      = 5;
    localparam S_HDR_FLAGS    = 6;
    localparam S_PAYLOAD_WAIT = 7;
    localparam S_SPI_START    = 8;
    localparam S_SPI_WAIT     = 9;
    localparam S_SPI_OUT      = 10;
    localparam S_DONE         = 11;

    reg [3:0] state, next_state;

    // 组合：默认
    always @(*) begin
        in_ready  = 1'b0;
        out_valid = 1'b0;
        out_data  = spi_rx_data;
        spi_start = 1'b0;
        next_state = state;

        case (state)
            S_SEARCH_MAGIC: begin
                in_ready = 1'b1;
                if (in_valid) begin
                    if ({magic_shift[23:0], in_data} == MAGIC)
                        next_state = S_HDR_CFG;
                end
            end

            S_HDR_CFG,
            S_HDR_TL3,
            S_HDR_TL2,
            S_HDR_TL1,
            S_HDR_TL0,
            S_HDR_FLAGS: begin
                in_ready = 1'b1;
                if (in_valid)
                    next_state = state + 1;
            end

            S_PAYLOAD_WAIT: begin
                in_ready = (!spi_busy && (tx_count < tx_len));
                if (tx_count == tx_len) begin
                    next_state = S_DONE;
                end else if (in_valid && in_ready) begin
                    next_state = S_SPI_START;
                end
            end

            S_SPI_START: begin
                spi_start  = 1'b1;
                next_state = S_SPI_WAIT;
            end

            S_SPI_WAIT: begin
                if (spi_done) begin
                    if (read_back)
                        next_state = S_SPI_OUT;
                    else
                        next_state = S_PAYLOAD_WAIT;
                end
            end

            S_SPI_OUT: begin
                if (read_back && out_ready) begin
                    out_valid  = 1'b1;
                    out_data   = spi_rx_data;
                    next_state = S_PAYLOAD_WAIT;
                end
            end

            S_DONE: begin
                next_state = S_SEARCH_MAGIC;
            end

            default: next_state = S_SEARCH_MAGIC;
        endcase
    end

    // 时序
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_SEARCH_MAGIC;
            magic_shift <= 32'h0;
            spi_tx_size <= 4'd0;
            line_mode   <= 2'd0;
            spi_mode    <= 2'd0;
            tx_len      <= 32'd0;
            read_back   <= 1'b0;
            tx_count    <= 32'd0;
            spi_cs_n    <= 1'b1;
            spi_tx_data <= 8'h00;
        end else begin
            state <= next_state;

            case (state)
                S_SEARCH_MAGIC: begin
                    spi_cs_n <= 1'b1;     // 空闲拉高 CS
                    tx_count <= 32'd0;
                    if (in_valid && in_ready) begin
                        magic_shift <= {magic_shift[23:0], in_data};
                    end
                end

                S_HDR_CFG: begin
                    if (in_valid && in_ready) begin
                        spi_cs_n    <= 1'b0;  // 收到 CFG 时拉低 CS，准备事务
                        spi_tx_size <= in_data[7:4];
                        line_mode   <= in_data[3:2];
                        spi_mode    <= in_data[1:0]; // 当前仅支持 00
                    end
                end

                S_HDR_TL3: if (in_valid && in_ready) tx_len[31:24] <= in_data;
                S_HDR_TL2: if (in_valid && in_ready) tx_len[23:16] <= in_data;
                S_HDR_TL1: if (in_valid && in_ready) tx_len[15:8]  <= in_data;
                S_HDR_TL0: if (in_valid && in_ready) tx_len[7:0]   <= in_data;

                S_HDR_FLAGS: begin
                    if (in_valid && in_ready) begin
                        read_back <= in_data[0];
                        tx_count  <= 32'd0;
                    end
                end

                S_PAYLOAD_WAIT: begin
                    if (in_valid && in_ready && (tx_count < tx_len) && !spi_busy) begin
                        spi_tx_data <= in_data;
                    end
                end

                S_SPI_WAIT: begin
                    if (spi_done)
                        tx_count <= tx_count + 1;
                end

                S_DONE: begin
                    spi_cs_n <= 1'b1; // 拉高 CS 结束事务
                end

                default: ;
            endcase
        end
    end

endmodule
