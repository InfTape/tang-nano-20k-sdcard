`timescale 1ns/1ps
`default_nettype none

// Sends one 512-byte native-SD data block over four DAT lanes. Production
// writes use external_data; the deterministic seed pattern remains available
// for the self-checking transmitter testbench.
// After the block, this module checks the card's CRC status and waits for DAT0
// to return high after programming busy.
module sd_native_data_tx (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] block_seed,
    input  wire        use_external_data,
    input  wire [7:0]  external_data,
    input  wire        sd_rise,
    input  wire        sd_fall,
    input  wire [3:0]  sd_dat_in,

    output reg  [3:0]  sd_dat_out,
    output reg         sd_dat_oe,
    output reg         busy,
    output reg         done,
    output reg         accepted,
    output reg         response_error,
    output wire [8:0]  data_index
);
    localparam [3:0]
        S_IDLE      = 4'd0,
        S_GAP       = 4'd1,
        S_DATA      = 4'd2,
        S_CRC       = 4'd3,
        S_END       = 4'd4,
        S_RELEASE   = 4'd5,
        S_WAIT_RESP = 4'd6,
        S_STATUS    = 4'd7,
        S_RESP_END  = 4'd8,
        S_WAIT_BUSY = 4'd9;

    reg [3:0]  state;
    reg [3:0]  gap_count;
    reg [10:0] nibble_count;
    reg [4:0]  crc_count;
    reg [2:0]  status_bits;
    reg [1:0]  status_count;
    reg [23:0] timeout_count;
    reg [3:0]  ready_count;
    reg        busy_seen;
    reg [31:0] seed;

    reg [15:0] crc0;
    reg [15:0] crc1;
    reg [15:0] crc2;
    reg [15:0] crc3;

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

    function [7:0] pattern_byte;
        input [31:0] value_seed;
        input [8:0]  byte_index;
        begin
            pattern_byte = value_seed[7:0] ^ value_seed[15:8] ^
                           byte_index[7:0] ^ {7'd0, byte_index[8]} ^
                           8'ha5;
        end
    endfunction

    wire [8:0] byte_index = nibble_count[9:1];
    assign data_index = byte_index;
    wire [7:0] current_byte =
        use_external_data ? external_data : pattern_byte(seed, byte_index);
    wire [3:0] current_nibble =
        nibble_count[0] ? current_byte[3:0] : current_byte[7:4];

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state          <= S_IDLE;
            gap_count      <= 4'd0;
            nibble_count   <= 11'd0;
            crc_count      <= 5'd0;
            status_bits    <= 3'd0;
            status_count   <= 2'd0;
            timeout_count  <= 24'd0;
            ready_count    <= 4'd0;
            busy_seen      <= 1'b0;
            seed           <= 32'd0;
            crc0           <= 16'd0;
            crc1           <= 16'd0;
            crc2           <= 16'd0;
            crc3           <= 16'd0;
            sd_dat_out     <= 4'hf;
            sd_dat_oe      <= 1'b0;
            busy           <= 1'b0;
            done           <= 1'b0;
            accepted       <= 1'b0;
            response_error <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    sd_dat_out <= 4'hf;
                    sd_dat_oe  <= 1'b0;
                    busy       <= 1'b0;
                    if (start) begin
                        seed           <= block_seed;
                        gap_count      <= 4'd0;
                        accepted       <= 1'b0;
                        response_error <= 1'b0;
                        busy           <= 1'b1;
                        state          <= S_GAP;
                    end
                end

                S_GAP: begin
                    if (sd_fall) begin
                        if (gap_count == 4'd7) begin
                            sd_dat_oe    <= 1'b1;
                            sd_dat_out   <= 4'h0;
                            nibble_count <= 11'd0;
                            crc0         <= 16'd0;
                            crc1         <= 16'd0;
                            crc2         <= 16'd0;
                            crc3         <= 16'd0;
                            state        <= S_DATA;
                        end else begin
                            gap_count <= gap_count + 4'd1;
                        end
                    end
                end

                S_DATA: begin
                    if (sd_fall) begin
                        sd_dat_out <= current_nibble;
                        crc0 <= crc16_next(crc0, current_nibble[0]);
                        crc1 <= crc16_next(crc1, current_nibble[1]);
                        crc2 <= crc16_next(crc2, current_nibble[2]);
                        crc3 <= crc16_next(crc3, current_nibble[3]);
                        if (nibble_count == 11'd1023) begin
                            crc_count <= 5'd0;
                            state <= S_CRC;
                        end else begin
                            nibble_count <= nibble_count + 11'd1;
                        end
                    end
                end

                S_CRC: begin
                    if (sd_fall) begin
                        sd_dat_out <= {
                            crc3[15-crc_count],
                            crc2[15-crc_count],
                            crc1[15-crc_count],
                            crc0[15-crc_count]
                        };
                        if (crc_count == 5'd15)
                            state <= S_END;
                        else
                            crc_count <= crc_count + 5'd1;
                    end
                end

                S_END: begin
                    if (sd_fall) begin
                        sd_dat_out <= 4'hf;
                        state <= S_RELEASE;
                    end
                end

                S_RELEASE: begin
                    if (sd_fall) begin
                        sd_dat_oe     <= 1'b0;
                        timeout_count <= 24'd0;
                        state         <= S_WAIT_RESP;
                    end
                end

                S_WAIT_RESP: begin
                    if (sd_rise) begin
                        if (!sd_dat_in[0]) begin
                            status_bits  <= 3'd0;
                            status_count <= 2'd0;
                            state        <= S_STATUS;
                        end else if (timeout_count == 24'hff_ffff) begin
                            response_error <= 1'b1;
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            timeout_count <= timeout_count + 24'd1;
                        end
                    end
                end

                S_STATUS: begin
                    if (sd_rise) begin
                        status_bits <= {status_bits[1:0], sd_dat_in[0]};
                        if (status_count == 2'd2)
                            state <= S_RESP_END;
                        else
                            status_count <= status_count + 2'd1;
                    end
                end

                S_RESP_END: begin
                    if (sd_rise) begin
                        accepted       <= sd_dat_in[0] &&
                                          (status_bits == 3'b010);
                        response_error <= !sd_dat_in[0] ||
                                          (status_bits != 3'b010);
                        timeout_count <= 24'd0;
                        ready_count   <= 4'd0;
                        busy_seen     <= 1'b0;
                        state         <= S_WAIT_BUSY;
                    end
                end

                S_WAIT_BUSY: begin
                    if (sd_rise) begin
                        if (!sd_dat_in[0]) begin
                            busy_seen   <= 1'b1;
                            ready_count <= 4'd0;
                        end else if (busy_seen || (ready_count == 4'd7)) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            ready_count <= ready_count + 4'd1;
                        end

                        if (timeout_count == 24'hff_ffff) begin
                            response_error <= 1'b1;
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            timeout_count <= timeout_count + 24'd1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
