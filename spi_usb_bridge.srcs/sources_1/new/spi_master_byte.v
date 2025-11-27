`timescale 1ns / 1ps
// =======================================================
// spi_master_byte.v
// 单线 SPI，Mode0，按字节发送/接收
// CLK_DIV: 每 half SCK 所需 clk 周期数
// =======================================================
module spi_master_byte #(
    parameter integer CLK_DIV = 4
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start,
    input  wire [7:0] tx_data,
    output reg  [7:0] rx_data,
    output reg        busy,
    output reg        done,

    output reg        spi_sck,
    output reg        spi_mosi,
    input  wire       spi_miso
);

    localparam IDLE  = 0;
    localparam TRANS = 1;
    localparam DONE  = 2;

    reg [1:0] state;
    reg [7:0] shreg;
    reg [2:0] bit_cnt;
    reg [15:0] clk_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            spi_sck <= 1'b0;   // Mode0: 空闲时 SCK=0
            spi_mosi<= 1'b0;
            shreg   <= 8'h00;
            bit_cnt <= 3'd0;
            clk_cnt <= 16'd0;
            rx_data <= 8'h00;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    busy    <= 1'b0;
                    spi_sck <= 1'b0;
                    if (start) begin
                        busy    <= 1'b1;
                        shreg   <= tx_data;
                        bit_cnt <= 3'd7;
                        clk_cnt <= 16'd0;
                        spi_mosi<= tx_data[7];   // 先送 MSB
                        state   <= TRANS;
                    end
                end

                TRANS: begin
                    busy <= 1'b1;
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == CLK_DIV-1) begin
                        clk_cnt <= 0;
                        spi_sck <= ~spi_sck;

                        if (spi_sck == 1'b0) begin
                            // 上升沿：采样 MISO
                            shreg[bit_cnt] <= spi_miso;

                            if (bit_cnt == 0) begin
                                // 最后一个 bit
                                rx_data <= {shreg[7:1], spi_miso};
                                state   <= DONE;
                            end else begin
                                bit_cnt <= bit_cnt - 1;
                            end
                        end else begin
                            // 下降沿：更新 MOSI （Mode0）
                            spi_mosi <= shreg[bit_cnt];
                        end
                    end
                end

                DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    spi_sck <= 1'b0;
                    state <= IDLE;
                end

            endcase
        end
    end

endmodule
