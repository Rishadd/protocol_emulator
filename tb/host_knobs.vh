// Host-behaviour knobs for the chip-level workload harnesses (include after spi_master.vh).
// Call host_extra(base) at the start of every real management frame.
//   +HOSTGAP_NS=g     idle time before every frame (a slow host)
//   +ABORT_EVERY=k    before every k-th frame: a truncated frame (1..6 bytes, CS_N released early) that
//                     targets TX_DATA (write) or RX_DATA (read). It must not push or pop anything; it sets
//                     the sticky err (a short frame is a protocol error), so harnesses report err then.
//   +NOISE_EVERY=k    before every k-th frame: a complete READ of CTRL (base+0x000) or VIOL (0x0220),
//                     which must have no side effect on any FIFO or engine
//   +BURST=1          policy flag for the harness: write until TX full, then read until RX empty
integer hk_gap = 0, hk_abort = 0, hk_noise = 0, hk_burst = 0, hk_n = 0, hk_aborts = 0, hk_noises = 0;
integer hk_seed = 11;

task hk_args;
    begin
        if ($value$plusargs("HOSTGAP_NS=%d", hk_gap)) ;
        if ($value$plusargs("ABORT_EVERY=%d", hk_abort)) ;
        if ($value$plusargs("NOISE_EVERY=%d", hk_noise)) ;
        if ($value$plusargs("BURST=%d", hk_burst)) ;
    end
endtask

task host_extra(input [15:0] base);
    integer nb;
    reg [55:0] f;
    begin
        hk_n = hk_n + 1;
        if (hk_gap) #(hk_gap);
        if (hk_abort && hk_n % hk_abort == 0) begin
            nb = 1 + ({$random(hk_seed)} % 6);
            f = ({$random(hk_seed)} % 2) ? {8'h01, base + 16'h200, $random(hk_seed)}   // write TX_DATA
                                         : {8'h02, base + 16'h204, 32'd0};            // read RX_DATA
            spi_begin; spi_bits({72'd0, f} >> (8 * (7 - nb)), 8 * nb); spi_end;
            hk_aborts = hk_aborts + 1;
        end
        if (hk_noise && hk_n % hk_noise == 0) begin
            spi_begin;
            spi_bits({72'd0, 8'h02, ({$random(hk_seed)} % 2) ? base : 16'h0220, 32'd0}, 56);
            spi_end;
            hk_noises = hk_noises + 1;
        end
    end
endtask
