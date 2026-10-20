// SPI mode 0 slave (CPOL=0, CPHA=0), MSB first, oversampled in the system clock domain.
// SCLK/MOSI/CS_N are asynchronous pins: each passes a 2-flop synchronizer and SCLK is
// edge-detected, so no SCLK clock tree exists. MOSI and SCLK see the same synchronizer
// latency, so MOSI is taken at the synchronized SCLK rising edge. Contract (architecture
// doc §6): SCLK high and low phases >= 8 system clocks; CS_N setup/hold >= 4 system clocks.
//
// MISO: tx_byte is the byte to send next. It is sampled while CS_N is high (first byte)
// and at the SCLK falling edge that ends each byte; other falling edges shift it out MSB
// first, so MISO is stable around every rising edge. MISO is 0 while CS_N is high.
module spi_slave (
    input  wire       clk,
    input  wire       rst_n,
    // pins
    input  wire       sclk,
    input  wire       mosi,
    input  wire       cs_n,
    output wire       miso,
    // byte stream
    output reg        byte_valid,   // 1-cycle pulse, rx_byte holds the completed byte
    output reg  [7:0] rx_byte,
    input  wire [7:0] tx_byte,      // next byte to shift out on MISO
    output wire       active,       // synchronized CS_N low
    output wire       frame_end,    // 1-cycle pulse when CS_N deasserts
    output wire       frame_clean   // at frame_end: no partial byte was left over
);
    reg [2:0] sclk_s;
    reg [1:0] mosi_s;
    reg [2:0] cs_s;
    reg [2:0] bit_cnt;
    reg [6:0] shift;
    reg [7:0] miso_sr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_s <= 3'b000;
            mosi_s <= 2'b00;
            cs_s   <= 3'b111;
        end else begin
            sclk_s <= {sclk_s[1:0], sclk};
            mosi_s <= {mosi_s[0], mosi};
            cs_s   <= {cs_s[1:0], cs_n};
        end
    end

    wire sclk_rise = sclk_s[1] & ~sclk_s[2];
    wire sclk_fall = ~sclk_s[1] & sclk_s[2];

    assign active      = ~cs_s[1];
    assign frame_end   = cs_s[1] & ~cs_s[2];
    assign frame_clean = (bit_cnt == 3'd0);
    assign miso        = active & miso_sr[7];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt    <= 3'd0;
            shift      <= 7'd0;
            rx_byte    <= 8'd0;
            byte_valid <= 1'b0;
            miso_sr    <= 8'd0;
        end else begin
            byte_valid <= 1'b0;
            if (!active) begin
                bit_cnt <= 3'd0;
                miso_sr <= tx_byte;
            end else begin
                if (sclk_rise) begin
                    bit_cnt <= bit_cnt + 1'b1;
                    shift   <= {shift[5:0], mosi_s[1]};
                    if (bit_cnt == 3'd7) begin
                        rx_byte    <= {shift, mosi_s[1]};
                        byte_valid <= 1'b1;
                    end
                end
                if (sclk_fall)
                    miso_sr <= (bit_cnt == 3'd0) ? tx_byte : {miso_sr[6:0], 1'b0};
            end
        end
    end
endmodule
