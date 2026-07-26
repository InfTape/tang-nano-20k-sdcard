`timescale 1ns/1ps
`default_nettype none

// Tang Nano 20K USB card-reader FPGA endpoint. No card sector is read or
// written at power-up; operations are accepted only over the BL616 link.
module top (
    input  wire       clk,
    input  wire       reset_btn,
    output wire [5:0] led,
    output wire       uart_tx,

    input  wire       spi_csn,
    input  wire       spi_sclk,
    input  wire       spi_mosi,
    output wire       spi_miso,

    output wire       sd_clk,
    inout  wire       sd_cmd,
    inout  wire       sd_dat0,
    inout  wire       sd_dat1,
    inout  wire       sd_dat2,
    inout  wire       sd_dat3
);
    wire system_clk;
    wire pll_lock;
    pll_48m pll_i (
        .clkin(clk),
        .clkout(system_clk),
        .lock(pll_lock)
    );

    reg [15:0] power_on_reset = 16'd0;
    always @(posedge system_clk) begin
        if (!pll_lock || reset_btn)
            power_on_reset <= 16'd0;
        else if (!(&power_on_reset))
            power_on_reset <= power_on_reset + 16'd1;
    end
    wire rst = reset_btn || !pll_lock || !(&power_on_reset);

    wire sd_cmd_in = sd_cmd;
    wire sd_cmd_out;
    wire sd_cmd_oe;
    assign sd_cmd = sd_cmd_oe ? sd_cmd_out : 1'bz;

    wire [3:0] sd_dat_in = {sd_dat3, sd_dat2, sd_dat1, sd_dat0};
    wire [3:0] sd_dat_out;
    wire sd_dat_oe;
    assign sd_dat0 = sd_dat_oe ? sd_dat_out[0] : 1'bz;
    assign sd_dat1 = sd_dat_oe ? sd_dat_out[1] : 1'bz;
    assign sd_dat2 = sd_dat_oe ? sd_dat_out[2] : 1'bz;
    assign sd_dat3 = sd_dat_oe ? sd_dat_out[3] : 1'bz;

    wire card_ready;
    wire card_sdhc;
    wire card_busy;
    wire card_read_ready;
    wire [31:0] capacity_blocks;
    wire card_error;
    wire [7:0] card_error_code;

    wire read_request;
    wire write_request;
    wire [31:0] request_lba;
    wire [3:0] request_block_count;
    wire [11:0] buffer_addr;
    wire [7:0] buffer_rdata;
    wire [11:0] write_buffer_addr;
    wire [7:0] write_buffer_data;
    wire debug_cs_seen;
    wire debug_sclk_seen;
    wire debug_request_seen;
    wire debug_response_seen;

    sd_native_block_device card_i (
        .clk(system_clk), .rst(rst),
        .sd_clk(sd_clk),
        .sd_cmd_in(sd_cmd_in), .sd_cmd_out(sd_cmd_out),
        .sd_cmd_oe(sd_cmd_oe),
        .sd_dat_in(sd_dat_in), .sd_dat_out(sd_dat_out),
        .sd_dat_oe(sd_dat_oe),
        .read_request(read_request), .write_request(write_request),
        .request_lba(request_lba),
        .request_block_count(request_block_count),
        .host_buffer_addr(buffer_addr),
        .host_buffer_rdata(buffer_rdata),
        .write_buffer_addr(write_buffer_addr),
        .write_buffer_data(write_buffer_data),
        .card_ready(card_ready), .card_sdhc(card_sdhc),
        .operation_busy(card_busy), .read_ready(card_read_ready),
        .capacity_blocks(capacity_blocks),
        .error(card_error), .error_code(card_error_code)
    );

    fpga_spi_block_bridge bridge_i (
        .clk(system_clk), .rst(rst),
        .spi_csn(spi_csn), .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .card_ready(card_ready), .card_sdhc(card_sdhc),
        .card_busy(card_busy), .card_read_ready(card_read_ready),
        .capacity_blocks(capacity_blocks),
        .card_error(card_error), .card_error_code(card_error_code),
        .read_request(read_request), .write_request(write_request),
        .request_lba(request_lba),
        .request_block_count(request_block_count),
        .buffer_addr(buffer_addr), .buffer_rdata(buffer_rdata),
        .write_buffer_addr(write_buffer_addr),
        .write_buffer_data(write_buffer_data),
        .debug_cs_seen(debug_cs_seen),
        .debug_sclk_seen(debug_sclk_seen),
        .debug_request_seen(debug_request_seen),
        .debug_response_seen(debug_response_seen)
    );

    // The board trace is unused by the current mutually exclusive MSC/JTAG
    // firmware. Keep it idle-high to avoid noise on the BL616 input.
    assign uart_tx = 1'b1;

    wire [5:0] led_on;
    assign led_on[0] = pll_lock && !rst;
    assign led_on[1] = card_ready && card_sdhc;
    assign led_on[2] = debug_cs_seen;
    assign led_on[3] = debug_sclk_seen;
    assign led_on[4] = debug_request_seen;
    assign led_on[5] = debug_response_seen || card_error;
    assign led = ~led_on;
endmodule

`default_nettype wire
