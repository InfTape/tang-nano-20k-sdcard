`timescale 1ns/1ps
`default_nettype none

// Native 4-bit SD block device. Initialization is automatic, but media data
// is touched only after an explicit read_request or write_request.
module sd_native_block_device (
    input  wire        clk,
    input  wire        rst,

    output wire        sd_clk,
    input  wire        sd_cmd_in,
    output wire        sd_cmd_out,
    output wire        sd_cmd_oe,
    input  wire [3:0]  sd_dat_in,
    output wire [3:0]  sd_dat_out,
    output wire        sd_dat_oe,

    input  wire        read_request,
    input  wire        write_request,
    input  wire [31:0] request_lba,
    input  wire [3:0]  request_block_count,

    input  wire [8:0]  host_buffer_addr,
    output wire [7:0]  host_buffer_rdata,
    output wire [11:0] write_buffer_addr,
    input  wire [7:0]  write_buffer_data,

    output reg         card_ready,
    output reg         card_sdhc,
    output reg         operation_busy,
    output reg         read_ready,
    output reg  [31:0] capacity_blocks,
    output reg         error,
    output reg  [7:0]  error_code
);
    localparam [15:0] INIT_HALF_PERIOD = 16'd64;
    localparam [15:0] DATA_HALF_PERIOD = 16'd1;

    localparam [7:0]
        E_CMD8 = 8'h01, E_ACMD41 = 8'h02, E_CMD2 = 8'h03,
        E_CMD3 = 8'h04, E_CMD7 = 8'h05, E_CMD16 = 8'h06,
        E_ACMD6 = 8'h07, E_CMD9 = 8'h0b, E_CSD = 8'h0c,
        E_CMD17 = 8'h12, E_READ_DATA = 8'h13,
        E_CMD24 = 8'h14, E_WRITE_DATA = 8'h15,
        E_RANGE = 8'h16, E_TIMEOUT = 8'h17,
        E_ACMD23 = 8'h18, E_CMD25 = 8'h19, E_CMD12 = 8'h1a;

    localparam [5:0]
        S_POWER = 6'd0, S_CMD0_START = 6'd1, S_CMD0_WAIT = 6'd2,
        S_CMD8_START = 6'd3, S_CMD8_WAIT = 6'd4,
        S_CMD55_START = 6'd5, S_CMD55_WAIT = 6'd6,
        S_ACMD41_START = 6'd7, S_ACMD41_WAIT = 6'd8,
        S_CMD2_START = 6'd9, S_CMD2_WAIT = 6'd10,
        S_CMD3_START = 6'd11, S_CMD3_WAIT = 6'd12,
        S_CMD9_START = 6'd13, S_CMD9_WAIT = 6'd14,
        S_CMD7_START = 6'd15, S_CMD7_WAIT = 6'd16,
        S_SELECT_BUSY = 6'd17,
        S_CMD16_START = 6'd18, S_CMD16_WAIT = 6'd19,
        S_BUS55_START = 6'd20, S_BUS55_WAIT = 6'd21,
        S_ACMD6_START = 6'd22, S_ACMD6_WAIT = 6'd23,
        S_FAST_SETTLE = 6'd24, S_IDLE = 6'd25,
        S_READ_CMD_START = 6'd26, S_READ_CMD_WAIT = 6'd27,
        S_READ_DATA = 6'd28,
        S_WRITE_CMD_START = 6'd29, S_WRITE_CMD_WAIT = 6'd30,
        S_WRITE_DATA_START = 6'd31, S_WRITE_DATA_WAIT = 6'd32,
        S_FAILED = 6'd33,
        S_WRITE55_START = 6'd34, S_WRITE55_WAIT = 6'd35,
        S_ACMD23_START = 6'd36, S_ACMD23_WAIT = 6'd37,
        S_WRITE_STOP_START = 6'd38, S_WRITE_STOP_WAIT = 6'd39,
        S_WRITE_STOP_BUSY = 6'd40;

    reg [5:0] state;
    reg fast_clock;
    wire sd_rise;
    wire sd_fall;

    sd_native_clock clock_i (
        .clk(clk), .rst(rst),
        .half_period(fast_clock ? DATA_HALF_PERIOD : INIT_HALF_PERIOD),
        .sd_clk(sd_clk), .rise(sd_rise), .fall(sd_fall)
    );

    reg command_start;
    reg [5:0] command_index;
    reg [31:0] command_argument;
    reg [1:0] command_response_kind;
    wire command_busy;
    wire command_done;
    wire command_timeout;
    wire response_crc_ok;
    wire [5:0] response_command;
    wire [31:0] response_argument;
    wire [127:0] response_long;

    sd_native_command command_i (
        .clk(clk), .rst(rst), .sd_rise(sd_rise), .sd_fall(sd_fall),
        .cmd_in(sd_cmd_in), .cmd_out(sd_cmd_out), .cmd_oe(sd_cmd_oe),
        .start(command_start), .command(command_index),
        .argument(command_argument), .response_kind(command_response_kind),
        .busy(command_busy), .done(command_done), .timeout(command_timeout),
        .crc_ok(response_crc_ok), .response_command(response_command),
        .response_argument(response_argument), .response_long(response_long)
    );

    reg data_rx_enable;
    wire block_start;
    wire block_done;
    wire block_crc_error;
    wire [7:0] data_byte;
    wire data_valid;

    sd_native_data_rx data_rx_i (
        .clk(clk), .rst(rst), .enable(data_rx_enable),
        .sd_rise(sd_rise), .sd_dat(sd_dat_in),
        .block_start(block_start), .block_done(block_done),
        .block_crc_error(block_crc_error),
        .data_byte(data_byte), .data_valid(data_valid)
    );

    reg data_tx_start;
    wire data_tx_busy;
    wire data_tx_done;
    wire data_tx_accepted;
    wire data_tx_response_error;
    wire [8:0] tx_data_index;
    wire [7:0] tx_buffer_data = write_buffer_data;

    sd_native_data_tx data_tx_i (
        .clk(clk), .rst(rst), .start(data_tx_start),
        .block_seed(32'd0), .use_external_data(1'b1),
        .external_data(tx_buffer_data),
        .sd_rise(sd_rise), .sd_fall(sd_fall),
        .sd_dat_in(sd_dat_in), .sd_dat_out(sd_dat_out),
        .sd_dat_oe(sd_dat_oe), .busy(data_tx_busy),
        .done(data_tx_done), .accepted(data_tx_accepted),
        .response_error(data_tx_response_error),
        .data_index(tx_data_index)
    );

    reg [7:0] block_buffer [0:511];
    reg [8:0] rx_buffer_addr;
    assign host_buffer_rdata = block_buffer[host_buffer_addr];
    reg [3:0] active_block_count;
    reg [3:0] active_block_index;
    assign write_buffer_addr = {active_block_index[2:0], tx_data_index};

    always @(posedge clk) begin
        if (rst) begin
            rx_buffer_addr <= 9'd0;
        end else begin
            if (read_request && card_ready && !operation_busy)
                rx_buffer_addr <= 9'd0;
            else if (data_valid && data_rx_enable)
                rx_buffer_addr <= rx_buffer_addr + 9'd1;
            if (data_valid && data_rx_enable)
                block_buffer[rx_buffer_addr] <= data_byte;
        end
    end

    reg [7:0] power_clock_count;
    reg [15:0] init_retry_count;
    reg [15:0] rca;
    reg [7:0] settle_clock_count;
    reg [31:0] operation_timeout;
    reg [31:0] active_lba;

    wire [31:0] csd_capacity_blocks =
        ({10'd0, response_long[69:48]} + 32'd1) << 10;

    function [31:0] card_address;
        input [31:0] lba;
        begin
            card_address = card_sdhc ? lba : (lba << 9);
        end
    endfunction

    task fail;
        input [7:0] code;
        begin
            error          <= 1'b1;
            error_code     <= code;
            operation_busy <= 1'b0;
            read_ready     <= 1'b0;
            data_rx_enable <= 1'b0;
            state          <= S_FAILED;
        end
    endtask

    always @(posedge clk) begin
        command_start <= 1'b0;
        data_tx_start <= 1'b0;

        if (rst) begin
            state <= S_POWER;
            fast_clock <= 1'b0;
            command_start <= 1'b0;
            command_index <= 6'd0;
            command_argument <= 32'd0;
            command_response_kind <= 2'd0;
            data_rx_enable <= 1'b0;
            data_tx_start <= 1'b0;
            card_ready <= 1'b0;
            card_sdhc <= 1'b0;
            operation_busy <= 1'b0;
            read_ready <= 1'b0;
            capacity_blocks <= 32'd0;
            error <= 1'b0;
            error_code <= 8'd0;
            power_clock_count <= 8'd0;
            init_retry_count <= 16'd0;
            rca <= 16'd0;
            settle_clock_count <= 8'd0;
            operation_timeout <= 32'd0;
            active_lba <= 32'd0;
            active_block_count <= 4'd1;
            active_block_index <= 4'd0;
        end else begin
            case (state)
                S_POWER: if (sd_rise) begin
                    if (power_clock_count == 8'd100)
                        state <= S_CMD0_START;
                    else
                        power_clock_count <= power_clock_count + 8'd1;
                end

                S_CMD0_START: if (!command_busy) begin
                    command_index <= 6'd0;
                    command_argument <= 32'd0;
                    command_response_kind <= 2'd0;
                    command_start <= 1'b1;
                    state <= S_CMD0_WAIT;
                end
                S_CMD0_WAIT: if (command_done) state <= S_CMD8_START;

                S_CMD8_START: if (!command_busy) begin
                    command_index <= 6'd8;
                    command_argument <= 32'h0000_01aa;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_CMD8_WAIT;
                end
                S_CMD8_WAIT: if (command_done) begin
                    if (command_timeout || response_argument[11:0] != 12'h1aa)
                        fail(E_CMD8);
                    else
                        state <= S_CMD55_START;
                end

                S_CMD55_START: if (!command_busy) begin
                    command_index <= 6'd55;
                    command_argument <= 32'd0;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_CMD55_WAIT;
                end
                S_CMD55_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_ACMD41);
                    else state <= S_ACMD41_START;
                end

                S_ACMD41_START: if (!command_busy) begin
                    command_index <= 6'd41;
                    command_argument <= 32'h4010_0000;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_ACMD41_WAIT;
                end
                S_ACMD41_WAIT: if (command_done) begin
                    if (!command_timeout && response_argument[31]) begin
                        card_sdhc <= response_argument[30];
                        state <= S_CMD2_START;
                    end else if (init_retry_count == 16'hffff) begin
                        fail(E_ACMD41);
                    end else begin
                        init_retry_count <= init_retry_count + 16'd1;
                        state <= S_CMD55_START;
                    end
                end

                S_CMD2_START: if (!command_busy) begin
                    command_index <= 6'd2;
                    command_argument <= 32'd0;
                    command_response_kind <= 2'd2;
                    command_start <= 1'b1;
                    state <= S_CMD2_WAIT;
                end
                S_CMD2_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD2);
                    else state <= S_CMD3_START;
                end

                S_CMD3_START: if (!command_busy) begin
                    command_index <= 6'd3;
                    command_argument <= 32'd0;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_CMD3_WAIT;
                end
                S_CMD3_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD3);
                    else begin
                        rca <= response_argument[31:16];
                        state <= S_CMD9_START;
                    end
                end

                S_CMD9_START: if (!command_busy) begin
                    command_index <= 6'd9;
                    command_argument <= {rca, 16'd0};
                    command_response_kind <= 2'd2;
                    command_start <= 1'b1;
                    state <= S_CMD9_WAIT;
                end
                S_CMD9_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD9);
                    else if (!card_sdhc ||
                             response_long[127:126] != 2'b01 ||
                             csd_capacity_blocks == 0)
                        fail(E_CSD);
                    else begin
                        capacity_blocks <= csd_capacity_blocks;
                        state <= S_CMD7_START;
                    end
                end

                S_CMD7_START: if (!command_busy) begin
                    command_index <= 6'd7;
                    command_argument <= {rca, 16'd0};
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    operation_timeout <= 32'd0;
                    state <= S_CMD7_WAIT;
                end
                S_CMD7_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD7);
                    else state <= S_SELECT_BUSY;
                end
                S_SELECT_BUSY: begin
                    if (sd_dat_in[0])
                        state <= card_sdhc ? S_BUS55_START : S_CMD16_START;
                    else if (operation_timeout == 32'h00ff_ffff)
                        fail(E_TIMEOUT);
                    else
                        operation_timeout <= operation_timeout + 32'd1;
                end

                S_CMD16_START: if (!command_busy) begin
                    command_index <= 6'd16;
                    command_argument <= 32'd512;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_CMD16_WAIT;
                end
                S_CMD16_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD16);
                    else state <= S_BUS55_START;
                end

                S_BUS55_START: if (!command_busy) begin
                    command_index <= 6'd55;
                    command_argument <= {rca, 16'd0};
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_BUS55_WAIT;
                end
                S_BUS55_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_ACMD6);
                    else state <= S_ACMD6_START;
                end
                S_ACMD6_START: if (!command_busy) begin
                    command_index <= 6'd6;
                    command_argument <= 32'd2;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_ACMD6_WAIT;
                end
                S_ACMD6_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_ACMD6);
                    else begin
                        fast_clock <= 1'b1;
                        settle_clock_count <= 8'd0;
                        state <= S_FAST_SETTLE;
                    end
                end
                S_FAST_SETTLE: if (sd_rise) begin
                    if (settle_clock_count == 8'd15) begin
                        card_ready <= 1'b1;
                        state <= S_IDLE;
                    end else
                        settle_clock_count <= settle_clock_count + 8'd1;
                end

                S_IDLE: begin
                    operation_busy <= 1'b0;
                    data_rx_enable <= 1'b0;
                    if ((read_request || write_request) &&
                        (request_lba >= capacity_blocks ||
                         (write_request &&
                          (request_block_count == 0 ||
                           request_lba + request_block_count >
                           capacity_blocks)))) begin
                        fail(E_RANGE);
                    end else if (read_request) begin
                        active_lba <= request_lba;
                        operation_busy <= 1'b1;
                        read_ready <= 1'b0;
                        data_rx_enable <= 1'b1;
                        state <= S_READ_CMD_START;
                    end else if (write_request) begin
                        active_lba <= request_lba;
                        active_block_count <= request_block_count;
                        active_block_index <= 4'd0;
                        operation_busy <= 1'b1;
                        read_ready <= 1'b0;
                        if (request_block_count > 1)
                            state <= S_WRITE55_START;
                        else
                            state <= S_WRITE_CMD_START;
                    end
                end

                S_READ_CMD_START: if (!command_busy) begin
                    command_index <= 6'd17;
                    command_argument <= card_address(active_lba);
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    operation_timeout <= 32'd0;
                    state <= S_READ_CMD_WAIT;
                end
                S_READ_CMD_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD17);
                    else state <= S_READ_DATA;
                end
                S_READ_DATA: begin
                    if (block_done) begin
                        data_rx_enable <= 1'b0;
                        operation_busy <= 1'b0;
                        if (block_crc_error)
                            fail(E_READ_DATA);
                        else begin
                            read_ready <= 1'b1;
                            state <= S_IDLE;
                        end
                    end else if (operation_timeout == 32'h0fff_ffff) begin
                        fail(E_TIMEOUT);
                    end else begin
                        operation_timeout <= operation_timeout + 32'd1;
                    end
                end

                S_WRITE55_START: if (!command_busy) begin
                    command_index <= 6'd55;
                    command_argument <= {rca, 16'd0};
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_WRITE55_WAIT;
                end
                S_WRITE55_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_ACMD23);
                    else state <= S_ACMD23_START;
                end
                S_ACMD23_START: if (!command_busy) begin
                    command_index <= 6'd23;
                    command_argument <= {28'd0, active_block_count};
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_ACMD23_WAIT;
                end
                S_ACMD23_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_ACMD23);
                    else state <= S_WRITE_CMD_START;
                end

                S_WRITE_CMD_START: if (!command_busy) begin
                    command_index <= active_block_count > 1 ? 6'd25 : 6'd24;
                    command_argument <= card_address(active_lba);
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    state <= S_WRITE_CMD_WAIT;
                end
                S_WRITE_CMD_WAIT: if (command_done) begin
                    if (command_timeout)
                        fail(active_block_count > 1 ? E_CMD25 : E_CMD24);
                    else state <= S_WRITE_DATA_START;
                end
                S_WRITE_DATA_START: if (!data_tx_busy) begin
                    data_tx_start <= 1'b1;
                    state <= S_WRITE_DATA_WAIT;
                end
                S_WRITE_DATA_WAIT: if (data_tx_done) begin
                    if (data_tx_response_error || !data_tx_accepted)
                        fail(E_WRITE_DATA);
                    else if (active_block_index + 4'd1 <
                             active_block_count) begin
                        active_block_index <= active_block_index + 4'd1;
                        state <= S_WRITE_DATA_START;
                    end else if (active_block_count > 1) begin
                        state <= S_WRITE_STOP_START;
                    end else begin
                        operation_busy <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_WRITE_STOP_START: if (!command_busy) begin
                    command_index <= 6'd12;
                    command_argument <= 32'd0;
                    command_response_kind <= 2'd1;
                    command_start <= 1'b1;
                    operation_timeout <= 32'd0;
                    state <= S_WRITE_STOP_WAIT;
                end
                S_WRITE_STOP_WAIT: if (command_done) begin
                    if (command_timeout) fail(E_CMD12);
                    else state <= S_WRITE_STOP_BUSY;
                end
                S_WRITE_STOP_BUSY: begin
                    if (sd_dat_in[0]) begin
                        operation_busy <= 1'b0;
                        state <= S_IDLE;
                    end else if (operation_timeout == 32'h0fff_ffff) begin
                        fail(E_TIMEOUT);
                    end else begin
                        operation_timeout <= operation_timeout + 32'd1;
                    end
                end

                S_FAILED: begin
                    operation_busy <= 1'b0;
                    data_rx_enable <= 1'b0;
                end
                default: state <= S_FAILED;
            endcase
        end
    end

    wire _unused = &{1'b0, block_start, response_crc_ok,
                     response_command, active_lba[0]};
endmodule

`default_nettype wire
