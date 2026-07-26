`timescale 1ns/1ps
`default_nettype none

/*
 * Two-bank producer/consumer ownership controller.
 *
 * Typical read path:
 *   FREE -> SD_FILLING -> READY -> SPI_SENDING -> FREE
 *
 * All state lives in sys_clk. Only the selected bank bit crosses to the SCLK
 * domain as part of the stable response descriptor.
 */
module ping_pong_owner (
    input  wire       clk,
    input  wire       rst,

    input  wire       producer_acquire,
    output reg        producer_grant,
    output reg        producer_bank,
    input  wire       producer_commit,
    input  wire       producer_commit_bank,

    input  wire       consumer_acquire,
    output reg        consumer_grant,
    output reg        consumer_bank,
    input  wire       consumer_release,
    input  wire       consumer_release_bank,

    output wire [1:0] bank0_state,
    output wire [1:0] bank1_state
);
    localparam [1:0]
        OWNER_FREE = 2'd0,
        OWNER_PRODUCER = 2'd1,
        OWNER_READY = 2'd2,
        OWNER_CONSUMER = 2'd3;

    reg [1:0] state [0:1];
    reg next_producer_bank;
    reg next_consumer_bank;

    assign bank0_state = state[0];
    assign bank1_state = state[1];

    always @(posedge clk) begin
        producer_grant <= 1'b0;
        consumer_grant <= 1'b0;

        if (rst) begin
            state[0] <= OWNER_FREE;
            state[1] <= OWNER_FREE;
            producer_bank <= 1'b0;
            consumer_bank <= 1'b0;
            next_producer_bank <= 1'b0;
            next_consumer_bank <= 1'b0;
        end else begin
            if (producer_commit &&
                state[producer_commit_bank] == OWNER_PRODUCER)
                state[producer_commit_bank] <= OWNER_READY;

            if (consumer_release &&
                state[consumer_release_bank] == OWNER_CONSUMER)
                state[consumer_release_bank] <= OWNER_FREE;

            if (producer_acquire) begin
                if (state[next_producer_bank] == OWNER_FREE) begin
                    state[next_producer_bank] <= OWNER_PRODUCER;
                    producer_bank <= next_producer_bank;
                    producer_grant <= 1'b1;
                    next_producer_bank <= ~next_producer_bank;
                end else if (state[~next_producer_bank] == OWNER_FREE) begin
                    state[~next_producer_bank] <= OWNER_PRODUCER;
                    producer_bank <= ~next_producer_bank;
                    producer_grant <= 1'b1;
                    next_producer_bank <= next_producer_bank;
                end
            end

            if (consumer_acquire) begin
                if (state[next_consumer_bank] == OWNER_READY) begin
                    state[next_consumer_bank] <= OWNER_CONSUMER;
                    consumer_bank <= next_consumer_bank;
                    consumer_grant <= 1'b1;
                    next_consumer_bank <= ~next_consumer_bank;
                end else if (state[~next_consumer_bank] == OWNER_READY) begin
                    state[~next_consumer_bank] <= OWNER_CONSUMER;
                    consumer_bank <= ~next_consumer_bank;
                    consumer_grant <= 1'b1;
                    next_consumer_bank <= next_consumer_bank;
                end
            end
        end
    end
endmodule

`default_nettype wire
