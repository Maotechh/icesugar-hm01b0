module i2c_register #(
    parameter QUARTER = 120,
    parameter TIMEOUT = 960000
) (
    input wire clk, reset, start, read_op,
    input wire [15:0] address,
    input wire [7:0] write_data,
    input wire scl_in, sda_in,
    output reg scl_low, sda_low,
    output wire busy,
    output reg done,
    output reg [7:0] read_data, error
);
    initial begin
        scl_low = 0; sda_low = 0; done = 0; read_data = 0; error = 0;
    end
    localparam IDLE=0, START=1, BIT_SETUP=2, BIT_RAISE=3,
        BIT_HIGH=4, BIT_FALL=5, ACK_SETUP=6, ACK_RAISE=7,
        ACK_HIGH=8, ACK_FALL=9, RESTART_SETUP=10, RESTART_RAISE=11,
        RESTART_HIGH=12, STOP_SETUP=13, STOP_RAISE=14, STOP_HIGH=15,
        STOP_RELEASE=16, NEXT_BYTE=17;
    (* fsm_encoding = "one-hot" *) reg [4:0] state;
    reg [$clog2(QUARTER)-1:0] divider = 0;
    reg [15:0] regaddr = 0;
    reg [23:0] watchdog = 0;
    reg expired = 0;
    reg [7:0] shift = 0, wdata = 0;
    reg [2:0] bitno = 7, byteno = 0;
    reg reading = 0, receive_byte = 0;
    (* async_reg = "true" *) reg [2:0] scl_sync = 7, sda_sync = 7;
    assign busy = state != IDLE;
    always @(posedge clk) begin
        scl_sync <= {scl_sync[1:0], scl_in};
        sda_sync <= {sda_sync[1:0], sda_in};
        done <= 0;
        expired <= watchdog == TIMEOUT - 2;
        if (reset) begin
            state <= IDLE;
            scl_low <= 0;
            sda_low <= 0;
        end else if (state == IDLE) begin
            watchdog <= 0;
            divider <= QUARTER - 1;
            if (start) begin
                error <= 0;
                read_data <= 0;
                regaddr <= address;
                wdata <= write_data;
                reading <= read_op;
                receive_byte <= 0;
                byteno <= 0;
                bitno <= 7;
                shift <= 8'h48;
                if (!scl_sync[2] || !sda_sync[2]) begin
                    error <= 8'h20;
                    done <= 1;
                end else begin
                    sda_low <= 1;
                    state <= START;
                end
            end
        end else if (expired) begin
            state <= IDLE;
            scl_low <= 0;
            sda_low <= 0;
            error <= 8'h21;
            done <= 1;
        end else begin
            watchdog <= watchdog + 1'b1;
            if (divider != 0) divider <= divider - 1'b1;
            else begin
                divider <= QUARTER - 1;
                case (state)
                    START: begin scl_low <= 1; state <= BIT_SETUP; end
                    BIT_SETUP: begin
                        sda_low <= receive_byte ? 1'b0 : !shift[bitno];
                        state <= BIT_RAISE;
                    end
                    BIT_RAISE: begin scl_low <= 0; state <= BIT_HIGH; end
                    BIT_HIGH: if (scl_sync[2]) begin
                        if (receive_byte) shift[bitno] <= sda_sync[2];
                        state <= BIT_FALL;
                    end
                    BIT_FALL: begin
                        scl_low <= 1;
                        if (bitno == 0) state <= ACK_SETUP;
                        else begin bitno <= bitno - 1'b1; state <= BIT_SETUP; end
                    end
                    ACK_SETUP: begin sda_low <= 0; state <= ACK_RAISE; end
                    ACK_RAISE: begin scl_low <= 0; state <= ACK_HIGH; end
                    ACK_HIGH: if (scl_sync[2]) begin
                        if (!receive_byte && sda_sync[2]) error <= 8'h10 | {5'b0, byteno};
                        state <= ACK_FALL;
                    end
                    ACK_FALL: begin
                        scl_low <= 1;
                        bitno <= 7;
                        if (error != 0) state <= STOP_SETUP;
                        else if (receive_byte) begin read_data <= shift; state <= STOP_SETUP; end
                        else state <= NEXT_BYTE;
                    end
                    NEXT_BYTE: begin
                        case (byteno)
                            0: begin shift <= regaddr[15:8]; byteno <= 1; state <= BIT_SETUP; end
                            1: begin shift <= regaddr[7:0]; byteno <= 2; state <= BIT_SETUP; end
                            2: if (reading) state <= RESTART_SETUP;
                               else begin shift <= wdata; byteno <= 3; state <= BIT_SETUP; end
                            3: state <= STOP_SETUP;
                            4: begin receive_byte <= 1; state <= BIT_SETUP; end
                            default: begin error <= 8'h22; state <= STOP_SETUP; end
                        endcase
                    end
                    RESTART_SETUP: begin sda_low <= 0; state <= RESTART_RAISE; end
                    RESTART_RAISE: begin scl_low <= 0; state <= RESTART_HIGH; end
                    RESTART_HIGH: if (scl_sync[2]) begin
                        sda_low <= 1;
                        shift <= 8'h49;
                        byteno <= 4;
                        state <= START;
                    end
                    STOP_SETUP: begin sda_low <= 1; state <= STOP_RAISE; end
                    STOP_RAISE: begin scl_low <= 0; state <= STOP_HIGH; end
                    STOP_HIGH: if (scl_sync[2]) begin sda_low <= 0; state <= STOP_RELEASE; end
                    STOP_RELEASE: begin state <= IDLE; done <= 1; end
                    default: state <= IDLE;
                endcase
            end
        end
    end
endmodule
