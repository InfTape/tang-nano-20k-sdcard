`timescale 1ns/1ps
`default_nettype none

// Receives 512-byte native-SD data blocks in 4-bit mode and verifies all four
// lane CRC16 values. Data bytes are exposed for optional consumers.
module sd_native_data_rx (
    input  wire       clk,
    input  wire       rst,
    input  wire       enable,
    input  wire       sd_rise,
    input  wire [3:0] sd_dat,

    output reg        block_start,
    output reg        block_done,
    output reg        block_crc_error,
    output reg [7:0]  data_byte,
    output reg        data_valid
);
    localparam [2:0]
        S_WAIT  = 3'd0,
        S_DATA  = 3'd1,
        S_CRC   = 3'd2,
        S_END   = 3'd3,
        S_CHECK = 3'd4;

    reg [2:0] state;
    reg [10:0] nibble_count;
    reg [4:0] crc_count;
    reg       low_nibble_next;
    reg [3:0] high_nibble;

    reg [15:0] crc0;
    reg [15:0] crc1;
    reg [15:0] crc2;
    reg [15:0] crc3;
    reg [15:0] received_crc0;
    reg [15:0] received_crc1;
    reg [15:0] received_crc2;
    reg [15:0] received_crc3;
    reg        end_bit_error;

    function [15:0] crc16_next;
        input [15:0] crc;
        input        value;
        reg feedback;
        begin
            feedback = crc[15] ^ value;
            crc16_next = {crc[14:0], 1'b0};
            if (feedback)
                crc16_next = crc16_next ^ 16'h1021;
        end
    endfunction

    always @(posedge clk) begin
        block_start <= 1'b0;
        block_done  <= 1'b0;
        data_valid  <= 1'b0;

        if (rst || !enable) begin
            state             <= S_WAIT;
            nibble_count      <= 11'd0;
            crc_count         <= 5'd0;
            low_nibble_next   <= 1'b0;
            high_nibble       <= 4'd0;
            crc0              <= 16'd0;
            crc1              <= 16'd0;
            crc2              <= 16'd0;
            crc3              <= 16'd0;
            received_crc0     <= 16'd0;
            received_crc1     <= 16'd0;
            received_crc2     <= 16'd0;
            received_crc3     <= 16'd0;
            end_bit_error     <= 1'b0;
            block_crc_error   <= 1'b0;
            data_byte         <= 8'd0;
        end else begin
            case (state)
                S_WAIT: begin
                    if (sd_rise && (sd_dat == 4'b0000)) begin
                        block_start    <= 1'b1;
                        nibble_count   <= 11'd0;
                        low_nibble_next <= 1'b0;
                        crc0           <= 16'd0;
                        crc1           <= 16'd0;
                        crc2           <= 16'd0;
                        crc3           <= 16'd0;
                        end_bit_error  <= 1'b0;
                        state          <= S_DATA;
                    end
                end

                S_DATA: begin
                    if (sd_rise) begin
                        crc0 <= crc16_next(crc0, sd_dat[0]);
                        crc1 <= crc16_next(crc1, sd_dat[1]);
                        crc2 <= crc16_next(crc2, sd_dat[2]);
                        crc3 <= crc16_next(crc3, sd_dat[3]);

                        if (!low_nibble_next) begin
                            high_nibble     <= sd_dat;
                            low_nibble_next <= 1'b1;
                        end else begin
                            data_byte       <= {high_nibble, sd_dat};
                            data_valid      <= 1'b1;
                            low_nibble_next <= 1'b0;
                        end

                        if (nibble_count == 11'd1023) begin
                            received_crc0 <= 16'd0;
                            received_crc1 <= 16'd0;
                            received_crc2 <= 16'd0;
                            received_crc3 <= 16'd0;
                            crc_count <= 5'd0;
                            state <= S_CRC;
                        end else begin
                            nibble_count <= nibble_count + 11'd1;
                        end
                    end
                end

                S_CRC: begin
                    if (sd_rise) begin
                        received_crc0 <= {received_crc0[14:0], sd_dat[0]};
                        received_crc1 <= {received_crc1[14:0], sd_dat[1]};
                        received_crc2 <= {received_crc2[14:0], sd_dat[2]};
                        received_crc3 <= {received_crc3[14:0], sd_dat[3]};
                        if (crc_count == 5'd15)
                            state <= S_END;
                        else
                            crc_count <= crc_count + 5'd1;
                    end
                end

                S_END: begin
                    if (sd_rise) begin
                        end_bit_error <= (sd_dat != 4'b1111);
                        state <= S_CHECK;
                    end
                end

                S_CHECK: begin
                    block_crc_error <= end_bit_error ||
                        (crc0 != received_crc0) ||
                        (crc1 != received_crc1) ||
                        (crc2 != received_crc2) ||
                        (crc3 != received_crc3);
                    block_done <= 1'b1;
                    state <= S_WAIT;
                end

                default: state <= S_WAIT;
            endcase
        end
    end
endmodule

`default_nettype wire
