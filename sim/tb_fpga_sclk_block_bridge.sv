`timescale 1ns/1ps

module tb_fpga_sclk_block_bridge;
    reg clk = 0;
    always #10.416 clk = ~clk;

    reg rst = 0;
    reg spi_csn = 1;
    reg spi_sclk = 0;
    reg spi_mosi = 1;
    wire spi_miso;

    reg card_ready = 1;
    reg card_sdhc = 1;
    reg card_busy = 0;
    reg card_read_ready = 0;
    reg [31:0] capacity_blocks = 32'h0100_0000;
    reg card_error = 0;
    reg [7:0] card_error_code = 0;

    wire read_request;
    wire write_request;
    wire [31:0] request_lba;
    wire [5:0] request_block_count;
    reg model_read_active = 0;
    reg [13:0] model_read_index = 0;
    reg [7:0] model_read_seed = 0;
    wire read_buffer_we = model_read_active;
    wire [13:0] read_buffer_addr = model_read_index;
    wire [7:0] read_buffer_data =
        model_read_index[7:0] ^ {2'd0, model_read_index[13:8]} ^
        8'h5a ^ model_read_seed;
    reg [13:0] write_buffer_addr = 0;
    wire [7:0] write_buffer_data;

    wire debug_cs_seen;
    wire debug_sclk_seen;
    wire debug_request_seen;
    wire debug_response_seen;

    integer read_request_count = 0;
    integer write_request_count = 0;
    reg [31:0] captured_write_lba;
    reg [5:0] captured_write_blocks;
    integer i;
    integer scan;
    reg [7:0] rx_byte;
    reg [7:0] response_status;
    reg [15:0] response_length;
    reg [7:0] response_check;
    reg [31:0] crc;
    reg [31:0] received_crc;

    fpga_sclk_block_bridge dut (
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
        .read_buffer_we(read_buffer_we),
        .read_buffer_addr(read_buffer_addr),
        .read_buffer_data(read_buffer_data),
        .write_buffer_addr(write_buffer_addr),
        .write_buffer_data(write_buffer_data),
        .debug_cs_seen(debug_cs_seen),
        .debug_sclk_seen(debug_sclk_seen),
        .debug_request_seen(debug_request_seen),
        .debug_response_seen(debug_response_seen)
    );

    always @(posedge clk) begin
        if (read_request) begin
            read_request_count <= read_request_count + 1;
            model_read_active <= 1;
            model_read_index <= 0;
            model_read_seed <= request_lba[7:0];
            card_busy <= 1;
            card_read_ready <= 0;
        end else if (model_read_active) begin
            if (model_read_index == 14'd1023) begin
                model_read_active <= 0;
                card_busy <= 0;
                card_read_ready <= 1;
            end else begin
                model_read_index <= model_read_index + 14'd1;
            end
        end
        if (write_request) begin
            write_request_count <= write_request_count + 1;
            captured_write_lba <= request_lba;
            captured_write_blocks <= request_block_count;
        end
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

    task spi_transfer_byte;
        input [7:0] value;
        output [7:0] received;
        integer bit_index;
        reg sampled_miso;
        begin
            received = 0;
            for (bit_index = 7; bit_index >= 0;
                 bit_index = bit_index - 1) begin
                spi_mosi = value[bit_index];
                #25;
                sampled_miso = spi_miso;
                received = {received[6:0], sampled_miso};
                spi_sclk = 1;
                #1;
                if (spi_miso != sampled_miso) begin
                    $display("FAIL: MISO changed inside rising-edge hold window");
                    $fatal;
                end
                #24;
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

    task receive_header;
        integer magic_scan;
        begin
            rx_byte = 0;
            magic_scan = 0;
            while (rx_byte != 8'h5a && magic_scan < 16) begin
                spi_transfer_byte(8'hff, rx_byte);
                magic_scan = magic_scan + 1;
            end
            if (rx_byte != 8'h5a) begin
                $display("FAIL: response magic not found control=%0d sent=%0d grant=%0d banks=%0d/%0d req_valid=%0d rsp_valid=%0d rsp_ready=%0d",
                         dut.control_state, dut.acquire_sent,
                         dut.producer_grant, dut.bank0_state,
                         dut.bank1_state, dut.sys_request_valid,
                         dut.sys_response_valid, dut.sys_response_ready);
                $fatal;
            end
            spi_transfer_byte(8'hff, response_status);
            spi_transfer_byte(8'hff, rx_byte);
            response_length[7:0] = rx_byte;
            spi_transfer_byte(8'hff, rx_byte);
            response_length[15:8] = rx_byte;
            spi_transfer_byte(8'hff, response_check);
            if (response_check !=
                (8'h5a ^ response_status ^
                 response_length[7:0] ^ response_length[15:8])) begin
                $display("FAIL: response header checksum");
                $fatal;
            end
        end
    endtask

    task finish_transaction;
        begin
            spi_csn = 1;
            #200;
            spi_csn = 0;
        end
    endtask

    initial begin
        #20;
        rst = 1;
        #100;
        rst = 0;
        #100;

        // Start a two-block read. The controller must grant a buffer bank.
        spi_csn = 0;
        send_header(8'h03, 32'h0001_2000, 16'd1024);
        receive_header();
        if (response_status != 0 || response_length != 0) begin
            $display("FAIL: READ_START response status=%0d len=%0d",
                     response_status, response_length);
            $fatal;
        end
        if (read_request_count != 1 ||
            request_lba != 32'h0001_2000 ||
            request_block_count != 6'd2) begin
            $display("FAIL: SD request count=%0d lba=%08x blocks=%0d",
                     read_request_count, request_lba,
                     request_block_count);
            $fatal;
        end
        finish_transaction();

        wait (card_read_ready);
        repeat (8) @(posedge clk);

        // STATUS is an inline descriptor payload, not a RAM data crossing.
        send_header(8'h02, 32'd0, 16'd0);
        receive_header();
        if (response_status != 2 || response_length != 8) begin
            $display("FAIL: STATUS response status=%0d len=%0d",
                     response_status, response_length);
            $fatal;
        end
        crc = 32'hffff_ffff;
        for (i = 0; i < 8; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            if (i == 0 && rx_byte != 8'h09) begin
                $display("FAIL: STATUS flags=%02x", rx_byte);
                $fatal;
            end
            crc = crc32_byte(crc, rx_byte);
        end
        received_crc = 0;
        for (i = 0; i < 4; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            received_crc = received_crc | (rx_byte << (8 * i));
        end
        if (received_crc != (crc ^ 32'hffff_ffff)) begin
            $display("FAIL: STATUS CRC got=%08x expected=%08x",
                     received_crc, crc ^ 32'hffff_ffff);
            $fatal;
        end
        finish_transaction();

        // Queue a second SD read into the free bank before consuming the
        // first. Its fill must overlap the first bank's SPI transfer.
        send_header(8'h03, 32'h0001_20a5, 16'd1024);
        receive_header();
        if (response_status != 0 || response_length != 0) begin
            $display("FAIL: overlapped READ_START status=%0d len=%0d",
                     response_status, response_length);
            $fatal;
        end
        finish_transaction();

        // READ_DATA transfers bank ownership to the SCLK consumer even while
        // the SD controller is filling the other bank.
        send_header(8'h04, 32'd0, 16'd0);
        receive_header();
        if (response_status != 0 || response_length != 1024) begin
            $display("FAIL: READ_DATA response status=%0d len=%0d",
                     response_status, response_length);
            $fatal;
        end
        crc = 32'hffff_ffff;
        for (i = 0; i < 1024; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            if (rx_byte !=
                (i[7:0] ^ {2'd0, i[13:8]} ^ 8'h5a)) begin
                $display("FAIL: READ_DATA[%0d]=%02x", i, rx_byte);
                $fatal;
            end
            crc = crc32_byte(crc, rx_byte);
        end
        received_crc = 0;
        for (i = 0; i < 4; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            received_crc = received_crc | (rx_byte << (8 * i));
        end
        if (received_crc != (crc ^ 32'hffff_ffff)) begin
            $display("FAIL: READ_DATA CRC got=%08x expected=%08x",
                     received_crc, crc ^ 32'hffff_ffff);
            $fatal;
        end
        spi_csn = 1;
        #500;

        wait (card_read_ready);
        repeat (8) @(posedge clk);
        spi_csn = 0;
        send_header(8'h04, 32'd0, 16'd0);
        receive_header();
        if (response_status != 0 || response_length != 1024) begin
            $display("FAIL: second READ_DATA status=%0d len=%0d",
                     response_status, response_length);
            $fatal;
        end
        crc = 32'hffff_ffff;
        for (i = 0; i < 1024; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            if (rx_byte !=
                (i[7:0] ^ {2'd0, i[13:8]} ^ 8'h5a ^ 8'ha5)) begin
                $display("FAIL: second READ_DATA[%0d]=%02x", i, rx_byte);
                $fatal;
            end
            crc = crc32_byte(crc, rx_byte);
        end
        received_crc = 0;
        for (i = 0; i < 4; i = i + 1) begin
            spi_transfer_byte(8'hff, rx_byte);
            received_crc = received_crc | (rx_byte << (8 * i));
        end
        if (received_crc != (crc ^ 32'hffff_ffff)) begin
            $display("FAIL: second READ_DATA CRC");
            $fatal;
        end
        spi_csn = 1;
        #500;

        if (dut.bank0_state != 2'd0 || dut.bank1_state != 2'd0) begin
            $display("FAIL: buffer ownership not released bank0=%0d bank1=%0d",
                     dut.bank0_state, dut.bank1_state);
            $fatal;
        end

        // The SCLK request payload must cross through the 16 KiB write RAM
        // before the system domain pulses write_request.
        spi_csn = 0;
        send_header(8'h05, 32'h0004_0000, 16'd512);
        crc = 32'hffff_ffff;
        for (i = 0; i < 512; i = i + 1) begin
            rx_byte = i[7:0] ^ 8'hc3;
            crc = crc32_byte(crc, rx_byte);
            spi_transfer_byte(rx_byte, response_check);
        end
        crc = crc ^ 32'hffff_ffff;
        for (i = 0; i < 4; i = i + 1)
            spi_transfer_byte(crc >> (8 * i), response_check);
        receive_header();
        if (response_status != 0 || response_length != 0) begin
            $display("FAIL: WRITE_DATA status=%0d len=%0d",
                     response_status, response_length);
            $fatal;
        end
        finish_transaction();
        repeat (4) @(posedge clk);
        if (write_request_count != 1 ||
            captured_write_lba != 32'h0004_0000 ||
            captured_write_blocks != 6'd1) begin
            $display("FAIL: write request count=%0d lba=%08x blocks=%0d",
                     write_request_count, captured_write_lba,
                     captured_write_blocks);
            $fatal;
        end
        for (i = 0; i < 512; i = i + 1) begin
            @(negedge clk);
            write_buffer_addr = i[13:0];
            @(posedge clk);
            #1;
            if (write_buffer_data != (i[7:0] ^ 8'hc3)) begin
                $display("FAIL: write RAM[%0d]=%02x",
                         i, write_buffer_data);
                $fatal;
            end
        end
        spi_csn = 1;

        if (!debug_cs_seen || !debug_sclk_seen ||
            !debug_request_seen || !debug_response_seen) begin
            $display("FAIL: debug markers were not all observed");
            $fatal;
        end

        $display("PASS: overlapped reads and SCLK-to-SD write payload");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: integrated SCLK bridge timeout");
        $fatal;
    end
endmodule
