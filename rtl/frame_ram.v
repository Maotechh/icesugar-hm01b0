module frame_ram (
    input wire clk, we,
    input wire [16:0] address,
    input wire [7:0] din,
    output wire [7:0] dout
);
`ifdef CXXRTL
    reg [7:0] memory [0:131071];
    reg [7:0] q;
    always @(posedge clk) begin
        if (we) memory[address] <= din;
        q <= memory[address];
    end
    assign dout = q;
`else
    wire [15:0] q[0:3];
    reg [1:0] bank;
    reg lane;
    always @(posedge clk) begin
        bank <= address[16:15];
        lane <= address[0];
    end
    genvar i;
    generate for (i=0; i<4; i=i+1) begin: ram
        SB_SPRAM256KA block (
            .CLOCK(clk), .ADDRESS(address[14:1]), .DATAIN({din, din}),
            .MASKWREN(address[0] ? 4'b1100 : 4'b0011),
            .WREN(we && address[16:15] == i), .CHIPSELECT(1'b1),
            .STANDBY(1'b0), .SLEEP(1'b0), .POWEROFF(1'b1), .DATAOUT(q[i])
        );
    end endgenerate
    assign dout = lane ? q[bank][15:8] : q[bank][7:0];
`endif
endmodule
