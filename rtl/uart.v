module uart #(
    parameter DIV = 416
) (
    input wire clk, reset,
    input wire rx,
    output wire tx,
    output reg [7:0] rx_data,
    output reg rx_valid, rx_error,
    input wire [7:0] tx_data,
    input wire tx_valid,
    output wire tx_ready
);
    (* async_reg = "true" *) reg [2:0] rx_sync = 3'b111;
    localparam TIMER_BITS = $clog2(DIV);
    reg [TIMER_BITS-1:0] rx_timer = 0, tx_timer = 0;
    // Parallel borrow terms avoid a fragmented carry chain on UP5K.
    wire [TIMER_BITS-1:0] rx_decrement, tx_decrement;
    assign rx_decrement[0] = !rx_timer[0];
    assign tx_decrement[0] = !tx_timer[0];
    genvar i;
    generate for (i = 1; i < TIMER_BITS; i = i + 1) begin: timer_borrow
        assign rx_decrement[i] = rx_timer[i] ^ (~|rx_timer[i-1:0]);
        assign tx_decrement[i] = tx_timer[i] ^ (~|tx_timer[i-1:0]);
    end endgenerate
    reg [3:0] rx_bit = 0, tx_left = 0;
    reg [7:0] rx_shift = 0;
    reg [9:0] tx_shift = 10'h3ff;
    reg rx_busy = 0;
    reg rx_zero = 1, tx_zero = 1;
    assign tx = tx_shift[0];
    assign tx_ready = (tx_left == 0);
    always @(posedge clk) begin
        rx_sync <= {rx_sync[1:0], rx};
        rx_valid <= 0;
        rx_error <= 0;
        rx_data <= rx_shift;
        if (reset) begin
            rx_busy <= 0;
            tx_left <= 0;
            tx_shift <= 10'h3ff;
        end else begin
            if (tx_ready) begin
                if (tx_valid) begin
                    tx_shift <= {1'b1, tx_data, 1'b0};
                    tx_left <= 10;
                    tx_timer <= DIV - 1;
                    tx_zero <= 0;
                end
            end else if (tx_zero) begin
                tx_shift <= {1'b1, tx_shift[9:1]};
                tx_left <= tx_left - 1'b1;
                tx_timer <= DIV - 1;
                tx_zero <= 0;
            end else begin
                tx_timer <= tx_decrement;
                tx_zero <= tx_timer == 1;
            end
            if (!rx_busy) begin
                if (!rx_sync[2]) begin
                    rx_busy <= 1;
                    rx_bit <= 0;
                    rx_timer <= DIV / 2 - 1;
                    rx_zero <= 0;
                end
            end else if (!rx_zero) begin
                rx_timer <= rx_decrement;
                rx_zero <= rx_timer == 1;
            end
            else begin
                rx_timer <= DIV - 1;
                rx_zero <= 0;
                if (rx_bit == 0) begin
                    if (rx_sync[2]) rx_busy <= 0;
                    else rx_bit <= 1;
                end else if (rx_bit == 9) begin
                    rx_busy <= 0;
                    if (rx_sync[2]) begin
                        rx_valid <= 1;
                    end else rx_error <= 1;
                end else begin
                    rx_shift <= {rx_sync[2], rx_shift[7:1]};
                    rx_bit <= rx_bit + 1'b1;
                end
            end
        end
    end
endmodule
