`timescale 1ns/1ps

module tb_sd_native_block_device_write_batch;
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
    reg data_tx_done_override = 0;
    integer data_blocks = 0;

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
            dut.rca = 16'h1234;
            data_blocks = 0;
        end
    endtask

    task start_write;
        input [31:0] lba;
        input [5:0] count;
        begin
            @(negedge clk);
            request_lba = lba;
            request_block_count = count;
            write_request = 1;
            @(negedge clk);
            write_request = 0;
        end
    endtask

    task complete_command;
        input [5:0] expected_state;
        input [5:0] expected_command;
        input [31:0] expected_argument;
        begin
            wait (dut.state == expected_state);
            if (dut.command_index != expected_command ||
                dut.command_argument != expected_argument) begin
                $display("FAIL: state %0d got CMD%0d/%08x expected CMD%0d/%08x",
                         expected_state, dut.command_index,
                         dut.command_argument, expected_command,
                         expected_argument);
                $fatal;
            end
            @(negedge clk);
            command_done_override = 1;
            @(negedge clk);
            command_done_override = 0;
        end
    endtask

    task complete_data_block;
        begin
            wait (dut.state == 6'd32);
            @(negedge clk);
            data_tx_done_override = 1;
            @(negedge clk);
            data_tx_done_override = 0;
            data_blocks = data_blocks + 1;
        end
    endtask

    initial begin
        force dut.command_busy = 1'b0;
        force dut.command_done = command_done_override;
        force dut.command_timeout = 1'b0;
        force dut.data_tx_busy = 1'b0;
        force dut.data_tx_done = data_tx_done_override;
        force dut.data_tx_accepted = 1'b1;
        force dut.data_tx_response_error = 1'b0;

        #100;
        prepare_card();

        // Single-sector writes use CMD24 and do not issue CMD12.
        start_write(32'h0000_0400, 6'd1);
        complete_command(6'd30, 6'd24, 32'h0000_0400);
        complete_data_block();
        repeat (2) @(posedge clk);
        if (operation_busy || error || data_blocks != 1) begin
            $display("FAIL: single write completion");
            $fatal;
        end

        // Multi-sector writes pre-erase, issue one CMD25, transmit all data
        // blocks, and stop with CMD12.
        prepare_card();
        start_write(32'h0001_0000, 6'd3);
        complete_command(6'd35, 6'd55, 32'h1234_0000);
        complete_command(6'd37, 6'd23, 32'd3);
        complete_command(6'd30, 6'd25, 32'h0001_0000);
        complete_data_block();
        complete_data_block();
        complete_data_block();
        complete_command(6'd39, 6'd12, 32'd0);
        repeat (3) @(posedge clk);

        if (operation_busy || error || data_blocks != 3 ||
            dut.active_block_index != 6'd2 ||
            dut.state != 6'd25) begin
            $display("FAIL: multi write busy=%0d error=%0d blocks=%0d index=%0d state=%0d",
                     operation_busy, error, data_blocks,
                     dut.active_block_index, dut.state);
            $fatal;
        end

        $display("PASS: CMD24 and ACMD23/CMD25/CMD12 write sequences");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: write batch state-machine timeout state=%0d",
                 dut.state);
        $fatal;
    end
endmodule
