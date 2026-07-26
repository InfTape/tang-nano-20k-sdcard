`timescale 1ns/1ps

module tb_fpga_spi_block_bridge;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg spi_csn = 1;
    reg spi_sclk = 0;
    reg spi_mosi = 1;
    wire spi_miso;

    reg card_ready = 1;
    reg card_sdhc = 1;
    reg card_busy = 0;
    reg card_read_ready = 0;
    reg [31:0] capacity_blocks = 32'h0123_4567;
    reg card_error = 0;
    reg [7:0] card_error_code = 0;

    wire read_request;
    wire write_request;
    wire [31:0] request_lba;
    wire [5:0] request_block_count;
    wire [11:0] buffer_addr;
    reg [7:0] memory [0:4095];
    reg [7:0] buffer_rdata;
    reg [13:0] write_buffer_addr = 0;
    wire [7:0] write_buffer_data;

    integer read_pulses = 0;
    integer write_pulses = 0;
    reg [31:0] captured_lba;
    reg [3:0] captured_block_count;

    always @(posedge clk) begin
        buffer_rdata <= memory[buffer_addr];
        if (read_request) begin
            read_pulses <= read_pulses + 1;
            captured_lba <= request_lba;
            captured_block_count <= request_block_count;
        end
        if (write_request) begin
            write_pulses <= write_pulses + 1;
            captured_lba <= request_lba;
            captured_block_count <= request_block_count;
        end
    end

    fpga_spi_block_bridge dut (
        .clk(clk), .rst(rst),
        .spi_csn(spi_csn), .spi_sclk(spi_sclk),
        .spi_mosi(spi_mosi), .spi_miso(spi_miso),
        .card_ready(card_ready), .card_sdhc(card_sdhc),
        .card_busy(card_busy), .card_read_ready(card_read_ready),
        .capacity_blocks(capacity_blocks),
        .card_error(card_error), .card_error_code(card_error_code),
        .read_request(read_request), .write_request(write_request),
        .request_lba(request_lba),
        .request_block_count(request_block_count),
        .buffer_addr(buffer_addr), .buffer_rdata(buffer_rdata),
        .write_buffer_addr(write_buffer_addr),
        .write_buffer_data(write_buffer_data)
    );

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] value;
        integer bit_number;
        reg [31:0] crc;
        begin
            crc = crc_in ^ value;
            for (bit_number = 0; bit_number < 8;
                 bit_number = bit_number + 1)
                crc = (crc >> 1) ^
                      (crc[0] ? 32'hedb8_8320 : 32'd0);
            crc32_byte = crc;
        end
    endfunction

    task spi_send_byte;
        input [7:0] value;
        integer bit_number;
        begin
            for (bit_number = 7; bit_number >= 0;
                 bit_number = bit_number - 1) begin
                spi_mosi = value[bit_number];
                #100;
                spi_sclk = 1;
                #100;
                spi_sclk = 0;
            end
        end
    endtask

    task spi_receive_byte;
        output [7:0] value;
        integer bit_number;
        begin
            value = 0;
            for (bit_number = 7; bit_number >= 0;
                 bit_number = bit_number - 1) begin
                #100;
                spi_sclk = 1;
                #40;
                value[bit_number] = spi_miso;
                #60;
                spi_sclk = 0;
            end
        end
    endtask

    task begin_request;
        input [7:0] command;
        input [31:0] lba;
        input [15:0] length;
        reg [7:0] check;
        begin
            spi_csn = 0;
            spi_mosi = 1;
            #500;
            check = 8'ha5 ^ command ^
                    lba[7:0] ^ lba[15:8] ^ lba[23:16] ^ lba[31:24] ^
                    length[7:0] ^ length[15:8];
            spi_send_byte(8'ha5);
            spi_send_byte(command);
            spi_send_byte(lba[7:0]);
            spi_send_byte(lba[15:8]);
            spi_send_byte(lba[23:16]);
            spi_send_byte(lba[31:24]);
            spi_send_byte(length[7:0]);
            spi_send_byte(length[15:8]);
            spi_send_byte(check);
        end
    endtask

    task receive_header;
        output [7:0] status;
        output [15:0] length;
        reg [7:0] value;
        reg [7:0] check;
        integer scan;
        begin
            #150000;
            value = 0;
            scan = 0;
            while (value != 8'h5a && scan < 8) begin
                spi_receive_byte(value);
                scan = scan + 1;
            end
            if (value != 8'h5a) begin
                $display("FAIL: response magic not found");
                $fatal;
            end
            spi_receive_byte(status);
            spi_receive_byte(length[7:0]);
            spi_receive_byte(length[15:8]);
            spi_receive_byte(check);
            if (check != (8'h5a ^ status ^
                          length[7:0] ^ length[15:8])) begin
                $display("FAIL: response header checksum");
                $fatal;
            end
        end
    endtask

    task end_request;
        begin
            spi_csn = 1;
            spi_sclk = 0;
            spi_mosi = 1;
            #500;
        end
    endtask

    integer i;
    reg [7:0] status;
    reg [15:0] length;
    reg [7:0] value;
    reg [31:0] crc;
    reg [31:0] received_crc;

    initial begin
        for (i = 0; i < 4096; i = i + 1)
            memory[i] = i[7:0] ^ i[11:8] ^ 8'ha5;

        #100;
        rst = 0;
        #500;

        // INFO returns capacity and flags.
        begin_request(8'h01, 0, 0);
        receive_header(status, length);
        if (status != 0 || length != 8) begin
            $display("FAIL: INFO status=%0d length=%0d", status, length);
            $fatal;
        end
        crc = 32'hffff_ffff;
        received_crc = 0;
        for (i = 0; i < 8; i = i + 1) begin
            spi_receive_byte(value);
            crc = crc32_byte(crc, value);
            case (i)
                0: if (value != 8'h67) $fatal;
                1: if (value != 8'h45) $fatal;
                2: if (value != 8'h23) $fatal;
                3: if (value != 8'h01) $fatal;
            endcase
        end
        for (i = 0; i < 4; i = i + 1) begin
            spi_receive_byte(value);
            received_crc = received_crc | (value << (8*i));
        end
        if (received_crc != (crc ^ 32'hffff_ffff)) begin
            $display("FAIL: INFO payload CRC");
            $fatal;
        end
        end_request();

        // READ_START rejects non-sector-aligned transfer lengths.
        begin_request(8'h03, 32'h0012_3456, 16'd513);
        receive_header(status, length);
        end_request();
        if (status != 4 || length != 0 || read_pulses != 0) begin
            $display("FAIL: invalid READ_START length");
            $fatal;
        end

        // A 4 KiB READ_START creates one eight-block request pulse.
        begin_request(8'h03, 32'h0012_3456, 16'd4096);
        receive_header(status, length);
        end_request();
        if (status != 0 || length != 0 || read_pulses != 1 ||
            captured_lba != 32'h0012_3456 ||
            captured_block_count != 8) begin
            $display("FAIL: 4 KiB READ_START");
            $fatal;
        end

        // READ_DATA returns all eight blocks with one transport CRC32.
        card_read_ready = 1;
        begin_request(8'h04, 0, 0);
        receive_header(status, length);
        if (status != 0 || length != 4096) begin
            $display("FAIL: READ_DATA header");
            $fatal;
        end
        crc = 32'hffff_ffff;
        for (i = 0; i < 4096; i = i + 1) begin
            spi_receive_byte(value);
            if (value != (i[7:0] ^ i[11:8] ^ 8'ha5)) begin
                $display("FAIL: READ_DATA byte %0d got=%02x expected=%02x",
                         i, value, (i[7:0] ^ i[11:8] ^ 8'ha5));
                $fatal;
            end
            crc = crc32_byte(crc, value);
        end
        received_crc = 0;
        for (i = 0; i < 4; i = i + 1) begin
            spi_receive_byte(value);
            received_crc = received_crc | (value << (8*i));
        end
        if (received_crc != (crc ^ 32'hffff_ffff)) begin
            $display("FAIL: READ_DATA CRC");
            $fatal;
        end
        end_request();
        card_read_ready = 0;

        // WRITE_DATA is accepted only after all data and CRC32 validate.
        begin_request(8'h05, 32'h0000_4321, 16'd512);
        crc = 32'hffff_ffff;
        for (i = 0; i < 512; i = i + 1) begin
            value = i[7:0] ^ 8'h3c;
            spi_send_byte(value);
            crc = crc32_byte(crc, value);
        end
        crc = crc ^ 32'hffff_ffff;
        spi_send_byte(crc[7:0]);
        spi_send_byte(crc[15:8]);
        spi_send_byte(crc[23:16]);
        spi_send_byte(crc[31:24]);
        receive_header(status, length);
        end_request();
        #500;
        if (status != 0 || length != 0 || write_pulses != 1 ||
            captured_lba != 32'h0000_4321 ||
            captured_block_count != 1) begin
            $display("FAIL: WRITE_DATA request");
            $fatal;
        end
        for (i = 0; i < 512; i = i + 1) begin
            write_buffer_addr = {2'b00, i[11:0]};
            #20;
            if (write_buffer_data != (i[7:0] ^ 8'h3c)) begin
                $display("FAIL: WRITE_DATA buffer byte %0d", i);
                $fatal;
            end
        end

        // A 4096-byte request is exposed as eight contiguous SD blocks.
        begin_request(8'h05, 32'h0001_0000, 16'd4096);
        crc = 32'hffff_ffff;
        for (i = 0; i < 4096; i = i + 1) begin
            value = i[7:0] ^ i[11:8] ^ 8'h69;
            spi_send_byte(value);
            crc = crc32_byte(crc, value);
        end
        crc = crc ^ 32'hffff_ffff;
        spi_send_byte(crc[7:0]);
        spi_send_byte(crc[15:8]);
        spi_send_byte(crc[23:16]);
        spi_send_byte(crc[31:24]);
        receive_header(status, length);
        end_request();
        #500;
        if (status != 0 || length != 0 || write_pulses != 2 ||
            captured_lba != 32'h0001_0000 ||
            captured_block_count != 8) begin
            $display("FAIL: 4 KiB WRITE_DATA request");
            $fatal;
        end
        for (i = 0; i < 4096; i = i + 1) begin
            write_buffer_addr = {2'b00, i[11:0]};
            #20;
            if (write_buffer_data !=
                (i[7:0] ^ i[11:8] ^ 8'h69)) begin
                $display("FAIL: 4 KiB WRITE_DATA buffer byte %0d", i);
                $fatal;
            end
        end

        $display("PASS: BL616 link INFO/4KiB READ/512B+4KiB WRITE and CRC32");
        $finish;
    end
endmodule
