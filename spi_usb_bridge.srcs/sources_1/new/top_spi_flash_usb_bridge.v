`timescale 1ns / 1ps
// =======================================================
// top_spi_flash_usb_bridge.v
// - 使用 FT601 同步 FIFO 模式，只真正用到 FT_DATA[7:0]
// - FT601 时钟 ft_clk 作为系统时钟
//   byte0..3 : MAGIC = 0xDEAD_BEAF (big-endian)
//   byte4    : [7:4] spi_tx_size, [3:2] line_mode, [1:0] spi_mode
//   byte5..8 : TX_LEN (32bit, big-endian)，总 spi_txrx 字节数
//   byte9    : bit0 READ_BACK (其余保留)
//   byte10.. : payload[0..TX_LEN-1]
//
// 只实现单线 SPI，line_mode 暂未生效。
// =======================================================
module top_spi_flash_usb_bridge (
    input  wire        ft_clk,      // FT601 时钟
    input  wire        ft_reset_n,  // 低有效复位

    inout  wire [31:0] ft_data,
    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    output wire        ft_rd_n,
    output wire        ft_wr_n,
    output wire        ft_oe_n,

    // SPI Flash 端口
    output wire        spi_cs_n,
    output wire        spi_sck,
    output wire        spi_mosi,
    input  wire        spi_miso
);

    // ------------------------------
    // FT601 ↔ 字节流 适配
    // ------------------------------
    wire       usb_rx_valid;
    wire [7:0] usb_rx_data;
    wire       usb_rx_ready;

    wire       usb_tx_valid;
    wire [7:0] usb_tx_data;
    wire       usb_tx_ready;

    ft601_byte_if u_ft601_byte_if (
        .clk        (ft_clk),
        .rst_n      (ft_reset_n),

        // FT601物理接口
        .ft_data    (ft_data),
        .ft_rxf_n   (ft_rxf_n),
        .ft_txe_n   (ft_txe_n),
        .ft_rd_n    (ft_rd_n),
        .ft_wr_n    (ft_wr_n),
        .ft_oe_n    (ft_oe_n),

        // 向 SPI 桥核心提供 8bit 输入流
        .rx_valid   (usb_rx_valid),
        .rx_data    (usb_rx_data),
        .rx_ready   (usb_rx_ready),

        // 从 SPI 桥核心接收 8bit 输出流
        .tx_valid   (usb_tx_valid),
        .tx_data    (usb_tx_data),
        .tx_ready   (usb_tx_ready)
    );

    // ------------------------------
    // SPI Flash 桥接核心
    // ------------------------------
    spi_flash_bridge_core #(
        .MAGIC (32'hDEAD_BEAF)
    ) u_spi_flash_bridge_core (
        .clk        (ft_clk),
        .rst_n      (ft_reset_n),

        .in_valid   (usb_rx_valid),
        .in_data    (usb_rx_data),
        .in_ready   (usb_rx_ready),

        .out_valid  (usb_tx_valid),
        .out_data   (usb_tx_data),
        .out_ready  (usb_tx_ready),

        .spi_cs_n   (spi_cs_n),
        .spi_sck    (spi_sck),
        .spi_mosi   (spi_mosi),
        .spi_miso   (spi_miso)
    );

endmodule
