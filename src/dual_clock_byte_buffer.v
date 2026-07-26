`timescale 1ns/1ps
`default_nettype none

/*
 * Symmetric true-dual-port byte buffer.
 *
 * The extra high address bit selects one of two banks. Buffer ownership must
 * prevent both ports from writing the same location at the same time.
 * Registered reads are intentional so Gowin can map the array to BSRAM.
 */
module dual_clock_byte_buffer #(
    parameter integer BANK_ADDR_WIDTH = 14
) (
    input  wire                       port_a_clk,
    input  wire [BANK_ADDR_WIDTH:0]   port_a_addr,
    input  wire                       port_a_we,
    input  wire [7:0]                 port_a_wdata,
    output reg  [7:0]                 port_a_rdata,

    input  wire                       port_b_clk,
    input  wire [BANK_ADDR_WIDTH:0]   port_b_addr,
    input  wire                       port_b_we,
    input  wire [7:0]                 port_b_wdata,
    output reg  [7:0]                 port_b_rdata
);
    reg [7:0] memory [0:(1 << (BANK_ADDR_WIDTH + 1)) - 1];

    always @(posedge port_a_clk) begin
        if (port_a_we)
            memory[port_a_addr] <= port_a_wdata;
        port_a_rdata <= memory[port_a_addr];
    end

    always @(posedge port_b_clk) begin
        if (port_b_we)
            memory[port_b_addr] <= port_b_wdata;
        port_b_rdata <= memory[port_b_addr];
    end
endmodule

`default_nettype wire
