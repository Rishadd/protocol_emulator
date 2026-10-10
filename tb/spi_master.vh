// SPI mode 0 master model (include inside a module).
// The including module declares: reg sclk, mosi, cs_n; wire miso; real spi_half_ns, spi_cs_ns.
// Timing is in ns and independent of the system clock, so the SCLK phase drifts
// against clk the way an asynchronous host would.
// MISO is sampled on every SCLK rising edge into spi_rx (newest bit in spi_rx[0]).
reg [127:0] spi_rx = 128'd0;

task spi_begin;
    begin cs_n = 1'b0; #(spi_cs_ns); end
endtask

task spi_end;
    begin #(spi_cs_ns); cs_n = 1'b1; #(spi_cs_ns); end
endtask

// mode 0: MOSI set while SCLK is low, both sides sample on the rising edge
task spi_bit(input b);
    begin
        mosi = b; #(spi_half_ns);
        sclk = 1'b1; spi_rx = {spi_rx[126:0], miso}; #(spi_half_ns);
        sclk = 1'b0;
    end
endtask

task spi_byte(input [7:0] b);
    integer i;
    begin for (i = 7; i >= 0; i = i - 1) spi_bit(b[i]); end
endtask

// n bits of v, MSB (bit n-1) first
task spi_bits(input [127:0] v, input integer n);
    integer i;
    begin for (i = n - 1; i >= 0; i = i - 1) spi_bit(v[i]); end
endtask
