`timescale 1ns/1ps
`default_nettype none

// Slave side of the private BL616 link. SCLK is sampled by the 48 MHz system
// clock through a synchronizer; the BL616 therefore acts as a slow master.
module fpga_spi_block_bridge (
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
    output reg  [3:0]  request_block_count,

    output wire [8:0]  buffer_addr,
    input  wire [7:0]  buffer_rdata,
    input  wire [11:0] write_buffer_addr,
    output reg  [7:0]  write_buffer_data,

    output reg         debug_cs_seen,
    output reg         debug_sclk_seen,
    output reg         debug_request_seen,
    output reg         debug_response_seen
);
    localparam [7:0]
        CMD_INFO = 8'h01, CMD_STATUS = 8'h02,
        CMD_READ_START = 8'h03, CMD_READ_DATA = 8'h04,
        CMD_WRITE_DATA = 8'h05;

    localparam [7:0]
        STATUS_OK = 8'd0, STATUS_BUSY = 8'd1,
        STATUS_READ_READY = 8'd2, STATUS_NOT_READY = 8'd3,
        STATUS_BAD_REQUEST = 8'd4, STATUS_IO_ERROR = 8'd5,
        STATUS_CRC_ERROR = 8'd6;

    localparam [1:0]
        RX_HEADER = 2'd0, RX_PAYLOAD = 2'd1,
        RX_PAYLOAD_CRC = 2'd2, RX_DISCARD = 2'd3;

    localparam [1:0]
        PAYLOAD_NONE = 2'd0, PAYLOAD_INFO = 2'd1,
        PAYLOAD_STATUS = 2'd2, PAYLOAD_BLOCK = 2'd3;

    reg [2:0] cs_sync;
    reg [2:0] sclk_sync;
    reg [2:0] mosi_sync;
    wire cs_active = !cs_sync[2];
    wire cs_fall = cs_sync[2:1] == 2'b10;
    wire cs_rise = cs_sync[2:1] == 2'b01;
    wire sclk_rise = sclk_sync[2:1] == 2'b01;
    wire sclk_fall = sclk_sync[2:1] == 2'b10;

    always @(posedge clk) begin
        if (rst) begin
            cs_sync   <= 3'b111;
            sclk_sync <= 3'b000;
            mosi_sync <= 3'b111;
        end else begin
            cs_sync   <= {cs_sync[1:0], spi_csn};
            sclk_sync <= {sclk_sync[1:0], spi_sclk};
            mosi_sync <= {mosi_sync[1:0], spi_mosi};
        end
    end

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

    reg [1:0] rx_state;
    reg [2:0] rx_bit_count;
    reg [7:0] rx_shift;
    reg [3:0] header_index;
    reg [7:0] header_xor;
    reg request_magic_ok;
    reg [7:0] request_command;
    reg [15:0] request_length;
    reg [15:0] payload_count;
    reg [1:0] payload_crc_count;
    reg [31:0] request_crc_work;
    reg [31:0] request_crc_received;
    wire [7:0] received_byte = {rx_shift[6:0], mosi_sync[2]};

    reg [7:0] response_status;
    reg [15:0] response_length;
    reg [1:0] response_payload_kind;
    reg [31:0] response_crc_work;
    reg [31:0] response_crc;
    reg [7:0] response_buffer [0:511];
    reg [15:0] scan_index;
    reg scan_active;
    reg scan_phase;
    reg [7:0] scan_data_reg;
    reg response_ready;
    reg [5:0] turnaround_count;
    reg [8:0] buffer_addr_reg;
    reg [7:0] request_buffer [0:4095];

    reg tx_active;
    reg [2:0] tx_bit_count;
    reg [15:0] tx_byte_index;

    wire tx_payload_phase =
        tx_active && tx_byte_index >= 16'd7 &&
        tx_byte_index < (16'd7 + response_length);
    wire [15:0] tx_payload_index = tx_byte_index - 16'd7;
    assign buffer_addr = scan_active ?
        scan_index[8:0] : buffer_addr_reg;

    function [7:0] generated_payload_byte;
        input [1:0] kind;
        input [15:0] index;
        begin
            case (kind)
                PAYLOAD_INFO: case (index)
                    0: generated_payload_byte = capacity_blocks[7:0];
                    1: generated_payload_byte = capacity_blocks[15:8];
                    2: generated_payload_byte = capacity_blocks[23:16];
                    3: generated_payload_byte = capacity_blocks[31:24];
                    4: generated_payload_byte =
                        {5'd0, card_error, card_sdhc, card_ready};
                    5: generated_payload_byte = card_error_code;
                    default: generated_payload_byte = 8'd0;
                endcase
                PAYLOAD_STATUS: case (index)
                    0: generated_payload_byte =
                        {4'd0, card_read_ready, card_busy,
                         card_error, card_ready};
                    1: generated_payload_byte = card_error_code;
                    2: generated_payload_byte = request_lba[7:0];
                    3: generated_payload_byte = request_lba[15:8];
                    4: generated_payload_byte = request_lba[23:16];
                    5: generated_payload_byte = request_lba[31:24];
                    default: generated_payload_byte = 8'd0;
                endcase
                PAYLOAD_BLOCK: generated_payload_byte = buffer_rdata;
                default: generated_payload_byte = 8'd0;
            endcase
        end
    endfunction

    wire [7:0] scan_byte =
        response_payload_kind == PAYLOAD_BLOCK ? buffer_rdata :
        generated_payload_byte(response_payload_kind, scan_index);
    wire [31:0] scan_crc_next =
        crc32_update(response_crc_work, scan_data_reg);

    function [7:0] response_byte;
        input [15:0] index;
        reg [15:0] payload_index;
        reg [15:0] crc_index;
        begin
            if (index < 16'd2)
                response_byte = 8'hff;
            else case (index)
                16'd2: response_byte = 8'h5a;
                16'd3: response_byte = response_status;
                16'd4: response_byte = response_length[7:0];
                16'd5: response_byte = response_length[15:8];
                16'd6: response_byte =
                    8'h5a ^ response_status ^
                    response_length[7:0] ^ response_length[15:8];
                default: begin
                    payload_index = index - 16'd7;
                    if (payload_index < response_length)
                        response_byte = generated_payload_byte(
                            response_payload_kind, payload_index);
                    else begin
                        crc_index = payload_index - response_length;
                        case (crc_index)
                            0: response_byte = response_crc[7:0];
                            1: response_byte = response_crc[15:8];
                            2: response_byte = response_crc[23:16];
                            3: response_byte = response_crc[31:24];
                            default: response_byte = 8'hff;
                        endcase
                    end
                end
            endcase
        end
    endfunction

    wire [7:0] current_tx_byte =
        tx_payload_phase && response_payload_kind == PAYLOAD_BLOCK ?
            response_buffer[tx_payload_index[8:0]] :
            response_byte(tx_byte_index);
    assign spi_miso = (cs_active && tx_active) ?
        current_tx_byte[3'd7 - tx_bit_count] : 1'b1;

    task start_response;
        input [7:0] status_value;
        input [15:0] length_value;
        input [1:0] payload_kind_value;
        begin
            response_status <= status_value;
            response_length <= length_value;
            response_payload_kind <= payload_kind_value;
            response_crc_work <= 32'hffff_ffff;
            response_crc <= 32'd0;
            scan_index <= 16'd0;
            scan_phase <= 1'b0;
            buffer_addr_reg <= 9'd0;
            if (length_value == 0) begin
                scan_active <= 1'b0;
                response_ready <= 1'b0;
                turnaround_count <= 6'd32;
            end else begin
                scan_active <= 1'b1;
                response_ready <= 1'b0;
                turnaround_count <= 6'd0;
            end
        end
    endtask

    task finish_header_command;
        begin
            case (request_command)
                CMD_INFO: begin
                    if (card_error)
                        start_response(STATUS_IO_ERROR, 0, PAYLOAD_NONE);
                    else if (!card_ready)
                        start_response(STATUS_NOT_READY, 0, PAYLOAD_NONE);
                    else
                        start_response(STATUS_OK, 16'd8, PAYLOAD_INFO);
                end
                CMD_STATUS: begin
                    if (card_error)
                        start_response(STATUS_IO_ERROR, 16'd8,
                                       PAYLOAD_STATUS);
                    else if (!card_ready)
                        start_response(STATUS_NOT_READY, 16'd8,
                                       PAYLOAD_STATUS);
                    else if (card_busy)
                        start_response(STATUS_BUSY, 16'd8,
                                       PAYLOAD_STATUS);
                    else if (card_read_ready)
                        start_response(STATUS_READ_READY, 16'd8,
                                       PAYLOAD_STATUS);
                    else
                        start_response(STATUS_OK, 16'd8,
                                       PAYLOAD_STATUS);
                end
                CMD_READ_START: begin
                    if (!card_ready)
                        start_response(STATUS_NOT_READY, 0, PAYLOAD_NONE);
                    else if (card_error)
                        start_response(STATUS_IO_ERROR, 0, PAYLOAD_NONE);
                    else if (card_busy)
                        start_response(STATUS_BUSY, 0, PAYLOAD_NONE);
                    else if (request_lba >= capacity_blocks)
                        start_response(STATUS_BAD_REQUEST, 0, PAYLOAD_NONE);
                    else begin
                        read_request <= 1'b1;
                        start_response(STATUS_OK, 0, PAYLOAD_NONE);
                    end
                end
                CMD_READ_DATA: begin
                    if (card_read_ready)
                        start_response(STATUS_OK, 16'd512, PAYLOAD_BLOCK);
                    else if (card_busy)
                        start_response(STATUS_BUSY, 0, PAYLOAD_NONE);
                    else
                        start_response(STATUS_NOT_READY, 0, PAYLOAD_NONE);
                end
                default:
                    start_response(STATUS_BAD_REQUEST, 0, PAYLOAD_NONE);
            endcase
        end
    endtask

    always @(posedge clk) begin
        read_request <= 1'b0;
        write_request <= 1'b0;
        write_buffer_data <= request_buffer[write_buffer_addr];

        if (rst) begin
            rx_state <= RX_HEADER;
            rx_bit_count <= 3'd0;
            rx_shift <= 8'd0;
            header_index <= 4'd0;
            header_xor <= 8'd0;
            request_magic_ok <= 1'b0;
            request_command <= 8'd0;
            request_lba <= 32'd0;
            request_block_count <= 4'd1;
            request_length <= 16'd0;
            payload_count <= 16'd0;
            payload_crc_count <= 2'd0;
            request_crc_work <= 32'hffff_ffff;
            request_crc_received <= 32'd0;
            response_status <= STATUS_NOT_READY;
            response_length <= 16'd0;
            response_payload_kind <= PAYLOAD_NONE;
            response_crc_work <= 32'hffff_ffff;
            response_crc <= 32'd0;
            scan_index <= 16'd0;
            scan_active <= 1'b0;
            scan_phase <= 1'b0;
            scan_data_reg <= 8'd0;
            response_ready <= 1'b0;
            turnaround_count <= 6'd0;
            buffer_addr_reg <= 9'd0;
            write_buffer_data <= 8'd0;
            tx_active <= 1'b0;
            tx_bit_count <= 3'd0;
            tx_byte_index <= 16'd0;
            debug_cs_seen <= 1'b0;
            debug_sclk_seen <= 1'b0;
            debug_request_seen <= 1'b0;
            debug_response_seen <= 1'b0;
        end else begin
            if (cs_fall) begin
                debug_cs_seen <= 1'b1;
                rx_state <= RX_HEADER;
                rx_bit_count <= 3'd0;
                header_index <= 4'd0;
                header_xor <= 8'd0;
                request_magic_ok <= 1'b0;
                request_length <= 16'd0;
                payload_count <= 16'd0;
                request_crc_work <= 32'hffff_ffff;
                request_crc_received <= 32'd0;
                scan_active <= 1'b0;
                scan_phase <= 1'b0;
                response_ready <= 1'b0;
                turnaround_count <= 6'd0;
                tx_active <= 1'b0;
            end

            if (cs_rise) begin
                tx_active <= 1'b0;
                response_ready <= 1'b0;
                scan_active <= 1'b0;
                turnaround_count <= 6'd0;
            end

            if (cs_active && sclk_rise)
                debug_sclk_seen <= 1'b1;

            if (cs_active && !tx_active && sclk_rise) begin
                rx_shift <= {rx_shift[6:0], mosi_sync[2]};
                if (rx_bit_count == 3'd7) begin
                    rx_bit_count <= 3'd0;
                    case (rx_state)
                        RX_HEADER: begin
                            if (header_index < 4'd8)
                                header_xor <= header_xor ^ received_byte;
                            case (header_index)
                                0: request_magic_ok <=
                                    received_byte == 8'ha5;
                                1: request_command <= received_byte;
                                2: request_lba[7:0] <= received_byte;
                                3: request_lba[15:8] <= received_byte;
                                4: request_lba[23:16] <= received_byte;
                                5: request_lba[31:24] <= received_byte;
                                6: request_length[7:0] <= received_byte;
                                7: request_length[15:8] <= received_byte;
                                8: begin
                                    if (!request_magic_ok ||
                                        received_byte != header_xor) begin
                                        rx_state <= RX_DISCARD;
                                        start_response(STATUS_CRC_ERROR, 0,
                                                       PAYLOAD_NONE);
                                    end else if (request_length == 0) begin
                                        rx_state <= RX_DISCARD;
                                        debug_request_seen <= 1'b1;
                                        finish_header_command();
                                    end else if (
                                        request_command == CMD_WRITE_DATA &&
                                        (request_length == 16'd512 ||
                                         request_length == 16'd4096)) begin
                                        debug_request_seen <= 1'b1;
                                        rx_state <= RX_PAYLOAD;
                                        payload_count <= 16'd0;
                                        request_crc_work <= 32'hffff_ffff;
                                    end else begin
                                        rx_state <= RX_DISCARD;
                                        start_response(STATUS_BAD_REQUEST, 0,
                                                       PAYLOAD_NONE);
                                    end
                                end
                                default: ;
                            endcase
                            if (header_index != 4'd8)
                                header_index <= header_index + 4'd1;
                        end

                        RX_PAYLOAD: begin
                            request_buffer[payload_count[11:0]] <=
                                received_byte;
                            request_crc_work <= crc32_update(
                                request_crc_work, received_byte);
                            if (payload_count + 16'd1 == request_length) begin
                                rx_state <= RX_PAYLOAD_CRC;
                                payload_crc_count <= 2'd0;
                                request_crc_received <= 32'd0;
                            end else
                                payload_count <= payload_count + 16'd1;
                        end

                        RX_PAYLOAD_CRC: begin
                            case (payload_crc_count)
                                0: request_crc_received[7:0] <=
                                    received_byte;
                                1: request_crc_received[15:8] <=
                                    received_byte;
                                2: request_crc_received[23:16] <=
                                    received_byte;
                                3: begin
                                    request_crc_received[31:24] <=
                                        received_byte;
                                    rx_state <= RX_DISCARD;
                                    if ({received_byte,
                                         request_crc_received[23:0]} !=
                                        (request_crc_work ^
                                         32'hffff_ffff)) begin
                                        start_response(STATUS_CRC_ERROR, 0,
                                                       PAYLOAD_NONE);
                                    end else if (!card_ready) begin
                                        start_response(STATUS_NOT_READY, 0,
                                                       PAYLOAD_NONE);
                                    end else if (card_error) begin
                                        start_response(STATUS_IO_ERROR, 0,
                                                       PAYLOAD_NONE);
                                    end else if (card_busy) begin
                                        start_response(STATUS_BUSY, 0,
                                                       PAYLOAD_NONE);
                                    end else if (
                                        request_lba >= capacity_blocks) begin
                                        start_response(STATUS_BAD_REQUEST, 0,
                                                       PAYLOAD_NONE);
                                    end else begin
                                        request_block_count <=
                                            request_length[12:9];
                                        write_request <= 1'b1;
                                        start_response(STATUS_OK, 0,
                                                       PAYLOAD_NONE);
                                    end
                                end
                            endcase
                            if (payload_crc_count != 2'd3)
                                payload_crc_count <=
                                    payload_crc_count + 2'd1;
                        end
                        default: ;
                    endcase
                end else begin
                    rx_bit_count <= rx_bit_count + 3'd1;
                end
            end

            if (scan_active) begin
                if (!scan_phase) begin
                    // Break the block-RAM -> CRC combinational timing path.
                    scan_data_reg <= scan_byte;
                    if (response_payload_kind == PAYLOAD_BLOCK)
                        response_buffer[scan_index[8:0]] <= buffer_rdata;
                    scan_phase <= 1'b1;
                end else begin
                    response_crc_work <= scan_crc_next;
                    scan_phase <= 1'b0;
                    if (scan_index + 16'd1 == response_length) begin
                        response_crc <= scan_crc_next ^ 32'hffff_ffff;
                        scan_active <= 1'b0;
                        turnaround_count <= 6'd32;
                    end else begin
                        scan_index <= scan_index + 16'd1;
                    end
                end
            end

            /*
             * Do not begin driving MISO during the falling edge that ends the
             * request checksum. The master leaves a much longer turnaround
             * delay, so this fixed guard gives byte-aligned mode-0 replies.
             */
            if (turnaround_count != 0) begin
                turnaround_count <= turnaround_count - 6'd1;
                if (turnaround_count == 6'd1)
                    response_ready <= 1'b1;
            end

            if (cs_active && response_ready && !tx_active) begin
                debug_response_seen <= 1'b1;
                tx_active <= 1'b1;
                tx_byte_index <= 16'd0;
                tx_bit_count <= 3'd0;
            end else if (tx_active && sclk_fall) begin
                if (tx_bit_count == 3'd7) begin
                    tx_bit_count <= 3'd0;
                    tx_byte_index <= tx_byte_index + 16'd1;
                end else begin
                    tx_bit_count <= tx_bit_count + 3'd1;
                end
            end
        end
    end
endmodule

`default_nettype wire
