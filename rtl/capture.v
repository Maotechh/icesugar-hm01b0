// Oversampling receiver: 48 MHz system clock, supported PCLK <= 6 MHz.
// Data is sampled one system cycle after the synchronized PCLK edge.
module capture #(
    parameter WIDTH = 324,
    parameter HEIGHT = 244,
    parameter CAPACITY = 131072,
    parameter TIMEOUT = 96000000
) (
    input wire clk, reset, arm,
    input wire msb_first, falling_edge,
    input wire pclk, vsync, href,
    input wire [3:0] data,
    output reg busy, done,
    output reg mem_we,
    output reg [16:0] mem_addr,
    output reg [7:0] mem_data,
    output reg [17:0] bytes_count,
    output reg [15:0] lines_count,
    output reg [15:0] min_line, max_line,
    output reg [7:0] flags,
    output reg [31:0] cycles
);
    initial begin
        busy = 0; done = 0; mem_we = 0; mem_addr = 0; mem_data = 0;
        bytes_count = 0; lines_count = 0; min_line = 16'hffff;
        max_line = 0; flags = 0; cycles = 0;
    end
    (* async_reg = "true" *) reg [3:0] pc = 0, vs = 0, hs = 0;
    (* async_reg = "true" *) reg [3:0] d1 = 0, d2 = 0, d3 = 0;
    reg [2:0] phase = 3'b001;
    reg [15:0] nibbles = 0;
    reg [3:0] first = 0;
    reg half = 0, order = 0, edge_fall = 0;
    reg [7:0] pulse_cycles = 255;
    reg [31:0] elapsed = 0;
    reg expired = 0;
    wire pc_edge = edge_fall ? (!pc[2] && pc[3]) : (pc[2] && !pc[3]);
    wire h_end = !hs[2] && hs[3];
    wire v_end = !vs[2] && vs[3];
    wire starting = phase[1] && vs[2] && !vs[3];
    wire active = phase[2] || starting;
    reg pixel_event = 0, line_event = 0, frame_event = 0;
    reg sample_bad = 0, pulse_bad = 0, sync_bad = 0, frame_bad = 0;
    reg [3:0] pixel_data = 0;
    reg line_pending = 0, finish_pending = 0;
    reg less_min = 0, more_max = 0;
    reg [15:0] line_snapshot = 0;
    function less16;
        input [15:0] a, b;
        begin
            less16 = (a[15:12] < b[15:12]) ||
                (a[15:12] == b[15:12] && a[11:8] < b[11:8]) ||
                (a[15:8] == b[15:8] && a[7:4] < b[7:4]) ||
                (a[15:4] == b[15:4] && a[3:0] < b[3:0]);
        end
    endfunction
    always @(posedge clk) begin
        pc <= {pc[2:0], pclk};
        vs <= {vs[2:0], vsync};
        hs <= {hs[2:0], href};
        d1 <= data; d2 <= d1; d3 <= d2;
        mem_we <= 0;
        done <= 0;
        expired <= busy && elapsed == TIMEOUT - 2;
        // Pipeline the event qualifier with its data and quality observations.
        pixel_event <= !reset && busy && active && pc_edge && vs[2] && hs[2];
        line_event <= !reset && busy && active && h_end;
        frame_event <= !reset && busy && active && v_end;
        pixel_data <= d2;
        sample_bad <= d2 != d3 || hs[1] != hs[2];
        pulse_bad <= busy && active && pc[2] != pc[3] && pulse_cycles < 3;
        sync_bad <= busy && active && hs[2] && !vs[2];
        frame_bad <= hs[2];
        line_pending <= !reset && busy && line_event;
        finish_pending <= !reset && busy && frame_event;
        line_snapshot <= nibbles;
        less_min <= less16(nibbles, min_line);
        more_max <= less16(max_line, nibbles);
        if (line_pending) begin
            if (less_min) min_line <= line_snapshot;
            if (more_max) max_line <= line_snapshot;
        end
        if (pc[2] != pc[3]) pulse_cycles <= 1;
        else if (pulse_cycles != 255) pulse_cycles <= pulse_cycles + 1'b1;
        if (reset) begin
            busy <= 0;
            phase <= 3'b001;
            half <= 0;
        end else if (arm && !busy) begin
            busy <= 1;
            phase <= 3'b001;
            half <= 0;
            nibbles <= 0;
            bytes_count <= 0;
            lines_count <= 0;
            min_line <= 16'hffff;
            max_line <= 0;
            flags <= 0;
            cycles <= 0;
            elapsed <= 0;
            order <= msb_first;
            edge_fall <= falling_edge;
        end else if (busy) begin
            elapsed <= elapsed + 1'b1;
            if (phase[0] && !vs[2] && !hs[2]) phase <= 3'b010;
            if (starting) phase <= 3'b100;
            if (active) cycles <= cycles + 1'b1;
            if (pulse_bad) flags[6] <= 1;
            if (sync_bad) flags[3] <= 1;
            if (pixel_event) begin
                // Check the following synchronized sample as well: a two-cycle
                // pulse can agree at both earlier observations yet corrupt data.
                if (sample_bad || pixel_data != d2) flags[5] <= 1;
                if (nibbles != 16'hffff) nibbles <= nibbles + 1'b1;
                else flags[1] <= 1;
                half <= !half;
                if (!half) first <= pixel_data;
                else if (bytes_count < CAPACITY) begin
                    mem_data <= order ? {first, pixel_data} : {pixel_data, first};
                    mem_addr <= bytes_count[16:0];
                    mem_we <= 1;
                    bytes_count <= bytes_count + 1'b1;
                end else flags[4] <= 1;
            end
            if (line_event) begin
                if (half) flags[0] <= 1;
                if (nibbles != WIDTH * 2) flags[1] <= 1;
                if (lines_count != 16'hffff) lines_count <= lines_count + 1'b1;
                else flags[2] <= 1;
                half <= 0;
                nibbles <= 0;
            end
            if (frame_event) begin
                if (frame_bad) begin
                    flags[3] <= 1;
                    if (half) flags[0] <= 1;
                end
                if (line_event ? lines_count != HEIGHT - 1 : lines_count != HEIGHT)
                    flags[2] <= 1;
                phase <= 3'b000;
            end
            if (finish_pending) begin
                busy <= 0;
                done <= 1;
            end
            if (expired) begin
                flags[7] <= 1;
                busy <= 0;
                done <= 1;
            end
        end
    end
endmodule
