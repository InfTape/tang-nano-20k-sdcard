`timescale 1ns/1ps
`default_nettype none

// Continuous SD clock generator. rise/fall are combinational event strobes
// sampled by logic on the same system-clock edge that changes sd_clk.
module sd_native_clock (
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] half_period,
    output reg         sd_clk,
    output wire        rise,
    output wire        fall
);
    reg [15:0] count;
    wire [15:0] selected =
        (half_period == 16'd0) ? 16'd1 : half_period;
    wire toggle = (count >= selected - 16'd1);

    assign rise = toggle && !sd_clk;
    assign fall = toggle &&  sd_clk;

    always @(posedge clk) begin
        if (rst) begin
            count  <= 16'd0;
            sd_clk <= 1'b0;
        end else if (toggle) begin
            count  <= 16'd0;
            sd_clk <= ~sd_clk;
        end else begin
            count <= count + 16'd1;
        end
    end
endmodule

`default_nettype wire
