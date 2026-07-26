`timescale 1ns/1ps
`default_nettype none

/*
 * System-clock protocol controller around the source-synchronous SPI
 * frontend. Read payloads live in two 16 KiB dual-clock banks; write payloads
 * use a separate 16 KiB dual-clock bank.
 */
module fpga_sclk_block_bridge #(
    parameter ALLOW_WRITES = 1'b1
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        spi_csn,
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    output wire        spi_miso,

    input  wire        card_ready,
    input  wire        card_sdhc,
    input  wire        card_busy,
    input  wire        card_read_ready,
    input  wire [31:0] capacity_blocks,
    input  wire        card_error,
    input  wire [7:0]  card_error_code,

    output reg         read_request,
    output reg         write_request,
    output reg  [31:0] request_lba,
    output reg  [5:0]  request_block_count,

    input  wire        read_buffer_we,
    input  wire [13:0] read_buffer_addr,
    input  wire [7:0]  read_buffer_data,
    input  wire [13:0] write_buffer_addr,
    output wire [7:0]  write_buffer_data,

    output reg         debug_cs_seen,
    output reg         debug_sclk_seen,
    output reg         debug_request_seen,
    output reg         debug_response_seen
);
    localparam [7:0]
        CMD_INFO = 8'h01,
        CMD_STATUS = 8'h02,
        CMD_READ_START = 8'h03,
        CMD_READ_DATA = 8'h04,
        CMD_WRITE_DATA = 8'h05;

    localparam [7:0]
        STATUS_OK = 8'd0,
        STATUS_BUSY = 8'd1,
        STATUS_READ_READY = 8'd2,
        STATUS_NOT_READY = 8'd3,
        STATUS_BAD_REQUEST = 8'd4,
        STATUS_IO_ERROR = 8'd5,
        STATUS_CRC_ERROR = 8'd6;

    localparam [1:0]
        CONTROL_IDLE = 2'd0,
        CONTROL_WAIT_PRODUCER = 2'd1,
        CONTROL_WAIT_CONSUMER = 2'd2;

    function [31:0] crc32_update;
        input [31:0] crc_in;
        input [7:0] value;
        integer i;
        reg [31:0] crc;
        begin
            crc = crc_in ^ value;
            for (i = 0; i < 8; i = i + 1)
                crc = (crc >> 1) ^
                      (crc[0] ? 32'hedb8_8320 : 32'd0);
            crc32_update = crc;
        end
    endfunction

    function [31:0] crc32_inline;
        input [63:0] data;
        input [3:0] length;
        integer index;
        reg [31:0] crc;
        begin
            crc = 32'hffff_ffff;
            for (index = 0; index < 8; index = index + 1)
                if (index < length)
                    crc = crc32_update(crc, data[index * 8 +: 8]);
            crc32_inline = crc ^ 32'hffff_ffff;
        end
    endfunction

    wire sys_request_valid;
    wire [7:0] sys_request_command;
    wire [31:0] sys_request_lba;
    wire [15:0] sys_request_length;
    wire sys_request_has_payload;
    wire sys_request_crc_ok;
    wire request_buffer_we_sclk;
    wire [13:0] request_buffer_addr_sclk;
    wire [7:0] request_buffer_data_sclk;

    wire sys_response_ready;
    reg sys_response_valid;
    reg [7:0] sys_response_status;
    reg [15:0] sys_response_length;
    reg [31:0] sys_response_crc;
    reg sys_response_buffer;
    reg sys_response_inline;
    reg [63:0] sys_response_inline_data;
    wire sys_response_done;
    wire [14:0] response_buffer_addr_sclk;
    wire [7:0] response_buffer_data_sclk;

    spi_sclk_mailbox mailbox_i (
        .sys_clk(clk), .sys_rst(rst),
        .spi_csn(spi_csn), .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .sys_request_valid(sys_request_valid),
        .sys_request_command(sys_request_command),
        .sys_request_lba(sys_request_lba),
        .sys_request_length(sys_request_length),
        .sys_request_has_payload(sys_request_has_payload),
        .sys_request_crc_ok(sys_request_crc_ok),
        .request_buffer_we_sclk(request_buffer_we_sclk),
        .request_buffer_addr_sclk(request_buffer_addr_sclk),
        .request_buffer_data_sclk(request_buffer_data_sclk),
        .sys_response_ready(sys_response_ready),
        .sys_response_valid(sys_response_valid),
        .sys_response_status(sys_response_status),
        .sys_response_length(sys_response_length),
        .sys_response_crc(sys_response_crc),
        .sys_response_buffer(sys_response_buffer),
        .sys_response_inline(sys_response_inline),
        .sys_response_inline_data(sys_response_inline_data),
        .sys_response_done(sys_response_done),
        .response_buffer_addr_sclk(response_buffer_addr_sclk),
        .response_buffer_data_sclk(response_buffer_data_sclk)
    );

    reg fill_bank;
    wire [14:0] read_buffer_system_addr =
        {fill_bank, read_buffer_addr};
    wire [7:0] unused_read_buffer_system_data;

    dual_clock_byte_buffer read_buffers_i (
        .port_a_clk(clk),
        .port_a_addr(read_buffer_system_addr),
        .port_a_we(read_buffer_we),
        .port_a_wdata(read_buffer_data),
        .port_a_rdata(unused_read_buffer_system_data),
        .port_b_clk(spi_sclk),
        .port_b_addr(response_buffer_addr_sclk),
        .port_b_we(1'b0),
        .port_b_wdata(8'd0),
        .port_b_rdata(response_buffer_data_sclk)
    );

    wire [7:0] unused_write_buffer_sclk_data;
    dual_clock_byte_buffer write_buffer_i (
        .port_a_clk(clk),
        .port_a_addr({1'b0, write_buffer_addr}),
        .port_a_we(1'b0),
        .port_a_wdata(8'd0),
        .port_a_rdata(write_buffer_data),
        .port_b_clk(spi_sclk),
        .port_b_addr({1'b0, request_buffer_addr_sclk}),
        .port_b_we(request_buffer_we_sclk),
        .port_b_wdata(request_buffer_data_sclk),
        .port_b_rdata(unused_write_buffer_sclk_data)
    );

    reg producer_acquire;
    wire producer_grant;
    wire producer_bank;
    reg producer_commit;
    reg producer_commit_bank;
    reg consumer_acquire;
    wire consumer_grant;
    wire consumer_bank;
    reg consumer_release;
    reg consumer_release_bank;
    wire [1:0] bank0_state;
    wire [1:0] bank1_state;

    ping_pong_owner owner_i (
        .clk(clk), .rst(rst),
        .producer_acquire(producer_acquire),
        .producer_grant(producer_grant),
        .producer_bank(producer_bank),
        .producer_commit(producer_commit),
        .producer_commit_bank(producer_commit_bank),
        .consumer_acquire(consumer_acquire),
        .consumer_grant(consumer_grant),
        .consumer_bank(consumer_bank),
        .consumer_release(consumer_release),
        .consumer_release_bank(consumer_release_bank),
        .bank0_state(bank0_state), .bank1_state(bank1_state)
    );

    reg [1:0] control_state;
    reg acquire_sent;
    reg [31:0] pending_lba;
    reg [5:0] pending_block_count;
    reg [15:0] pending_length;
    reg [31:0] last_request_lba;
    reg read_inflight;
    reg read_started;
    reg [15:0] fill_length;
    reg [31:0] fill_crc_work;
    reg [15:0] bank_length [0:1];
    reg [31:0] bank_crc [0:1];
    reg response_uses_bank;
    reg response_active_bank;

    wire any_read_ready = bank0_state == 2'd2 ||
                          bank1_state == 2'd2;
    wire any_read_free = bank0_state == 2'd0 ||
                         bank1_state == 2'd0;
    wire [31:0] fill_crc_next = read_buffer_we ?
        crc32_update(fill_crc_work, read_buffer_data) : fill_crc_work;

    task queue_empty_response;
        input [7:0] status;
        begin
            sys_response_status <= status;
            sys_response_length <= 16'd0;
            sys_response_crc <= 32'd0;
            sys_response_buffer <= 1'b0;
            sys_response_inline <= 1'b0;
            sys_response_inline_data <= 64'd0;
            sys_response_valid <= 1'b1;
            debug_response_seen <= 1'b1;
        end
    endtask

    task queue_inline_response;
        input [7:0] status;
        input [63:0] data;
        begin
            sys_response_status <= status;
            sys_response_length <= 16'd8;
            sys_response_crc <= crc32_inline(data, 4'd8);
            sys_response_buffer <= 1'b0;
            sys_response_inline <= 1'b1;
            sys_response_inline_data <= data;
            sys_response_valid <= 1'b1;
            debug_response_seen <= 1'b1;
        end
    endtask

    wire [63:0] info_payload = {
        16'd0,
        card_error_code,
        {5'd0, card_error, card_sdhc, card_ready},
        capacity_blocks
    };
    wire [63:0] status_payload = {
        16'd0,
        last_request_lba,
        card_error_code,
        {4'd0, any_read_ready, card_busy, card_error, card_ready}
    };

    wire request_length_valid =
        sys_request_length >= 16'd512 &&
        sys_request_length <= 16'd16384 &&
        sys_request_length[8:0] == 9'd0;
    wire [5:0] decoded_block_count =
        sys_request_length == 0 ? 6'd1 :
        sys_request_length[14:9];
    wire request_range_valid =
        sys_request_lba < capacity_blocks &&
        {26'd0, decoded_block_count} <=
            capacity_blocks - sys_request_lba;

    reg [2:0] cs_sync;
    reg [2:0] sclk_sync;

    always @(posedge clk) begin
        read_request <= 1'b0;
        write_request <= 1'b0;
        sys_response_valid <= 1'b0;
        producer_acquire <= 1'b0;
        producer_commit <= 1'b0;
        consumer_acquire <= 1'b0;
        consumer_release <= 1'b0;

        if (rst) begin
            request_lba <= 32'd0;
            request_block_count <= 6'd1;
            sys_response_status <= STATUS_NOT_READY;
            sys_response_length <= 16'd0;
            sys_response_crc <= 32'd0;
            sys_response_buffer <= 1'b0;
            sys_response_inline <= 1'b0;
            sys_response_inline_data <= 64'd0;
            producer_commit_bank <= 1'b0;
            consumer_release_bank <= 1'b0;
            control_state <= CONTROL_IDLE;
            acquire_sent <= 1'b0;
            pending_lba <= 32'd0;
            pending_block_count <= 6'd1;
            pending_length <= 16'd512;
            last_request_lba <= 32'd0;
            fill_bank <= 1'b0;
            read_inflight <= 1'b0;
            read_started <= 1'b0;
            fill_length <= 16'd0;
            fill_crc_work <= 32'hffff_ffff;
            bank_length[0] <= 16'd0;
            bank_length[1] <= 16'd0;
            bank_crc[0] <= 32'd0;
            bank_crc[1] <= 32'd0;
            response_uses_bank <= 1'b0;
            response_active_bank <= 1'b0;
            debug_cs_seen <= 1'b0;
            debug_sclk_seen <= 1'b0;
            debug_request_seen <= 1'b0;
            debug_response_seen <= 1'b0;
            cs_sync <= 3'b111;
            sclk_sync <= 3'b000;
        end else begin
            cs_sync <= {cs_sync[1:0], spi_csn};
            sclk_sync <= {sclk_sync[1:0], spi_sclk};
            if (!cs_sync[2])
                debug_cs_seen <= 1'b1;
            if (sclk_sync[2:1] == 2'b01 ||
                sclk_sync[2:1] == 2'b10)
                debug_sclk_seen <= 1'b1;

            if (read_inflight && !card_read_ready)
                read_started <= 1'b1;

            if (read_inflight && read_buffer_we)
                fill_crc_work <= fill_crc_next;

            if (read_inflight && read_started && card_read_ready) begin
                read_inflight <= 1'b0;
                read_started <= 1'b0;
                bank_length[fill_bank] <= fill_length;
                bank_crc[fill_bank] <=
                    fill_crc_next ^ 32'hffff_ffff;
                producer_commit_bank <= fill_bank;
                producer_commit <= 1'b1;
            end

            if (sys_response_done && response_uses_bank) begin
                consumer_release_bank <= response_active_bank;
                consumer_release <= 1'b1;
                response_uses_bank <= 1'b0;
            end

            case (control_state)
                CONTROL_IDLE: if (sys_request_valid &&
                                  sys_response_ready) begin
                    debug_request_seen <= 1'b1;
                    last_request_lba <= sys_request_lba;
                    if (!sys_request_crc_ok) begin
                        queue_empty_response(STATUS_CRC_ERROR);
                    end else case (sys_request_command)
                        CMD_INFO: begin
                            if (card_error)
                                queue_empty_response(STATUS_IO_ERROR);
                            else if (!card_ready)
                                queue_empty_response(STATUS_NOT_READY);
                            else
                                queue_inline_response(STATUS_OK,
                                                      info_payload);
                        end

                        CMD_STATUS: begin
                            if (card_error)
                                queue_inline_response(STATUS_IO_ERROR,
                                                      status_payload);
                            else if (!card_ready)
                                queue_inline_response(STATUS_NOT_READY,
                                                      status_payload);
                            else if (card_busy || read_inflight)
                                queue_inline_response(STATUS_BUSY,
                                                      status_payload);
                            else if (any_read_ready)
                                queue_inline_response(STATUS_READ_READY,
                                                      status_payload);
                            else
                                queue_inline_response(STATUS_OK,
                                                      status_payload);
                        end

                        CMD_READ_START: begin
                            if (sys_request_has_payload ||
                                (sys_request_length != 0 &&
                                 !request_length_valid) ||
                                !request_range_valid) begin
                                queue_empty_response(STATUS_BAD_REQUEST);
                            end else if (!card_ready) begin
                                queue_empty_response(STATUS_NOT_READY);
                            end else if (card_error) begin
                                queue_empty_response(STATUS_IO_ERROR);
                            end else if (card_busy || read_inflight ||
                                         !any_read_free) begin
                                queue_empty_response(STATUS_BUSY);
                            end else begin
                                pending_lba <= sys_request_lba;
                                pending_block_count <=
                                    decoded_block_count;
                                pending_length <=
                                    sys_request_length == 0 ?
                                        16'd512 :
                                        sys_request_length;
                                acquire_sent <= 1'b0;
                                control_state <=
                                    CONTROL_WAIT_PRODUCER;
                            end
                        end

                        CMD_READ_DATA: begin
                            if (sys_request_has_payload ||
                                sys_request_length != 0) begin
                                queue_empty_response(STATUS_BAD_REQUEST);
                            end else if (card_error) begin
                                queue_empty_response(STATUS_IO_ERROR);
                            end else if (!any_read_ready) begin
                                if (card_busy || read_inflight)
                                    queue_empty_response(STATUS_BUSY);
                                else
                                    queue_empty_response(STATUS_NOT_READY);
                            end else begin
                                acquire_sent <= 1'b0;
                                control_state <=
                                    CONTROL_WAIT_CONSUMER;
                            end
                        end

                        CMD_WRITE_DATA: begin
                            if (!ALLOW_WRITES) begin
                                queue_empty_response(STATUS_IO_ERROR);
                            end else if (!sys_request_has_payload ||
                                !request_length_valid ||
                                !request_range_valid) begin
                                queue_empty_response(STATUS_BAD_REQUEST);
                            end else if (!card_ready) begin
                                queue_empty_response(STATUS_NOT_READY);
                            end else if (card_error) begin
                                queue_empty_response(STATUS_IO_ERROR);
                            end else if (card_busy || read_inflight ||
                                         any_read_ready) begin
                                queue_empty_response(STATUS_BUSY);
                            end else begin
                                request_lba <= sys_request_lba;
                                request_block_count <=
                                    decoded_block_count;
                                write_request <= 1'b1;
                                queue_empty_response(STATUS_OK);
                            end
                        end

                        default:
                            queue_empty_response(STATUS_BAD_REQUEST);
                    endcase
                end

                CONTROL_WAIT_PRODUCER: begin
                    if (producer_grant) begin
                        fill_bank <= producer_bank;
                        fill_length <= pending_length;
                        fill_crc_work <= 32'hffff_ffff;
                        request_lba <= pending_lba;
                        request_block_count <= pending_block_count;
                        read_request <= 1'b1;
                        read_inflight <= 1'b1;
                        read_started <= 1'b0;
                        queue_empty_response(STATUS_OK);
                        acquire_sent <= 1'b0;
                        control_state <= CONTROL_IDLE;
                    end else if (!acquire_sent) begin
                        producer_acquire <= 1'b1;
                        acquire_sent <= 1'b1;
                    end else begin
                        acquire_sent <= 1'b0;
                    end
                end

                CONTROL_WAIT_CONSUMER: begin
                    if (consumer_grant) begin
                        sys_response_status <= STATUS_OK;
                        sys_response_length <=
                            bank_length[consumer_bank];
                        sys_response_crc <= bank_crc[consumer_bank];
                        sys_response_buffer <= consumer_bank;
                        sys_response_inline <= 1'b0;
                        sys_response_inline_data <= 64'd0;
                        sys_response_valid <= 1'b1;
                        response_uses_bank <= 1'b1;
                        response_active_bank <= consumer_bank;
                        debug_response_seen <= 1'b1;
                        acquire_sent <= 1'b0;
                        control_state <= CONTROL_IDLE;
                    end else if (!acquire_sent) begin
                        consumer_acquire <= 1'b1;
                        acquire_sent <= 1'b1;
                    end else begin
                        acquire_sent <= 1'b0;
                    end
                end

                default: control_state <= CONTROL_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
