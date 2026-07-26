`timescale 1ns/1ps

module tb_sd_native_data_rx_multiblock;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg enable = 0;
    reg sd_rise = 0;
    reg [3:0] sd_dat = 4'hf;

    wire block_start;
    wire block_done;
    wire block_crc_error;
    wire [7:0] data_byte;
    wire data_valid;

    integer received_bytes = 0;
    integer completed_blocks = 0;
    reg [7:0] expected_byte;

    sd_native_data_rx dut (
        .clk(clk), .rst(rst), .enable(enable),
        .sd_rise(sd_rise), .sd_dat(sd_dat),
        .block_start(block_start), .block_done(block_done),
        .block_crc_error(block_crc_error),
        .data_byte(data_byte), .data_valid(data_valid)
    );

    function [15:0] crc16_next;
        input [15:0] crc;
        input value;
        reg feedback;
        begin
            feedback = crc[15] ^ value;
            crc16_next = {crc[14:0], 1'b0};
            if (feedback)
                crc16_next = crc16_next ^ 16'h1021;
        end
    endfunction

    task pulse_nibble;
        input [3:0] value;
        begin
            @(negedge clk);
            sd_dat = value;
            sd_rise = 1;
            @(negedge clk);
            sd_rise = 0;
        end
    endtask

    task send_block;
        input [7:0] seed;
        integer byte_index;
        integer crc_index;
        reg [7:0] value;
        reg [3:0] nibble;
        reg [15:0] crc0;
        reg [15:0] crc1;
        reg [15:0] crc2;
        reg [15:0] crc3;
        begin
            crc0 = 0;
            crc1 = 0;
            crc2 = 0;
            crc3 = 0;
            pulse_nibble(4'h0);
            for (byte_index = 0; byte_index < 512;
                 byte_index = byte_index + 1) begin
                value = byte_index[7:0] ^ seed;

                nibble = value[7:4];
                crc0 = crc16_next(crc0, nibble[0]);
                crc1 = crc16_next(crc1, nibble[1]);
                crc2 = crc16_next(crc2, nibble[2]);
                crc3 = crc16_next(crc3, nibble[3]);
                pulse_nibble(nibble);

                nibble = value[3:0];
                crc0 = crc16_next(crc0, nibble[0]);
                crc1 = crc16_next(crc1, nibble[1]);
                crc2 = crc16_next(crc2, nibble[2]);
                crc3 = crc16_next(crc3, nibble[3]);
                pulse_nibble(nibble);
            end
            for (crc_index = 15; crc_index >= 0;
                 crc_index = crc_index - 1)
                pulse_nibble({crc3[crc_index], crc2[crc_index],
                              crc1[crc_index], crc0[crc_index]});
            pulse_nibble(4'hf);
        end
    endtask

    always @(posedge clk) begin
        if (data_valid) begin
            expected_byte = received_bytes[7:0] ^
                (received_bytes < 512 ? 8'ha5 : 8'h5a);
            if (data_byte !== expected_byte) begin
                $display("FAIL: byte %0d got=%02x expected=%02x",
                         received_bytes, data_byte, expected_byte);
                $fatal;
            end
            received_bytes = received_bytes + 1;
        end
        if (block_done) begin
            if (block_crc_error) begin
                $display("FAIL: CRC error on block %0d", completed_blocks);
                $fatal;
            end
            completed_blocks = completed_blocks + 1;
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        enable = 1;

        send_block(8'ha5);
        send_block(8'h5a);
        repeat (4) @(posedge clk);

        if (received_bytes != 1024 || completed_blocks != 2) begin
            $display("FAIL: bytes=%0d blocks=%0d",
                     received_bytes, completed_blocks);
            $fatal;
        end

        $display("PASS: two consecutive native-SD blocks and lane CRC16");
        $finish;
    end

    initial begin
        #1000000;
        $display("FAIL: multi-block data receiver timeout");
        $fatal;
    end
endmodule
