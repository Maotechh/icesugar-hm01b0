module camera_core #(
    parameter UART_DIV = 416,
    parameter I2C_QUARTER = 120,
    parameter CAP_WIDTH = 324,
    parameter CAP_HEIGHT = 244,
    parameter CAP_TIMEOUT = 96000000
) (
    input wire clk, reset, uart_rx,
    output wire uart_tx,
    input wire [3:0] cam_d,
    input wire cam_pclk, cam_vsync, cam_href, cam_int, scl_in, sda_in,
    output wire scl_low, sda_low,
    output reg enabled,
    output wire capture_busy,
    output wire [7:0] capture_flags
);
    initial enabled = 0;
    function [15:0] crc16_byte;
        input [15:0] crc;
        input [7:0] value;
        reg [15:0] c;
        integer j;
        begin
            c = crc ^ {value, 8'b0};
            for (j=0; j<8; j=j+1) c = c[15] ? (c << 1) ^ 16'h1021 : c << 1;
            crc16_byte = c;
        end
    endfunction
    function [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] value;
        reg [31:0] c;
        integer j;
        begin
            c = crc ^ value;
            for (j=0; j<8; j=j+1) c = c[0] ? (c >> 1) ^ 32'hedb88320 : c >> 1;
            crc32_byte = c;
        end
    endfunction

    wire [7:0] rx_data;
    wire rx_valid, rx_error, tx_ready, uart_ready;
    reg [7:0] tx_data;
    reg tx_valid;
    reg [7:0] tx_buffer = 0;
    reg tx_pending = 0;
    assign tx_ready = !tx_pending;
    uart #(.DIV(UART_DIV)) serial (
        .clk(clk), .reset(reset), .rx(uart_rx), .tx(uart_tx),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_error(rx_error),
        .tx_data(tx_buffer), .tx_valid(tx_pending), .tx_ready(uart_ready)
    );
    always @(posedge clk) begin
        if (reset) tx_pending <= 0;
        else begin
            if (tx_pending && uart_ready) tx_pending <= 0;
            if (tx_valid && tx_ready) begin
                tx_buffer <= tx_data;
                tx_pending <= 1;
            end
        end
    end

    reg [3:0] req_index = 0;
    reg [15:0] req_crc = 16'hffff;
    reg [15:0] next_req_crc = 0;
    reg [7:0] rbyte = 0;
    reg rvalid = 0, rerror = 0;
    reg [7:0] req_crc_hi, req_op, req_seq, req_value;
    reg [15:0] req_addr;
    reg req_valid = 0;
    reg [23:0] req_timeout = 0;
    reg req_expired = 0;
    reg [15:0] crc_errors = 0, uart_errors = 0, busy_errors = 0;
    always @(posedge clk) begin
        rbyte <= rx_data;
        rvalid <= !reset && rx_valid;
        rerror <= !reset && rx_error;
        next_req_crc <= crc16_byte(req_crc, rx_data);
        req_valid <= 0;
        req_expired <= !reset && !rvalid && req_index != 0 && req_timeout == 4799999;
        if (reset) begin
            req_index <= 0;
            req_crc <= 16'hffff;
            crc_errors <= 0;
            uart_errors <= 0;
        end else begin
            if (req_index == 0 || rvalid) req_timeout <= 0;
            else req_timeout <= req_timeout + 1'b1;
            if (rerror || req_expired) begin
                req_index <= 0;
                uart_errors <= uart_errors + 1'b1;
            end else if (rvalid) begin
                if (req_index == 0) begin
                    if (rbyte == 8'h48) begin
                        req_index <= 1;
                        req_crc <= crc16_byte(16'hffff, 8'h48);
                    end
                end else if (req_index == 1 && rbyte != 8'h43) begin
                    req_index <= rbyte == 8'h48 ? 1 : 0;
                    req_crc <= crc16_byte(16'hffff, 8'h48);
                end else begin
                    req_index <= req_index + 1'b1;
                    if (req_index <= 6) req_crc <= next_req_crc;
                    case (req_index)
                        2: req_op <= rbyte;
                        3: req_seq <= rbyte;
                        4: req_addr[15:8] <= rbyte;
                        5: req_addr[7:0] <= rbyte;
                        6: req_value <= rbyte;
                        7: req_crc_hi <= rbyte;
                        8: begin
                            req_index <= 0;
                            if ({req_crc_hi, rbyte} == req_crc) req_valid <= 1;
                            else crc_errors <= crc_errors + 1'b1;
                        end
                    endcase
                end
            end
        end
    end

    reg i2c_start = 0, i2c_read;
    reg [15:0] i2c_addr;
    reg [7:0] i2c_wdata;
    wire i2c_busy, i2c_done;
    wire [7:0] i2c_rdata, i2c_error;
    i2c_register #(.QUARTER(I2C_QUARTER)) control (
        .clk(clk), .reset(reset), .start(i2c_start), .read_op(i2c_read),
        .address(i2c_addr), .write_data(i2c_wdata), .scl_in(scl_in), .sda_in(sda_in),
        .scl_low(scl_low), .sda_low(sda_low), .busy(i2c_busy),
        .done(i2c_done), .read_data(i2c_rdata), .error(i2c_error)
    );
    reg cap_arm = 0;
    reg [7:0] cap_mode = 0;
    wire cap_done, mem_we;
    wire [16:0] mem_waddr;
    wire [7:0] mem_wdata, mem_rdata;
    wire [17:0] cap_bytes;
    wire [15:0] cap_lines, cap_min, cap_max;
    wire [31:0] cap_cycles;
    capture #(.WIDTH(CAP_WIDTH), .HEIGHT(CAP_HEIGHT), .TIMEOUT(CAP_TIMEOUT)) receiver (
        .clk(clk), .reset(reset), .arm(cap_arm), .msb_first(cap_mode[0]),
        .falling_edge(cap_mode[1]), .pclk(cam_pclk), .vsync(cam_vsync),
        .href(cam_href), .data(cam_d), .busy(capture_busy), .done(cap_done),
        .mem_we(mem_we), .mem_addr(mem_waddr), .mem_data(mem_wdata),
        .bytes_count(cap_bytes), .lines_count(cap_lines), .min_line(cap_min),
        .max_line(cap_max), .flags(capture_flags), .cycles(cap_cycles)
    );

    localparam IDLE=0, I2C_WAIT=1, CAP_WAIT=2, PREP=3, HEADER=4,
        RAM_WAIT1=5, RAM_WAIT2=6, PAYLOAD=7, TRAILER=8;
    (* fsm_encoding = "one-hot" *) reg [3:0] state;
    reg [7:0] response_op, response_seq, response_status;
    reg [31:0] response_length = 0;
    reg [127:0] small_payload = 0;
    reg [17:0] payload_index = 0;
    reg [17:0] payload_last = 0;
    reg last_payload = 0;
    reg [7:0] payload_byte = 0;
    reg [3:0] header_index = 0;
    reg [1:0] trailer_index = 0;
    reg [31:0] response_crc = 32'hffffffff;
    reg crc_pending = 0;
    reg response_frame = 0;
    // Track payload_index - 16 in a register to shorten the SPRAM address path.
    reg [16:0] read_address = 0;
    frame_ram storage (.clk(clk), .we(mem_we),
        .address(mem_we ? mem_waddr : read_address), .din(mem_wdata), .dout(mem_rdata));
    (* async_reg = "true" *) reg [7:0] gpio1 = 0, gpio2 = 0;
    always @(posedge clk) begin
        gpio1 <= {scl_in, sda_in, cam_int, cam_vsync, cam_href, cam_pclk, cam_d[1:0]};
        gpio2 <= gpio1;
    end

    always @* begin
        tx_data = 0;
        tx_valid = 0;
        case (state)
            HEADER: begin
                tx_valid = 1;
                case (header_index)
                    0: tx_data = 8'h48;
                    1: tx_data = 8'h43;
                    2: tx_data = response_op;
                    3: tx_data = response_seq;
                    4: tx_data = response_status;
                    5: tx_data = response_length[7:0];
                    6: tx_data = response_length[15:8];
                    7: tx_data = response_length[23:16];
                    8: tx_data = response_length[31:24];
                endcase
            end
            PAYLOAD: begin
                tx_valid = 1;
                tx_data = payload_byte;
            end
            TRAILER: begin
                tx_valid = 1;
                tx_data = (~response_crc) >> (trailer_index * 8);
            end
        endcase
    end
    always @(posedge clk) begin
        i2c_start <= 0;
        cap_arm <= 0;
        crc_pending <= !reset && tx_valid && tx_ready && (state == HEADER || state == PAYLOAD);
        if (crc_pending) response_crc <= crc32_byte(response_crc, tx_buffer);
        if (reset) begin
            enabled <= 0;
            state <= IDLE;
            busy_errors <= 0;
        end else begin
            if (req_valid && state != IDLE) busy_errors <= busy_errors + 1'b1;
            case (state)
                IDLE: if (req_valid) begin
                    response_op <= req_op;
                    response_seq <= req_seq;
                    response_status <= 0;
                    response_length <= 1;
                    response_frame <= 0;
                    small_payload <= 0;
                    state <= PREP;
                    case (req_op)
                        0: begin
                            response_length <= 16;
                            small_payload <= {32'd48000000, 16'b0, busy_errors,
                                uart_errors, crc_errors, 8'b0, gpio2, 7'b0, enabled, 8'd1};
                        end
                        1, 2: if (!enabled) response_status <= 8'h30;
                            else begin
                                i2c_read <= req_op == 2;
                                i2c_addr <= req_addr;
                                i2c_wdata <= req_value;
                                i2c_start <= 1;
                                state <= I2C_WAIT;
                            end
                        3: begin
                            enabled <= req_value[0];
                            small_payload <= {127'b0, req_value[0]};
                        end
                        4: if (!enabled) response_status <= 8'h30;
                            else begin
                                cap_mode <= req_value;
                                cap_arm <= 1;
                                state <= CAP_WAIT;
                            end
                        default: response_status <= 8'h31;
                    endcase
                end
                I2C_WAIT: if (i2c_done) begin
                    response_status <= i2c_error;
                    small_payload <= {120'b0, i2c_rdata};
                    state <= PREP;
                end
                CAP_WAIT: if (cap_done) begin
                    response_frame <= 1;
                    response_length <= {14'b0, cap_bytes} + 32'd16;
                    small_payload <= {cap_cycles, cap_mode, capture_flags, cap_max,
                        cap_min, cap_lines, 14'b0, cap_bytes};
                    state <= PREP;
                end
                PREP: begin
                    header_index <= 0;
                    payload_index <= 0;
                    read_address <= 17'h1fff0;
                    payload_last <= response_length[17:0] - 18'd1;
                    trailer_index <= 0;
                    response_crc <= 32'hffffffff;
                    state <= HEADER;
                end
                HEADER: if (tx_ready) begin
                    if (header_index == 8) state <= RAM_WAIT1;
                    else header_index <= header_index + 1'b1;
                end
                RAM_WAIT1: state <= RAM_WAIT2;
                RAM_WAIT2: begin
                    payload_byte <= response_frame && payload_index >= 16 ? mem_rdata :
                        small_payload >> (payload_index[3:0] * 8);
                    last_payload <= payload_index == payload_last;
                    state <= PAYLOAD;
                end
                PAYLOAD: if (tx_ready) begin
                    if (last_payload) state <= TRAILER;
                    else begin
                        payload_index <= payload_index + 1'b1;
                        read_address <= read_address + 1'b1;
                        state <= RAM_WAIT1;
                    end
                end
                TRAILER: if (tx_ready) begin
                    if (trailer_index == 3) state <= IDLE;
                    else trailer_index <= trailer_index + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
