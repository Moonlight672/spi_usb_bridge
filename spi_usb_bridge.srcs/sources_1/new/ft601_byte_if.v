`timescale 1ns / 1ps
// =======================================================
// ft601_byte_if.v
// 简易 FT601 ↔ 8bit 字节流适配器
// - 只用 FT_DATA[7:0]，每个 32bit word 表示 1 个有效字节
// - RD 方向：从 FT601 读 32bit，只取 data[7:0]，丢弃其余位
// - WR 方向：向 FT601 写 32bit，data[7:0] = 要发送的字节，其余位置 0
//
// =======================================================
module ft601_byte_if (
    input  wire        clk,
    input  wire        rst_n,

    inout  wire [31:0] ft_data,
    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    output reg         ft_rd_n,
    output reg         ft_wr_n,
    output reg         ft_oe_n,

    // 输出到上层的 8bit 字节流（USB → FPGA）
    output reg         rx_valid,
    output reg  [7:0]  rx_data,
    input  wire        rx_ready,

    // 输入自上层的 8bit 字节流（FPGA → USB）
    input  wire        tx_valid,
    input  wire [7:0]  tx_data,
    output reg         tx_ready
);

    // FT_DATA 总线方向控制
    reg        ft_data_oe;        // 1: FPGA 驱动 ft_data
    reg [31:0] ft_data_out;
    wire [31:0] ft_data_in;

    assign ft_data     = ft_data_oe ? ft_data_out : 32'hZZZZ_ZZZZ;
    assign ft_data_in  = ft_data;

    // 简单状态机：读通道
    localparam R_IDLE  = 0;
    localparam R_WAIT  = 1;
    reg [1:0] rstate;

    // 写通道状态机
    localparam W_IDLE  = 0;
    localparam W_WAIT  = 1;
    reg [1:0] wstate;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ft_rd_n    <= 1'b1;
            ft_wr_n    <= 1'b1;
            ft_oe_n    <= 1'b1;
            ft_data_oe <= 1'b0;
            ft_data_out<= 32'h0;

            rx_valid   <= 1'b0;
            rx_data    <= 8'h00;
            tx_ready   <= 1'b0;

            rstate     <= R_IDLE;
            wstate     <= W_IDLE;
        end else begin
            // 默认保持 OE 使能读取
            ft_oe_n <= 1'b0;

            // -------- RX 通道：FT601 -> FPGA 字节流 --------
            case (rstate)
                R_IDLE: begin
                    rx_valid <= 1'b0;
                    if (!ft_rxf_n && rx_ready && !ft_data_oe) begin
                        // 有数据可读，发出一个 RD 脉冲
                        ft_rd_n <= 1'b0;
                        rstate  <= R_WAIT;
                    end else begin
                        ft_rd_n <= 1'b1;
                    end
                end
                R_WAIT: begin
                    // 下一拍采样数据
                    ft_rd_n <= 1'b1;
                    // 只取最低 8bit
                    rx_data  <= ft_data_in[7:0];
                    rx_valid <= 1'b1;
                    rstate   <= R_IDLE;
                end
            endcase

            // -------- TX 通道：FPGA -> FT601 字节流 --------
            case (wstate)
                W_IDLE: begin
                    tx_ready <= 1'b0;
                    ft_wr_n  <= 1'b1;
                    if (!ft_txe_n && tx_valid) begin
                        // FT601 有空间且上层有数据
                        ft_data_oe  <= 1'b1;
                        ft_data_out <= {24'h0, tx_data};
                        ft_wr_n     <= 1'b0;
                        tx_ready    <= 1'b1;  // 表示这拍已经消费了一个字节
                        wstate      <= W_WAIT;
                    end
                end
                W_WAIT: begin
                    // 拉高 WR 完成交握
                    ft_wr_n   <= 1'b1;
                    ft_data_oe<= 1'b0;
                    wstate    <= W_IDLE;
                end
            endcase
        end
    end

endmodule
