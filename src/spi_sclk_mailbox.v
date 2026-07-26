`timescale 1ns/1ps
`default_nettype none

/*
 * Source-synchronous SPI mode-0 frontend for the BL616 private link.
 *
 * All wire-level shifting and frame parsing runs directly from spi_sclk.
 * Only stable request/response descriptors cross into the system clock
 * domain, using toggle mailboxes. Payload bytes use separate buffer ports so
 * the integration can map them to true dual-port BSRAM.
 *
 * A request descriptor remains stable until the system clock domain observes
 * its toggle. A response descriptor remains stable until the response has
 * been clocked out or the chip-select transaction ends.
 */
module spi_sclk_mailbox #(
    parameter integer MAX_PAYLOAD_BYTES = 16384,
    parameter integer BUFFER_ADDR_WIDTH = 14
) (
    input  wire        sys_clk,
    input  wire        sys_rst,

    input  wire        spi_csn,
    input  wire        spi_sclk,
    input  wire        spi_mosi,
    output wire        spi_miso,

    output reg         sys_request_valid,
    output reg  [7:0]  sys_request_command,
    output reg  [31:0] sys_request_lba,
    output reg  [15:0] sys_request_length,
    output reg         sys_request_has_payload,
    output reg         sys_request_crc_ok,

    output wire        request_buffer_we_sclk,
    output wire [BUFFER_ADDR_WIDTH-1:0]
                       request_buffer_addr_sclk,
    output wire [7:0]  request_buffer_data_sclk,

    output wire        sys_response_ready,
    input  wire        sys_response_valid,
    input  wire [7:0]  sys_response_status,
    input  wire [15:0] sys_response_length,
    input  wire [31:0] sys_response_crc,
    input  wire        sys_response_buffer,
    input  wire        sys_response_inline,
    input  wire [63:0] sys_response_inline_data,
    output reg         sys_response_done,

    output wire [BUFFER_ADDR_WIDTH:0]
                       response_buffer_addr_sclk,
    input  wire [7:0]  response_buffer_data_sclk
);
    localparam [1:0]
        RX_HEADER = 2'd0,
        RX_PAYLOAD = 2'd1,
        RX_PAYLOAD_CRC = 2'd2,
        RX_DISCARD = 2'd3;
    localparam [7:0] CMD_WRITE_DATA = 8'h05;

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

    /*
     * Request parser and request mailbox producer: spi_sclk domain.
     * spi_csn is a frame reset, so every transaction starts byte-aligned.
     */
    reg [1:0] rx_state;
    reg [2:0] rx_bit_count;
    reg [7:0] rx_shift;
    reg [3:0] header_index;
    reg [7:0] header_xor;
    reg request_magic_ok;
    reg request_header_ok;
    reg [7:0] request_command_sclk;
    reg [31:0] request_lba_sclk;
    reg [15:0] request_length_sclk;
    reg [15:0] payload_count;
    reg [1:0] payload_crc_count;
    reg [31:0] request_crc_work;
    reg [31:0] request_crc_received;

    wire [7:0] received_byte = {rx_shift[6:0], spi_mosi};
    wire received_byte_valid = !spi_csn && !tx_active &&
                               rx_bit_count == 3'd7;
    wire payload_byte_valid = received_byte_valid &&
                              rx_state == RX_PAYLOAD &&
                              payload_count < MAX_PAYLOAD_BYTES;

    assign request_buffer_we_sclk = payload_byte_valid;
    assign request_buffer_addr_sclk =
        payload_count[BUFFER_ADDR_WIDTH-1:0];
    assign request_buffer_data_sclk = received_byte;

    wire header_complete = received_byte_valid &&
                           rx_state == RX_HEADER &&
                           header_index == 4'd8;
    wire header_check_ok = request_magic_ok &&
                           received_byte == header_xor;
    wire header_commits_request =
        header_complete &&
        (!header_check_ok ||
         request_command_sclk != CMD_WRITE_DATA ||
         request_length_sclk == 0 ||
         request_length_sclk > MAX_PAYLOAD_BYTES);
    wire payload_crc_complete = received_byte_valid &&
                                rx_state == RX_PAYLOAD_CRC &&
                                payload_crc_count == 2'd3;
    wire payload_crc_ok =
        request_header_ok &&
        {received_byte, request_crc_received[23:0]} ==
            (request_crc_work ^ 32'hffff_ffff);
    wire commit_request = header_commits_request ||
                          payload_crc_complete;
    wire committed_crc_ok = header_commits_request ?
                            header_check_ok : payload_crc_ok;
    wire committed_has_payload = !header_commits_request &&
                                 request_length_sclk != 0;

    reg [7:0] request_command_mailbox;
    reg [31:0] request_lba_mailbox;
    reg [15:0] request_length_mailbox;
    reg request_has_payload_mailbox;
    reg request_crc_ok_mailbox;
    reg request_toggle_sclk;

    /*
     * Response mailbox consumer: descriptor synchronization is separate from
     * frame reset so each system response is consumed exactly once.
     */
    reg response_toggle_sync1;
    reg response_toggle_sync2;
    reg response_toggle_seen_sclk;
    wire response_available =
        response_toggle_sync2 != response_toggle_seen_sclk;
    wire load_response = !spi_csn && !tx_active &&
                         response_available &&
                         rx_bit_count == 3'd7;

    reg [7:0] response_status_mailbox;
    reg [15:0] response_length_mailbox;
    reg [31:0] response_crc_mailbox;
    reg response_buffer_mailbox;
    reg response_inline_mailbox;
    reg [63:0] response_inline_data_mailbox;
    reg response_toggle_sys;
    reg response_busy_sys;

    always @(posedge spi_sclk or posedge sys_rst) begin
        if (sys_rst) begin
            response_toggle_sync1 <= 1'b0;
            response_toggle_sync2 <= 1'b0;
        end else begin
            response_toggle_sync1 <= response_toggle_sys;
            response_toggle_sync2 <= response_toggle_sync1;
        end
    end

    always @(posedge spi_sclk or posedge sys_rst) begin
        if (sys_rst) begin
            request_command_mailbox <= 8'd0;
            request_lba_mailbox <= 32'd0;
            request_length_mailbox <= 16'd0;
            request_has_payload_mailbox <= 1'b0;
            request_crc_ok_mailbox <= 1'b0;
            request_toggle_sclk <= 1'b0;
            response_toggle_seen_sclk <= 1'b0;
        end else begin
            if (commit_request) begin
                request_command_mailbox <= request_command_sclk;
                request_lba_mailbox <= request_lba_sclk;
                request_length_mailbox <= request_length_sclk;
                request_has_payload_mailbox <= committed_has_payload;
                request_crc_ok_mailbox <= committed_crc_ok;
                request_toggle_sclk <= ~request_toggle_sclk;
            end
            if (load_response)
                response_toggle_seen_sclk <= response_toggle_sync2;
        end
    end

    always @(posedge spi_sclk or posedge spi_csn or posedge sys_rst) begin
        if (sys_rst || spi_csn) begin
            rx_state <= RX_HEADER;
            rx_bit_count <= 3'd0;
            rx_shift <= 8'd0;
            header_index <= 4'd0;
            header_xor <= 8'd0;
            request_magic_ok <= 1'b0;
            request_header_ok <= 1'b0;
            request_command_sclk <= 8'd0;
            request_lba_sclk <= 32'd0;
            request_length_sclk <= 16'd0;
            payload_count <= 16'd0;
            payload_crc_count <= 2'd0;
            request_crc_work <= 32'hffff_ffff;
            request_crc_received <= 32'd0;
        end else if (!tx_active) begin
            rx_shift <= received_byte;
            if (rx_bit_count == 3'd7) begin
                rx_bit_count <= 3'd0;
                case (rx_state)
                    RX_HEADER: begin
                        if (header_index < 4'd8)
                            header_xor <= header_xor ^ received_byte;
                        case (header_index)
                            0: request_magic_ok <=
                                received_byte == 8'ha5;
                            1: request_command_sclk <= received_byte;
                            2: request_lba_sclk[7:0] <= received_byte;
                            3: request_lba_sclk[15:8] <= received_byte;
                            4: request_lba_sclk[23:16] <= received_byte;
                            5: request_lba_sclk[31:24] <= received_byte;
                            6: request_length_sclk[7:0] <= received_byte;
                            7: request_length_sclk[15:8] <= received_byte;
                            8: begin
                                request_header_ok <= header_check_ok;
                                if (!header_check_ok ||
                                    request_command_sclk !=
                                        CMD_WRITE_DATA ||
                                    request_length_sclk == 0 ||
                                    request_length_sclk >
                                        MAX_PAYLOAD_BYTES) begin
                                    rx_state <= RX_DISCARD;
                                end else begin
                                    rx_state <= RX_PAYLOAD;
                                    payload_count <= 16'd0;
                                    request_crc_work <= 32'hffff_ffff;
                                end
                            end
                            default: ;
                        endcase
                        if (header_index != 4'd8)
                            header_index <= header_index + 4'd1;
                    end

                    RX_PAYLOAD: begin
                        request_crc_work <= crc32_update(
                            request_crc_work, received_byte);
                        if (payload_count + 16'd1 ==
                            request_length_sclk) begin
                            rx_state <= RX_PAYLOAD_CRC;
                            payload_crc_count <= 2'd0;
                            request_crc_received <= 32'd0;
                        end else begin
                            payload_count <= payload_count + 16'd1;
                        end
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
                            end
                            default: ;
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
    end

    /*
     * Request mailbox consumer: sys_clk domain.
     */
    reg request_toggle_sync1;
    reg request_toggle_sync2;
    reg request_toggle_seen_sys;

    always @(posedge sys_clk) begin
        sys_request_valid <= 1'b0;
        if (sys_rst) begin
            request_toggle_sync1 <= 1'b0;
            request_toggle_sync2 <= 1'b0;
            request_toggle_seen_sys <= 1'b0;
            sys_request_command <= 8'd0;
            sys_request_lba <= 32'd0;
            sys_request_length <= 16'd0;
            sys_request_has_payload <= 1'b0;
            sys_request_crc_ok <= 1'b0;
        end else begin
            request_toggle_sync1 <= request_toggle_sclk;
            request_toggle_sync2 <= request_toggle_sync1;
            if (request_toggle_sync2 != request_toggle_seen_sys) begin
                request_toggle_seen_sys <= request_toggle_sync2;
                sys_request_command <= request_command_mailbox;
                sys_request_lba <= request_lba_mailbox;
                sys_request_length <= request_length_mailbox;
                sys_request_has_payload <= request_has_payload_mailbox;
                sys_request_crc_ok <= request_crc_ok_mailbox;
                sys_request_valid <= 1'b1;
            end
        end
    end

    /*
     * Response mailbox producer and completion synchronization: sys_clk
     * domain. The descriptor is held unchanged while response_busy_sys is set.
     */
    reg response_done_toggle_sclk;
    reg response_done_sync1;
    reg response_done_sync2;
    reg response_done_seen_sys;
    reg [2:0] cs_sync_sys;
    wire cs_rise_sys = cs_sync_sys[2:1] == 2'b01;

    assign sys_response_ready = !response_busy_sys;

    always @(posedge sys_clk) begin
        sys_response_done <= 1'b0;
        if (sys_rst) begin
            response_status_mailbox <= 8'd0;
            response_length_mailbox <= 16'd0;
            response_crc_mailbox <= 32'd0;
            response_buffer_mailbox <= 1'b0;
            response_inline_mailbox <= 1'b0;
            response_inline_data_mailbox <= 64'd0;
            response_toggle_sys <= 1'b0;
            response_busy_sys <= 1'b0;
            response_done_sync1 <= 1'b0;
            response_done_sync2 <= 1'b0;
            response_done_seen_sys <= 1'b0;
            cs_sync_sys <= 3'b111;
        end else begin
            cs_sync_sys <= {cs_sync_sys[1:0], spi_csn};
            response_done_sync1 <= response_done_toggle_sclk;
            response_done_sync2 <= response_done_sync1;

            if (response_done_sync2 != response_done_seen_sys) begin
                response_done_seen_sys <= response_done_sync2;
                response_busy_sys <= 1'b0;
                sys_response_done <= 1'b1;
            end else if (response_busy_sys && cs_rise_sys) begin
                response_busy_sys <= 1'b0;
                sys_response_done <= 1'b1;
            end

            if (sys_response_valid && !response_busy_sys) begin
                response_status_mailbox <= sys_response_status;
                response_length_mailbox <= sys_response_length;
                response_crc_mailbox <= sys_response_crc;
                response_buffer_mailbox <= sys_response_buffer;
                response_inline_mailbox <= sys_response_inline;
                response_inline_data_mailbox <= sys_response_inline_data;
                response_toggle_sys <= ~response_toggle_sys;
                response_busy_sys <= 1'b1;
            end
        end
    end

    /*
     * Response shifter: spi_sclk domain.
     *
     * MISO changes immediately after the rising edge at which the preceding
     * bit was sampled, leaving nearly one full SCLK period of setup time for
     * the next rising edge. Response payload addresses run one byte ahead so a
     * synchronous BSRAM read port can prefetch the next payload byte.
     */
    reg tx_active;
    reg [2:0] tx_bit_count;
    reg [15:0] tx_byte_index;
    reg [7:0] tx_shift;
    reg [7:0] tx_response_status;
    reg [15:0] tx_response_length;
    reg [31:0] tx_response_crc;
    reg tx_response_buffer;
    reg tx_response_inline;
    reg [63:0] tx_response_inline_data;

    wire [15:0] tx_last_byte_index =
        tx_response_length == 0 ? 16'd6 :
        16'd10 + tx_response_length;
    wire [15:0] tx_next_byte_index = tx_byte_index + 16'd1;
    wire tx_next_is_payload =
        tx_next_byte_index >= 16'd7 &&
        tx_next_byte_index < 16'd7 + tx_response_length;

    wire [15:0] response_prefetch_index =
        tx_byte_index >= 16'd6 &&
        tx_byte_index < 16'd6 + tx_response_length ?
            tx_byte_index - 16'd6 : 16'd0;
    assign response_buffer_addr_sclk =
        {tx_response_buffer,
         response_prefetch_index[BUFFER_ADDR_WIDTH-1:0]};

    function [7:0] response_byte;
        input [15:0] index;
        reg [15:0] payload_index;
        reg [15:0] crc_index;
        begin
            case (index)
                16'd0, 16'd1: response_byte = 8'hff;
                16'd2: response_byte = 8'h5a;
                16'd3: response_byte = tx_response_status;
                16'd4: response_byte = tx_response_length[7:0];
                16'd5: response_byte = tx_response_length[15:8];
                16'd6: response_byte =
                    8'h5a ^ tx_response_status ^
                    tx_response_length[7:0] ^
                    tx_response_length[15:8];
                default: begin
                    payload_index = index - 16'd7;
                    if (payload_index < tx_response_length) begin
                        response_byte = response_buffer_data_sclk;
                    end else begin
                        crc_index = payload_index - tx_response_length;
                        case (crc_index)
                            0: response_byte = tx_response_crc[7:0];
                            1: response_byte = tx_response_crc[15:8];
                            2: response_byte = tx_response_crc[23:16];
                            3: response_byte = tx_response_crc[31:24];
                            default: response_byte = 8'hff;
                        endcase
                    end
                end
            endcase
        end
    endfunction

    function [7:0] inline_response_byte;
        input [15:0] index;
        begin
            case (index)
                0: inline_response_byte = tx_response_inline_data[7:0];
                1: inline_response_byte = tx_response_inline_data[15:8];
                2: inline_response_byte = tx_response_inline_data[23:16];
                3: inline_response_byte = tx_response_inline_data[31:24];
                4: inline_response_byte = tx_response_inline_data[39:32];
                5: inline_response_byte = tx_response_inline_data[47:40];
                6: inline_response_byte = tx_response_inline_data[55:48];
                7: inline_response_byte = tx_response_inline_data[63:56];
                default: inline_response_byte = 8'd0;
            endcase
        end
    endfunction

    assign spi_miso = (!spi_csn && tx_active) ?
                      tx_shift[3'd7 - tx_bit_count] : 1'b1;

    always @(posedge spi_sclk or posedge spi_csn or posedge sys_rst) begin
        if (sys_rst || spi_csn) begin
            tx_active <= 1'b0;
            tx_bit_count <= 3'd0;
            tx_byte_index <= 16'd0;
            tx_shift <= 8'hff;
            tx_response_status <= 8'd0;
            tx_response_length <= 16'd0;
            tx_response_crc <= 32'd0;
            tx_response_buffer <= 1'b0;
            tx_response_inline <= 1'b0;
            tx_response_inline_data <= 64'd0;
        end else if (load_response) begin
            tx_active <= 1'b1;
            tx_bit_count <= 3'd0;
            tx_byte_index <= 16'd0;
            tx_shift <= 8'hff;
            tx_response_status <= response_status_mailbox;
            tx_response_length <= response_length_mailbox;
            tx_response_crc <= response_crc_mailbox;
            tx_response_buffer <= response_buffer_mailbox;
            tx_response_inline <= response_inline_mailbox;
            tx_response_inline_data <= response_inline_data_mailbox;
        end else if (tx_active) begin
            if (tx_bit_count == 3'd7) begin
                tx_bit_count <= 3'd0;
                if (tx_byte_index == tx_last_byte_index) begin
                    tx_active <= 1'b0;
                end else begin
                    tx_byte_index <= tx_next_byte_index;
                    if (tx_next_is_payload)
                        tx_shift <= tx_response_inline ?
                            inline_response_byte(
                                tx_next_byte_index - 16'd7) :
                            response_buffer_data_sclk;
                    else
                        tx_shift <= response_byte(tx_next_byte_index);
                end
            end else begin
                tx_bit_count <= tx_bit_count + 3'd1;
            end
        end
    end

    always @(posedge spi_sclk or posedge sys_rst) begin
        if (sys_rst) begin
            response_done_toggle_sclk <= 1'b0;
        end else if (tx_active && tx_bit_count == 3'd7 &&
                     tx_byte_index == tx_last_byte_index) begin
            response_done_toggle_sclk <= ~response_done_toggle_sclk;
        end
    end
endmodule

`default_nettype wire
