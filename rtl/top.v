module top (
    input wire clk12, uart_rx,
    output wire uart_tx,
    input wire [3:0] cam_d,
    input wire cam_pclk, cam_vsync, cam_href, cam_int,
    // Arducam B0315 has a 24 MHz oscillator wired directly to this pin.
    input wire cam_xclk,
    output wire cam_trig,
    inout wire cam_scl, cam_sda,
    output wire led_r, led_g, led_b
);
    wire clk, locked;
    SB_PLL40_PAD #(.FEEDBACK_PATH("SIMPLE"), .DIVR(0), .DIVF(63),
        .DIVQ(4), .FILTER_RANGE(1)) pll (
        .PACKAGEPIN(clk12), .PLLOUTGLOBAL(clk), .LOCK(locked),
        .RESETB(1'b1), .BYPASS(1'b0), .EXTFEEDBACK(1'b0),
        .DYNAMICDELAY(8'b0), .LATCHINPUTVALUE(1'b0), .SDI(1'b0), .SCLK(1'b0)
    );
    reg [7:0] reset_pipe = 8'hff;
    always @(posedge clk or negedge locked)
        if (!locked) reset_pipe <= 8'hff;
        else reset_pipe <= {reset_pipe[6:0], 1'b0};
    wire enabled, scl_low, sda_low, cap_busy;
    wire [7:0] flags;
    camera_core core (.clk(clk), .reset(reset_pipe[7]), .uart_rx(uart_rx),
        .uart_tx(uart_tx), .cam_d(cam_d), .cam_pclk(cam_pclk), .cam_vsync(cam_vsync),
        .cam_href(cam_href), .cam_int(cam_int), .scl_in(cam_scl), .sda_in(cam_sda),
        .scl_low(scl_low), .sda_low(sda_low), .enabled(enabled),
        .capture_busy(cap_busy), .capture_flags(flags));
    assign cam_trig = 0;
    assign cam_scl = enabled && scl_low ? 1'b0 : 1'bz;
    assign cam_sda = enabled && sda_low ? 1'b0 : 1'bz;
    assign led_r = !(|flags);
    assign led_g = !enabled;
    assign led_b = !cap_busy;
endmodule
