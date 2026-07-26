`timescale 1ns/1ps

module tb_ping_pong_buffer;
    reg sys_clk = 0;
    always #10 sys_clk = ~sys_clk;
    reg spi_clk = 0;
    always #25 spi_clk = ~spi_clk;

    reg rst = 1;
    reg producer_acquire = 0;
    wire producer_grant;
    wire producer_bank;
    reg producer_commit = 0;
    reg producer_commit_bank = 0;
    reg consumer_acquire = 0;
    wire consumer_grant;
    wire consumer_bank;
    reg consumer_release = 0;
    reg consumer_release_bank = 0;
    wire [1:0] bank0_state;
    wire [1:0] bank1_state;

    reg [14:0] sys_addr = 0;
    reg sys_we = 0;
    reg [7:0] sys_wdata = 0;
    wire [7:0] sys_rdata;
    reg [14:0] spi_addr = 0;
    wire [7:0] spi_rdata;

    ping_pong_owner owner_i (
        .clk(sys_clk), .rst(rst),
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

    dual_clock_byte_buffer buffer_i (
        .port_a_clk(sys_clk), .port_a_addr(sys_addr),
        .port_a_we(sys_we), .port_a_wdata(sys_wdata),
        .port_a_rdata(sys_rdata),
        .port_b_clk(spi_clk), .port_b_addr(spi_addr),
        .port_b_we(1'b0), .port_b_wdata(8'd0),
        .port_b_rdata(spi_rdata)
    );

    task request_producer;
        input expected_bank;
        begin
            @(negedge sys_clk);
            producer_acquire = 1;
            @(negedge sys_clk);
            producer_acquire = 0;
            if (!producer_grant || producer_bank != expected_bank) begin
                $display("FAIL: producer grant=%0d bank=%0d expected=%0d",
                         producer_grant, producer_bank, expected_bank);
                $fatal;
            end
        end
    endtask

    task commit_producer;
        input bank;
        begin
            @(negedge sys_clk);
            producer_commit_bank = bank;
            producer_commit = 1;
            @(negedge sys_clk);
            producer_commit = 0;
        end
    endtask

    task request_consumer;
        input expected_bank;
        begin
            @(negedge sys_clk);
            consumer_acquire = 1;
            @(negedge sys_clk);
            consumer_acquire = 0;
            if (!consumer_grant || consumer_bank != expected_bank) begin
                $display("FAIL: consumer grant=%0d bank=%0d expected=%0d",
                         consumer_grant, consumer_bank, expected_bank);
                $fatal;
            end
        end
    endtask

    task release_consumer;
        input bank;
        begin
            @(negedge sys_clk);
            consumer_release_bank = bank;
            consumer_release = 1;
            @(negedge sys_clk);
            consumer_release = 0;
        end
    endtask

    task write_byte;
        input bank;
        input [13:0] address;
        input [7:0] value;
        begin
            @(negedge sys_clk);
            sys_addr = {bank, address};
            sys_wdata = value;
            sys_we = 1;
            @(negedge sys_clk);
            sys_we = 0;
        end
    endtask

    task check_spi_byte;
        input bank;
        input [13:0] address;
        input [7:0] expected;
        begin
            @(negedge spi_clk);
            spi_addr = {bank, address};
            @(posedge spi_clk);
            @(negedge spi_clk);
            if (spi_rdata != expected) begin
                $display("FAIL: bank=%0d addr=%0d data=%02x expected=%02x",
                         bank, address, spi_rdata, expected);
                $fatal;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge sys_clk);
        rst = 0;

        request_producer(1'b0);
        write_byte(1'b0, 14'd0, 8'h31);
        write_byte(1'b0, 14'd16383, 8'h7a);
        commit_producer(1'b0);
        request_consumer(1'b0);

        // While SPI owns bank 0, SD can fill bank 1.
        request_producer(1'b1);
        if (bank0_state != 2'd3 || bank1_state != 2'd1) begin
            $display("FAIL: ownership did not overlap bank0=%0d bank1=%0d",
                     bank0_state, bank1_state);
            $fatal;
        end
        write_byte(1'b1, 14'd0, 8'hc4);
        write_byte(1'b1, 14'd16383, 8'he9);
        check_spi_byte(1'b0, 14'd0, 8'h31);
        check_spi_byte(1'b0, 14'd16383, 8'h7a);

        commit_producer(1'b1);
        release_consumer(1'b0);
        request_consumer(1'b1);
        request_producer(1'b0);
        if (bank0_state != 2'd1 || bank1_state != 2'd3) begin
            $display("FAIL: banks did not swap bank0=%0d bank1=%0d",
                     bank0_state, bank1_state);
            $fatal;
        end
        check_spi_byte(1'b1, 14'd0, 8'hc4);
        check_spi_byte(1'b1, 14'd16383, 8'he9);

        $display("PASS: two 16 KiB banks overlap producer and consumer ownership");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: ping-pong buffer timeout");
        $fatal;
    end
endmodule
