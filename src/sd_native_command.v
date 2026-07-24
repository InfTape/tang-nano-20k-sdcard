`timescale 1ns/1ps
`default_nettype none

// Native-SD command transmitter and response receiver.
// response_kind: 0=no response, 1=48-bit response, 2=136-bit response.
module sd_native_command (
    input  wire        clk,
    input  wire        rst,
    input  wire        sd_rise,
    input  wire        sd_fall,

    input  wire        cmd_in,
    output reg         cmd_out,
    output reg         cmd_oe,

    input  wire        start,
    input  wire [5:0]  command,
    input  wire [31:0] argument,
    input  wire [1:0]  response_kind,

    output reg         busy,
    output reg         done,
    output reg         timeout,
    output reg         crc_ok,
    output reg  [5:0]  response_command,
    output reg  [31:0] response_argument,
    output reg [127:0] response_long
);
    localparam [2:0]
        S_IDLE       = 3'd0,
        S_ARM        = 3'd1,
        S_SEND       = 3'd2,
        S_TURN       = 3'd3,
        S_WAIT_START = 3'd4,
        S_RECEIVE    = 3'd5,
        S_CHECK      = 3'd6;

    reg [2:0]   state;
    reg [47:0]  tx_frame;
    reg [6:0]   tx_position;
    reg [1:0]   expected_kind;
    reg [135:0] response_shift;
    reg [7:0]   response_count;
    reg [10:0]  wait_count;
    reg [3:0]   arm_count;

    function [6:0] crc7_40;
        input [39:0] value;
        integer i;
        reg [6:0] crc;
        reg feedback;
        begin
            crc = 7'd0;
            for (i = 39; i >= 0; i = i - 1) begin
                feedback = value[i] ^ crc[6];
                crc = {crc[5:0], 1'b0};
                if (feedback)
                    crc = crc ^ 7'h09;
            end
            crc7_40 = crc;
        end
    endfunction

    wire [39:0] request_body = {2'b01, command, argument};
    wire [47:0] request_frame =
        {request_body, crc7_40(request_body), 1'b1};

    always @(posedge clk) begin
        done <= 1'b0;

        if (rst) begin
            state             <= S_IDLE;
            tx_frame          <= 48'hffff_ffff_ffff;
            tx_position       <= 7'd0;
            expected_kind     <= 2'd0;
            response_shift    <= 136'd0;
            response_count    <= 8'd0;
            wait_count        <= 11'd0;
            arm_count         <= 4'd0;
            cmd_out           <= 1'b1;
            cmd_oe            <= 1'b0;
            busy              <= 1'b0;
            done              <= 1'b0;
            timeout           <= 1'b0;
            crc_ok            <= 1'b0;
            response_command  <= 6'd0;
            response_argument <= 32'd0;
            response_long     <= 128'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    cmd_oe  <= 1'b0;
                    cmd_out <= 1'b1;
                    busy    <= 1'b0;
                    if (start) begin
                        tx_frame      <= request_frame;
                        expected_kind <= response_kind;
                        timeout       <= 1'b0;
                        crc_ok        <= 1'b0;
                        busy          <= 1'b1;
                        arm_count     <= 4'd0;
                        state         <= S_ARM;
                    end
                end

                // Start driving only on a falling edge.
                S_ARM: begin
                    if (sd_fall) begin
                        if (arm_count == 4'd7) begin
                            cmd_oe      <= 1'b1;
                            cmd_out     <= tx_frame[47];
                            tx_position <= 7'd47;
                            state       <= S_SEND;
                        end else begin
                            arm_count <= arm_count + 4'd1;
                        end
                    end
                end

                S_SEND: begin
                    if (sd_rise) begin
                        if (tx_position == 7'd0)
                            state <= S_TURN;
                        else
                            tx_position <= tx_position - 7'd1;
                    end
                    if (sd_fall && (tx_position != 7'd47))
                        cmd_out <= tx_frame[tx_position];
                end

                S_TURN: begin
                    if (sd_fall) begin
                        cmd_oe <= 1'b0;
                        wait_count <= 11'd0;
                        if (expected_kind == 2'd0) begin
                            done  <= 1'b1;
                            busy  <= 1'b0;
                            state <= S_IDLE;
                        end else begin
                            state <= S_WAIT_START;
                        end
                    end
                end

                S_WAIT_START: begin
                    if (sd_rise) begin
                        if (!cmd_in) begin
                            response_shift <= 136'd0;
                            response_count <= 8'd1;
                            state <= S_RECEIVE;
                        end else if (wait_count == 11'd1023) begin
                            timeout <= 1'b1;
                            done    <= 1'b1;
                            busy    <= 1'b0;
                            state   <= S_IDLE;
                        end else begin
                            wait_count <= wait_count + 11'd1;
                        end
                    end
                end

                S_RECEIVE: begin
                    if (sd_rise) begin
                        response_shift <=
                            {response_shift[134:0], cmd_in};
                        if (((expected_kind == 2'd1) &&
                             (response_count == 8'd47)) ||
                            ((expected_kind == 2'd2) &&
                             (response_count == 8'd135))) begin
                            state <= S_CHECK;
                        end else begin
                            response_count <= response_count + 8'd1;
                        end
                    end
                end

                S_CHECK: begin
                    response_command  <= response_shift[45:40];
                    response_argument <= response_shift[39:8];
                    response_long     <= response_shift[127:0];
                    if (expected_kind == 2'd1)
                        crc_ok <= response_shift[0] &&
                            (response_shift[7:1] ==
                             crc7_40(response_shift[47:8]));
                    else
                        crc_ok <= response_shift[0];
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
