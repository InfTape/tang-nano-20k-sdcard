`timescale 1ns/1ps

module tb_sd_native_block_device_read_batch;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    wire sd_clk;
    reg sd_cmd_in = 1;
    wire sd_cmd_out;
    wire sd_cmd_oe;
    reg [3:0] sd_dat_in = 4'hf;
    wire [3:0] sd_dat_out;
    wire sd_dat_oe;

    reg read_request = 0;
    reg write_request = 0;
    reg [31:0] request_lba = 0;
    reg [5:0] request_block_count = 1;
    wire read_buffer_we;
    wire [13:0] read_buffer_addr;
    wire [7:0] read_buffer_data;
    wire [13:0] write_buffer_addr;
    reg [7:0] write_buffer_data = 0;
    wire card_ready;
    wire card_sdhc;
    wire operation_busy;
    wire read_ready;
    wire [31:0] capacity_blocks;
    wire error;
    wire [7:0] error_code;

    reg command_done_override = 0;
    reg command_timeout_override = 0;
    reg block_done_override = 0;
    reg block_crc_error_override = 0;

    sd_native_block_device dut (
        .clk(clk), .rst(rst),
        .sd_clk(sd_clk),
        .sd_cmd_in(sd_cmd_in), .sd_cmd_out(sd_cmd_out),
        .sd_cmd_oe(sd_cmd_oe),
        .sd_dat_in(sd_dat_in), .sd_dat_out(sd_dat_out),
        .sd_dat_oe(sd_dat_oe),
        .read_request(read_request), .write_request(write_request),
        .request_lba(request_lba),
        .request_block_count(request_block_count),
        .read_buffer_we(read_buffer_we),
        .read_buffer_addr(read_buffer_addr),
        .read_buffer_data(read_buffer_data),
        .write_buffer_addr(write_buffer_addr),
        .write_buffer_data(write_buffer_data),
        .card_ready(card_ready), .card_sdhc(card_sdhc),
        .operation_busy(operation_busy), .read_ready(read_ready),
        .capacity_blocks(capacity_blocks),
        .error(error), .error_code(error_code)
    );

    task complete_command;
        input [5:0] expected_state;
        input [5:0] expected_command;
        input [31:0] expected_argument;
        begin
            wait (dut.state == expected_state);
            if (dut.command_index != expected_command ||
                dut.command_argument != expected_argument) begin
                $display("FAIL: command got CMD%0d/%08x expected CMD%0d/%08x",
                         dut.command_index, dut.command_argument,
                         expected_command, expected_argument);
                $fatal;
            end
            @(negedge clk);
            command_done_override = 1;
            @(negedge clk);
            command_done_override = 0;
        end
    endtask

    task complete_block;
        input crc_error;
        begin
            wait (dut.state == 6'd28);
            @(negedge clk);
            block_crc_error_override = crc_error;
            block_done_override = 1;
            @(negedge clk);
            block_done_override = 0;
            block_crc_error_override = 0;
        end
    endtask

    task complete_stop_with_timeout;
        begin
            wait (dut.state == 6'd42);
            if (dut.command_index != 6'd12 ||
                dut.command_argument != 32'd0) begin
                $display("FAIL: stop command got CMD%0d/%08x",
                         dut.command_index, dut.command_argument);
                $fatal;
            end
            @(negedge clk);
            command_timeout_override = 1;
            command_done_override = 1;
            @(negedge clk);
            command_done_override = 0;
            command_timeout_override = 0;
        end
    endtask

    task prepare_card;
        begin
            rst = 1;
            repeat (3) @(negedge clk);
            rst = 0;
            dut.state = 6'd25;
            dut.fast_clock = 1'b1;
            dut.card_ready = 1'b1;
            dut.card_sdhc = 1'b1;
            dut.capacity_blocks = 32'h0010_0000;
        end
    endtask

    task start_read;
        input [31:0] lba;
        input [5:0] count;
        begin
            @(negedge clk);
            request_lba = lba;
            request_block_count = count;
            read_request = 1;
            @(negedge clk);
            read_request = 0;
        end
    endtask

    initial begin
        force dut.command_busy = 1'b0;
        force dut.command_done = command_done_override;
        force dut.command_timeout = command_timeout_override;
        force dut.block_done = block_done_override;
        force dut.block_crc_error = block_crc_error_override;

        #100;
        prepare_card();

        // A single-block request remains CMD17 and needs no CMD12.
        start_read(32'h0000_0100, 6'd1);

        complete_command(6'd27, 6'd17, 32'h0000_0100);
        complete_block(1'b0);

        repeat (2) @(posedge clk);
        if (!read_ready || operation_busy || error ||
            dut.active_block_index != 6'd0) begin
            $display("FAIL: single-block CMD17 completion");
            $fatal;
        end

        // A multi-block request issues one CMD18, receives consecutive data
        // blocks, then terminates the stream with CMD12.
        start_read(32'h0001_2340, 6'd3);

        complete_command(6'd27, 6'd18, 32'h0001_2340);
        complete_block(1'b0);
        complete_block(1'b0);
        complete_block(1'b0);
        complete_command(6'd42, 6'd12, 32'd0);

        repeat (2) @(posedge clk);
        if (!read_ready || operation_busy || error ||
            dut.active_block_index != 6'd2 ||
            dut.active_block_count != 6'd3) begin
            $display("FAIL: batch completion ready=%0d busy=%0d error=%0d index=%0d count=%0d",
                     read_ready, operation_busy, error,
                     dut.active_block_index, dut.active_block_count);
            $fatal;
        end

        // CRC failure during CMD18 must still send CMD12 before reporting the
        // original data error.
        prepare_card();
        start_read(32'h0002_0000, 6'd2);

        complete_command(6'd27, 6'd18, 32'h0002_0000);
        complete_block(1'b0);
        complete_block(1'b1);
        complete_command(6'd42, 6'd12, 32'd0);

        repeat (2) @(posedge clk);
        if (!error || error_code != 8'h13 || operation_busy ||
            read_ready || dut.state != 6'd33) begin
            $display("FAIL: CRC cleanup error=%0d code=%02x state=%0d",
                     error, error_code, dut.state);
            $fatal;
        end

        // A CMD12 timeout is reported distinctly.
        prepare_card();
        start_read(32'h0003_0000, 6'd2);

        complete_command(6'd27, 6'd18, 32'h0003_0000);
        complete_block(1'b0);
        complete_block(1'b0);
        complete_stop_with_timeout();

        repeat (2) @(posedge clk);
        if (!error || error_code != 8'h1a || operation_busy ||
            read_ready || dut.state != 6'd33) begin
            $display("FAIL: CMD12 timeout error=%0d code=%02x state=%0d",
                     error, error_code, dut.state);
            $fatal;
        end

        $display("PASS: CMD17/CMD18 read, CMD12 cleanup, and errors");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: read batch timeout state=%0d cmd=%0d busy=%0d done=%0d block_done=%0d index=%0d error=%0d/%02x",
                 dut.state, dut.command_index, operation_busy,
                 command_done_override, block_done_override,
                 dut.active_block_index, error, error_code);
        $fatal;
    end
endmodule
