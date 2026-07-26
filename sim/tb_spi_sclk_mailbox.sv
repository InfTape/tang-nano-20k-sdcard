`timescale 1ns/1ps

module tb_spi_sclk_mailbox;
    reg sys_clk = 0;
    always #10.416 sys_clk = ~sys_clk;

    reg sys_rst = 0;
    reg spi_csn = 1;
    reg spi_sclk = 0;
    reg spi_mosi = 1;
    wire spi_miso;

    wire sys_request_valid;
    wire [7:0] sys_request_command;
    wire [31:0] sys_request_lba;
    wire [15:0] sys_request_length;
    wire sys_request_has_payload;
    wire sys_request_crc_ok;

    wire request_buffer_we_sclk;
    wire [13:0] request_buffer_addr_sclk;
    wire [7:0] request_buffer_data_sclk;
    reg [7:0] request_memory [0:16383];

    wire sys_response_ready;
    reg sys_response_valid = 0;
    reg [7:0] sys_response_status = 0;
    reg [15:0] sys_response_length = 0;
    reg [31:0] sys_response_crc = 0;
    reg sys_response_buffer = 0;
    reg sys_response_inline = 0;
    reg [63:0] sys_response_inline_data = 0;
    wire sys_response_done;

    wire [14:0] response_buffer_addr_sclk;
    reg [7:0] response_buffer_data_sclk = 0;
    reg [7:0] response_memory [0:32767];

    integer i;
    integer request_count = 0;
    reg [7:0] rx_byte;
    reg [31:0] crc;

    spi_sclk_mailbox dut (
        .sys_clk(sys_clk), .sys_rst(sys_rst),
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

    always @(posedge spi_sclk) begin
        if (request_buffer_we_sclk)
            request_memory[request_buffer_addr_sclk] <=
                request_buffer_data_sclk;
        response_buffer_data_sclk <=
            response_memory[response_buffer_addr_sclk];
    end

    always @(posedge sys_clk) begin
        if (sys_request_valid)
            request_count <= request_count + 1;
    end

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] value;
        integer bit_index;
        reg [31:0] value_crc;
        begin
            value_crc = crc_in ^ value;
            for (bit_index = 0; bit_index < 8;
                 bit_index = bit_index + 1)
                value_crc = (value_crc >> 1) ^
                    (value_crc[0] ? 32'hedb8_8320 : 32'd0);
            crc32_byte = value_crc;
        end
    endfunction

    /*
     * 20 MHz SPI mode 0. Sample MISO immediately before the rising edge; the
     * DUT advances it just after that edge for the following bit.
     */
    task spi_transfer_byte;
        input [7:0] value;
        output [7:0] received;
        integer bit_index;
        begin
            received = 0;
            for (bit_index = 7; bit_index >= 0;
                 bit_index = bit_index - 1) begin
                spi_mosi = value[bit_index];
                #25;
                received = {received[6:0], spi_miso};
                spi_sclk = 1;
                #25;
                spi_sclk = 0;
            end
        end
    endtask

    task send_header;
        input [7:0] command;
        input [31:0] lba;
        input [15:0] length;
        reg [7:0] bytes [0:8];
        reg [7:0] ignored;
        integer index;
        begin
            bytes[0] = 8'ha5;
            bytes[1] = command;
            bytes[2] = lba[7:0];
            bytes[3] = lba[15:8];
            bytes[4] = lba[23:16];
            bytes[5] = lba[31:24];
            bytes[6] = length[7:0];
            bytes[7] = length[15:8];
            bytes[8] = 0;
            for (index = 0; index < 8; index = index + 1)
                bytes[8] = bytes[8] ^ bytes[index];
            for (index = 0; index < 9; index = index + 1)
                spi_transfer_byte(bytes[index], ignored);
        end
    endtask

    task wait_for_request;
        input integer expected_count;
        input [7:0] expected_command;
        input [31:0] expected_lba;
        input [15:0] expected_length;
        input expected_payload;
        begin
            wait (request_count == expected_count);
            if (sys_request_command != expected_command ||
                sys_request_lba != expected_lba ||
                sys_request_length != expected_length ||
                sys_request_has_payload != expected_payload ||
                !sys_request_crc_ok) begin
                $display("FAIL: request descriptor cmd=%02x lba=%08x len=%0d payload=%0d crc=%0d",
                         sys_request_command, sys_request_lba,
                         sys_request_length, sys_request_has_payload,
                         sys_request_crc_ok);
                $fatal;
            end
            @(posedge sys_clk);
        end
    endtask

    task submit_response;
        input [7:0] status;
        input [15:0] length;
        input [31:0] response_crc;
        input buffer_bank;
        input inline_payload;
        input [63:0] inline_data;
        begin
            wait (sys_response_ready);
            @(negedge sys_clk);
            sys_response_status = status;
            sys_response_length = length;
            sys_response_crc = response_crc;
            sys_response_buffer = buffer_bank;
            sys_response_inline = inline_payload;
            sys_response_inline_data = inline_data;
            sys_response_valid = 1;
            @(negedge sys_clk);
            sys_response_valid = 0;
        end
    endtask

    task receive_response_magic;
        integer scan;
        begin
            rx_byte = 0;
            scan = 0;
            while (rx_byte != 8'h5a && scan < 12) begin
                spi_transfer_byte(8'hff, rx_byte);
                scan = scan + 1;
            end
            if (rx_byte != 8'h5a) begin
                $display("FAIL: response magic not found");
                $fatal;
            end
        end
    endtask

    initial begin
        for (i = 0; i < 16384; i = i + 1) begin
            request_memory[i] = 0;
            response_memory[i] = i[7:0] ^ 8'h91;
            response_memory[16384 + i] = i[7:0] ^ 8'h6d;
        end

        #20;
        sys_rst = 1;
        #100;
        sys_rst = 0;
        #100;

        // Header-only INFO request crosses into the 48 MHz system domain.
        spi_csn = 0;
        send_header(8'h01, 32'h1234_5678, 16'd0);
        wait_for_request(1, 8'h01, 32'h1234_5678, 16'd0, 1'b0);

        // Return 32 bytes through a synchronous SCLK-domain buffer port.
        crc = 32'hffff_ffff;
        for (i = 0; i < 32; i = i + 1)
            crc = crc32_byte(crc, response_memory[16384 + i]);
        submit_response(8'h00, 16'd32, crc ^ 32'hffff_ffff,
                        1'b1, 1'b0, 64'd0);

        receive_response_magic();
        spi_transfer_byte(8'hff, rx_byte);
        if (rx_byte != 8'h00) begin
            $display("FAIL: response status %02x", rx_byte);
            $fatal;
        end
        spi_transfer_byte(8'hff, rx_byte);
        if (rx_byte != 8'd32) begin
            $display("FAIL: response length low %02x", rx_byte);
            $fatal;
        end
        spi_transfer_byte(8'hff, rx_byte);
        if (rx_byte != 8'd0) begin
            $display("FAIL: response length high %02x", rx_byte);
            $fatal;
        end
        spi_transfer_byte(8'hff, rx_byte);
        if (rx_byte != (8'h5a ^ 8'd32)) begin
            $display("FAIL: response header check %02x", rx_byte);
            $fatal;
        end
        crc = 32'hffff_ffff;
        for (i = 0; i < 32; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            if (rx_byte != response_memory[16384 + i]) begin
                $display("FAIL: response payload[%0d]=%02x expected=%02x",
                         i, rx_byte, response_memory[16384 + i]);
                $fatal;
            end
            crc = crc32_byte(crc, rx_byte);
        end
        for (i = 0; i < 4; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            if (rx_byte !=
                (((crc ^ 32'hffff_ffff) >> (8 * i)) & 32'hff)) begin
                $display("FAIL: response CRC byte %0d=%02x expected=%02x full=%08x",
                         i, rx_byte,
                         ((crc ^ 32'hffff_ffff) >> (8 * i)),
                         crc ^ 32'hffff_ffff);
                $fatal;
            end
        end
        spi_csn = 1;
        #200;
        if (!sys_response_done) begin
            // sys_response_done is a pulse; readiness proves ownership return.
            if (!sys_response_ready) begin
                $display("FAIL: response ownership was not returned");
                $fatal;
            end
        end

        // A payload request writes the SCLK port and crosses only metadata.
        #100;
        spi_csn = 0;
        send_header(8'h05, 32'h0000_4000, 16'd512);
        crc = 32'hffff_ffff;
        for (i = 0; i < 512; i = i + 1) begin
            spi_transfer_byte(i[7:0] ^ 8'ha7, rx_byte);
            crc = crc32_byte(crc, i[7:0] ^ 8'ha7);
        end
        crc = crc ^ 32'hffff_ffff;
        for (i = 0; i < 4; i = i + 1)
            spi_transfer_byte(crc >> (8 * i), rx_byte);
        wait_for_request(2, 8'h05, 32'h0000_4000, 16'd512, 1'b1);
        for (i = 0; i < 512; i = i + 1) begin
            if (request_memory[i] != (i[7:0] ^ 8'ha7)) begin
                $display("FAIL: request payload[%0d]=%02x expected=%02x",
                         i, request_memory[i], (i[7:0] ^ 8'ha7));
                $fatal;
            end
        end
        submit_response(8'h00, 16'd0, 32'd0,
                        1'b0, 1'b0, 64'd0);
        receive_response_magic();
        spi_transfer_byte(8'hff, rx_byte);
        if (rx_byte != 8'h00) begin
            $display("FAIL: zero-length response status");
            $fatal;
        end
        spi_transfer_byte(8'hff, rx_byte);
        spi_transfer_byte(8'hff, rx_byte);
        spi_transfer_byte(8'hff, rx_byte);
        spi_csn = 1;

        #200;
        if (request_count != 2) begin
            $display("FAIL: request_count=%0d", request_count);
            $fatal;
        end

        $display("PASS: 20 MHz SCLK-domain SPI mailbox and synchronous payload ports");
        $finish;
    end

    initial begin
        #10000000;
        $display("FAIL: SCLK mailbox timeout");
        $fatal;
    end
endmodule
