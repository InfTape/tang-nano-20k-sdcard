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
    reg [3:0] request_block_count = 1;
    reg [11:0] host_buffer_addr = 0;
    wire [7:0] host_buffer_rdata;
    wire [11:0] write_buffer_addr;
    reg [7:0] write_buffer_data = 0;
    wire card_ready;
    wire card_sdhc;
    wire operation_busy;
    wire read_ready;
    wire [31:0] capacity_blocks;
    wire error;
    wire [7:0] error_code;

    reg command_done_override = 0;
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
        .host_buffer_addr(host_buffer_addr),
        .host_buffer_rdata(host_buffer_rdata),
        .write_buffer_addr(write_buffer_addr),
        .write_buffer_data(write_buffer_data),
        .card_ready(card_ready), .card_sdhc(card_sdhc),
        .operation_busy(operation_busy), .read_ready(read_ready),
        .capacity_blocks(capacity_blocks),
        .error(error), .error_code(error_code)
    );

    task complete_command;
        input [31:0] expected_argument;
        begin
            wait (dut.state == 6'd27);
            if (dut.command_index != 6'd17 ||
                dut.command_argument != expected_argument) begin
                $display("FAIL: CMD17 argument got=%08x expected=%08x",
                         dut.command_argument, expected_argument);
                $fatal;
            end
            @(negedge clk);
            command_done_override = 1;
            @(negedge clk);
            command_done_override = 0;
        end
    endtask

    task complete_block;
        begin
            wait (dut.state == 6'd28);
            @(negedge clk);
            block_done_override = 1;
            @(negedge clk);
            block_done_override = 0;
        end
    endtask

    initial begin
        force dut.command_busy = 1'b0;
        force dut.command_done = command_done_override;
        force dut.command_timeout = 1'b0;
        force dut.block_done = block_done_override;
        force dut.block_crc_error = block_crc_error_override;

        #100;
        rst = 0;
        @(negedge clk);
        dut.state = 6'd25;
        dut.fast_clock = 1'b1;
        dut.card_ready = 1'b1;
        dut.card_sdhc = 1'b1;
        dut.capacity_blocks = 32'h0010_0000;

        request_lba = 32'h0001_2340;
        request_block_count = 4'd3;
        read_request = 1;
        @(negedge clk);
        read_request = 0;

        complete_command(32'h0001_2340);
        complete_block();
        complete_command(32'h0001_2341);
        complete_block();
        complete_command(32'h0001_2342);
        complete_block();

        repeat (2) @(posedge clk);
        if (!read_ready || operation_busy || error ||
            dut.active_block_index != 4'd2 ||
            dut.active_block_count != 4'd3) begin
            $display("FAIL: batch completion ready=%0d busy=%0d error=%0d index=%0d count=%0d",
                     read_ready, operation_busy, error,
                     dut.active_block_index, dut.active_block_count);
            $fatal;
        end

        $display("PASS: three-block read issues sequential CMD17 arguments");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: read batch state-machine timeout");
        $fatal;
    end
endmodule
