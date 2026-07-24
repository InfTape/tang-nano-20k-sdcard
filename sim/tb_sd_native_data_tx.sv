`timescale 1ns/1ps
`default_nettype none

module tb_sd_native_data_tx;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst = 1'b1;
    logic sd_clk = 1'b0;
    logic sd_rise = 1'b0;
    logic sd_fall = 1'b0;
    logic start = 1'b0;
    logic [31:0] block_seed = 32'h0123_4567;
    tri1 [3:0] sd_dat;
    wire [3:0] host_dat;
    wire host_oe;
    logic [3:0] card_dat = 4'hf;
    logic card_oe = 1'b0;
    wire busy;
    wire done;
    wire accepted;
    wire response_error;

    assign sd_dat = host_oe ? host_dat : 4'bz;
    assign sd_dat = card_oe ? card_dat : 4'bz;

    sd_native_data_tx dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .block_seed(block_seed),
        .use_external_data(1'b0),
        .external_data(8'd0),
        .sd_rise(sd_rise),
        .sd_fall(sd_fall),
        .sd_dat_in(sd_dat),
        .sd_dat_out(host_dat),
        .sd_dat_oe(host_oe),
        .busy(busy),
        .done(done),
        .accepted(accepted),
        .response_error(response_error),
        .data_index()
    );

    // 25 MHz-equivalent SD edges relative to the 100 MHz simulation clock.
    always @(posedge clk) begin
        sd_rise <= 1'b0;
        sd_fall <= 1'b0;
        if (!sd_clk) begin
            sd_clk <= 1'b1;
            sd_rise <= 1'b1;
        end else begin
            sd_clk <= 1'b0;
            sd_fall <= 1'b1;
        end
    end

    function automatic [15:0] crc16_next(
        input [15:0] crc,
        input logic value
    );
        logic feedback;
        begin
            feedback = crc[15] ^ value;
            crc16_next = {crc[14:0], 1'b0};
            if (feedback)
                crc16_next = crc16_next ^ 16'h1021;
        end
    endfunction

    integer phase = 0;
    integer data_nibbles = 0;
    integer crc_bits = 0;
    integer response_phase = 0;
    logic [15:0] crc0 = 16'd0;
    logic [15:0] crc1 = 16'd0;
    logic [15:0] crc2 = 16'd0;
    logic [15:0] crc3 = 16'd0;

    // Observe host data at rising edges.
    always @(posedge clk) begin
        if (sd_rise && host_oe) begin
            case (phase)
                0: begin
                    if (sd_dat == 4'h0) begin
                        phase = 1;
                        data_nibbles = 0;
                    end
                end
                1: begin
                    crc0 = crc16_next(crc0, sd_dat[0]);
                    crc1 = crc16_next(crc1, sd_dat[1]);
                    crc2 = crc16_next(crc2, sd_dat[2]);
                    crc3 = crc16_next(crc3, sd_dat[3]);
                    data_nibbles = data_nibbles + 1;
                    if (data_nibbles == 1024) begin
                        phase = 2;
                        crc_bits = 0;
                    end
                end
                2: begin
                    if (sd_dat !== {crc3[15-crc_bits], crc2[15-crc_bits],
                                    crc1[15-crc_bits], crc0[15-crc_bits]}) begin
                        $display("FAIL: CRC bit %0d", crc_bits);
                        $finish_and_return(1);
                    end
                    crc_bits = crc_bits + 1;
                    if (crc_bits == 16)
                        phase = 3;
                end
                3: begin
                    if (sd_dat != 4'hf) begin
                        $display("FAIL: missing end bit");
                        $finish_and_return(1);
                    end
                    phase = 4;
                end
            endcase
        end
    end

    // Return accepted status 0,010,1 and a short busy interval.
    always @(posedge clk) begin
        if (sd_fall && (phase == 4) && !host_oe) begin
            card_oe <= 1'b1;
            case (response_phase)
                0: card_dat <= 4'b1110; // start
                1: card_dat <= 4'b1110; // status[2]
                2: card_dat <= 4'b1111; // status[1]
                3: card_dat <= 4'b1110; // status[0]
                4: card_dat <= 4'b1111; // end
                5, 6, 7, 8: card_dat <= 4'b1110; // busy
                default: card_dat <= 4'b1111;
            endcase
            response_phase <= response_phase + 1;
        end
    end

    integer timeout;
    initial begin
        repeat (8) @(posedge clk);
        rst <= 1'b0;
        repeat (4) @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        timeout = 0;
        while (!done && timeout < 100000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end

        if (!done || !accepted || response_error ||
            (data_nibbles != 1024)) begin
            $display("FAIL: done=%0d accepted=%0d response_error=%0d nibbles=%0d",
                     done, accepted, response_error, data_nibbles);
            $finish_and_return(1);
        end

        $display("PASS: native 4-bit write block, CRC response, and busy");
        $finish;
    end
endmodule

`default_nettype wire
