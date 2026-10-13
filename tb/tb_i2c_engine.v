`timescale 1ns/1ps
`include "isa.vh"
// I2C at engine level (engine_top + the real pin_mgr, pads 6/7 claimed open-drain for engine 0),
// orchestrated by host/i2c_test.py. 20 ns = 1 system clock (50 MHz), so timing checks are in real ns.
//   +ROLE=0 engine is the master        +ROLE=2 no engine: Verilog master model (same word semantics)
//   +ROLE=3 engine is the slave at 0x50 (replaces model s1): the master model drives the words, a
//           Verilog host answers the engine like i2c_slave_model (pointer + memory, +S_NACK_AT);
//           +HLAT_NS host reaction time. The program may use L2: +L2PROG (256 words), +RV, +RANGE.
// Bus: wired-AND with pull-ups; a released line rises after T_RISE ns (compile-time -P parameter).
// Slaves: s1 at 0x50 (+S1EN=0 removes it), s2 at 0x23 (only with +S2EN=1); knobs +S_TVD_NS
// +S_STRETCH_NS +S_STRETCH_MODE +S_NACK_AT apply to s1. Host: +HTX words, +N, +TXLATE_NS, +RXOFF_NS,
// +TXGAP_NS (minimum time between two host TX writes).
// Log: P <ns> <sda><scl>  W/R <ns> <hex>  MEM <slave> <256 bytes hex>  END ...
module tb_i2c_engine;
    parameter T_RISE = 1;
    reg         clk = 0, rst_n = 0, run = 0;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe, pad_oe, pad_out, od;
    wire [15:0] owner, viol;
    wire [8:0]  pc;
    reg  [2:0]  cfg_pad = 0;
    reg         cfg_we = 0;
    reg  [2:0]  padcfg = 3'b101;           // engine 0, open-drain (+PUSHPULL=1: 3'b001)
    wire        cfg_ok;

    // ---- bus
    reg  m_sda_low = 0, m_scl_low = 0;
    wire s1_sda, s1_scl, s2_sda, s2_scl;
    wire c_sda = pad_oe[6] & ~pad_out[6], c_scl = pad_oe[7] & ~pad_out[7];
    wire #(T_RISE, 1) sda = !(c_sda | s1_sda | s2_sda | m_sda_low);
    wire #(T_RISE, 1) scl = !(c_scl | s1_scl | s2_scl | m_scl_low);

    reg  [8:0]  rv = 0;
    reg  [15:0] rng = 16'h00FF;
    reg         h_we = 0;
    reg  [7:0]  h_a = 0;
    reg  [31:0] h_d = 0;
    wire        l2_req, l2_hi;
    wire [7:0]  l2_a;
    wire [1:0]  l2_gnt;
    wire [31:0] l2d;
    l2_mem l2 (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(1'b0), .h_addr(h_a), .h_wdata(h_d),
               .req({1'b0, l2_req}), .req_hi({1'b0, l2_hi}), .req_addr({8'd0, l2_a}), .policy(2'd0), .gnt(l2_gnt), .rdata(l2d));
    engine_top dut (
        .reset_pc(rv), .l2_range(rng), .fetch_cfg(2'b01), .perf_clr(2'b00),
        .l2_req(l2_req), .l2_req_hi(l2_hi), .l2_addr(l2_a), .l2_gnt(l2_gnt[0]), .l2_rdata(l2d),
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in({scl, sda, 6'd0}), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));
    pin_mgr pm (.clk(clk), .rst_n(rst_n), .run({1'b0, run}), .cfg_pad(cfg_pad), .cfg_data(padcfg),
        .cfg_ok(cfg_ok), .cfg_we(cfg_we), .viol_clr(16'd0), .oe0(pin_oe), .out0(pin_out), .oe1(8'd0),
        .out1(8'd0), .pad_oe(pad_oe), .pad_out(pad_out), .owner(owner), .od(od), .viol(viol));
    i2c_slave_model #(7'h50) s1 (.sda(sda), .scl(scl), .sda_low(s1_sda), .scl_low(s1_scl));
    i2c_slave_model #(7'h23) s2 (.sda(sda), .scl(scl), .sda_low(s2_sda), .scl_low(s2_scl));

    reg [8*256-1:0] prog_f, htx_f, out_f;
    reg [31:0] htx [0:8191];
    reg [31:0] htx_l2 [0:255];
    integer role = 0, n = 0, tmax = 10000000, txlate = 0, rxoff = 0, txgap = 0, fd, cyc = 0, nw = 0, nr = 0;
    integer drive_high = 0, idle = 0, k;
    integer m_low = 1300, m_high = 600;

    always #10 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    always @(posedge clk) if (cyc == tmax && role == 3) disable master;   // slave lost sync: SCL held low
    always @(sda or scl) if (fd) $fdisplay(fd, "P %0d %b%b", $time, sda, scl);
    always @(negedge clk) begin
        if ((pad_oe[6] & pad_out[6]) | (pad_oe[7] & pad_out[7])) drive_high = drive_high + 1;
        tx_wr_en = 0; rx_rd_en = 0;
        if (role == 3 && run && hq_r < hq_w && !tx_full && $time >= hready) begin
            tx_wr_en = 1; tx_wr_data = hq[hq_r % 16]; hq_r = hq_r + 1;
            $fdisplay(fd, "W %0d %h", $time, tx_wr_data);
        end
        if (role == 0 && run && nw < n && !tx_full && $time >= txlate) begin
            tx_wr_en = 1; tx_wr_data = htx[nw]; nw = nw + 1; txlate = $time + txgap;
            $fdisplay(fd, "W %0d %h", $time, tx_wr_data);
        end
        if (!rx_empty && $time >= rxoff) begin
            rx_rd_en = 1; nr = nr + 1;
            if (role == 3) slave_host(rx_rd_data); else $fdisplay(fd, "R %0d %h", $time, rx_rd_data);
        end
        idle = (dut.tx_empty && dut.cu.opcode == `OP_PULL) ? idle + 1 : 0;
    end

    // ---- slave host (ROLE=3): written from i2c_slave_model's behaviour, not from the firmware
    reg  [7:0]  h_mem [0:255];
    reg  [7:0]  h_ptr = 0;
    reg  [31:0] hq [0:15];
    integer     hq_w = 0, hq_r = 0, h_state = 0, h_nb = 0, h_nack_at = -1, hlat = 0, n_ev = 0;
    time        hready = 0;
    reg         h_data = 1;
    localparam  IDLE = 0, ADDR = 1, WPTR = 2, WDATA = 3, READ = 4, OTHER = 5;
    task hpush(input [31:0] w); begin hq[hq_w % 16] = w; hq_w = hq_w + 1; hready = $time + hlat; end endtask
    task slave_host(input [31:0] w);
        begin
            if (w == 32'h0400_0001) begin h_state = ADDR; h_data = 1; n_ev = n_ev + 1; hpush(32'hFF00_0000); end
            else if (w == 32'h0400_0002) begin h_state = IDLE; n_ev = n_ev + 1; end
            else if (h_data) begin                                   // the 8 bits read
                h_data = 0;
                case (h_state)
                    ADDR: if (w[7:1] == 7'h50) begin
                              hpush(32'h0); h_state = w[0] ? READ : WPTR; h_nb = 0;
                              if (!w[0]) hpush(32'hFF00_0000);
                          end else begin hpush(32'h8000_0000); h_state = OTHER; end
                    WPTR, WDATA: if (h_nb == h_nack_at) begin hpush(32'h8000_0000); h_state = OTHER; end
                          else begin
                              if (h_state == WPTR) h_ptr = w[7:0]; else begin h_mem[h_ptr] = w[7:0]; h_ptr = h_ptr + 1; end
                              h_nb = h_nb + 1; h_state = WDATA; hpush(32'h0); hpush(32'hFF00_0000);
                          end
                    READ: hpush(32'h8000_0000);                       // release the 9th bit for the master
                    default: ;
                endcase
            end else begin                                           // the 9th bit as sampled
                h_data = 1;
                if (h_state == READ && w[0] == 1'b0) begin hpush({h_mem[h_ptr], 24'hFF_FFFF}); h_ptr = h_ptr + 1; end
                else if (h_state == READ) h_state = OTHER;            // master NACK: it ends the read
            end
        end
    endtask

    // ---- Verilog master model (ROLE=2): same word semantics as the firmware, independent code
    reg  [8:0] m_rx;
    reg        m_open = 0, m_skip = 0;
    task m_scl_pulse(input b);                 // drive b during SCL low, sample during SCL high
        begin
            m_sda_low = !b; #(m_low);
            m_scl_low = 0; wait (scl === 1'b1); #(m_high);
            m_rx = {m_rx[7:0], sda};
            m_scl_low = 1; #(m_low / 4);
        end
    endtask
    task m_start;
        begin
            if (m_open) begin m_sda_low = 0; #(m_low); m_scl_low = 0; wait (scl === 1'b1); end
            wait (sda === 1'b1); #(m_high);
            m_sda_low = 1; #(m_high); m_scl_low = 1; #(m_low / 4); m_open = 1;
        end
    endtask
    task m_stop;
        begin
            m_sda_low = 1; #(m_low); m_scl_low = 0; wait (scl === 1'b1); #(m_high);
            m_sda_low = 0; #(m_low); m_open = 0;
        end
    endtask
    task m_word(input [31:0] w);
        integer i;
        begin
            if (m_skip && !w[31]) ;                                  // dropped after a NACK STOP
            else if (!m_open && !w[31]) ;                            // no START on an idle bus: dropped
            else begin
                m_skip = 0;
                if (w[31]) m_start;
                for (i = 0; i < 9; i = i + 1) m_scl_pulse(w[30 - i]);
                $fdisplay(fd, "R %0d %h", $time, {23'd0, m_rx});
                if (w[21] && m_rx[0]) begin
                    m_stop; m_skip = 1;
                    $fdisplay(fd, "R %0d %h", $time, 32'h04000003);
                end else if (w[20]) m_stop;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("ROLE=%d", role) || !$value$plusargs("N=%d", n) ||
            !$value$plusargs("OUT=%s", out_f) || !$value$plusargs("HTX=%s", htx_f)) begin
            $display("ERROR: missing plusargs"); $finish;
        end
        $readmemh(htx_f, htx);
        if ($value$plusargs("PROG=%s", prog_f)) dut.imem.load_hex(prog_f);
        if ($value$plusargs("RV=%d", k)) rv = k;
        if ($value$plusargs("RANGE=%d", k)) rng = k;
        if ($value$plusargs("HLAT_NS=%d", hlat)) ;
        for (k = 0; k < 256; k = k + 1) h_mem[k] = k[7:0] ^ 8'hA5;
        if ($value$plusargs("S_NACK_AT=%d", k)) h_nack_at = k;
        if ($value$plusargs("TMAX=%d", tmax)) ;
        if ($value$plusargs("TXLATE_NS=%d", txlate)) ;
        if ($value$plusargs("RXOFF_NS=%d", rxoff)) ;
        if ($value$plusargs("TXGAP_NS=%d", txgap)) ;
        if ($value$plusargs("PUSHPULL=%d", k) && k) padcfg = 3'b001;
        if ($value$plusargs("M_LOW_NS=%d", m_low)) ;
        if ($value$plusargs("M_HIGH_NS=%d", m_high)) ;
        // slave knobs (s1 at 0x50 always present unless +S1EN=0; s2 at 0x23 only with +S2EN=1)
        if ($value$plusargs("S1EN=%d", k)) s1.en = k;
        s2.en = $value$plusargs("S2EN=%d", k) ? k : 0;
        if ($value$plusargs("S_TVD_NS=%d", k)) begin s1.tvd = k; s2.tvd = k; end
        if ($value$plusargs("S_STRETCH_NS=%d", k)) s1.stretch_ns = k;
        if ($value$plusargs("S_STRETCH_MODE=%d", k)) s1.stretch_mode = k;
        if ($value$plusargs("S_NACK_AT=%d", k)) s1.nack_at = k;
        fd = $fopen(out_f, "w");
        $fdisplay(fd, "P %0d %b%b", $time, sda, scl);

        repeat (3) @(posedge clk); #1 rst_n = 1;
        if ($value$plusargs("L2PROG=%s", prog_f)) begin                 // L2 image through the host port
            $readmemh(prog_f, htx_l2);
            for (k = 0; k < 256; k = k + 1) begin @(negedge clk) begin h_we = 1; h_a = k; h_d = htx_l2[k]; end end
            @(negedge clk) h_we = 0;
        end
        for (k = 6; k < 8; k = k + 1) begin                       // claim pads 6, 7: engine 0, open-drain
            @(negedge clk) begin cfg_pad = k; cfg_we = 1; end
            @(negedge clk) cfg_we = 0;
        end
        repeat (2) @(posedge clk);
        if (role == 0) begin
            #1 run = 1;
            wait ((nw >= n && idle > 2000) || cyc >= tmax);
        end else if (role == 3) begin
            #1 run = 1;
            repeat (200) @(posedge clk);
            begin : master                                         // cut by the TMAX watchdog below
                for (k = 0; k < n; k = k + 1) m_word(htx[k]);
                if (m_open) m_stop;
                repeat (2000) @(posedge clk);
            end
        end else begin
            for (k = 0; k < n; k = k + 1) m_word(htx[k]);
            if (m_open) m_stop;
        end
        repeat (200) @(posedge clk);
        $fwrite(fd, "MEM 1 "); for (k = 0; k < 256; k = k + 1) $fwrite(fd, "%h", role == 3 ? h_mem[k] : s1.mem[k]); $fdisplay(fd, "");
        $fwrite(fd, "MEM 2 "); for (k = 0; k < 256; k = k + 1) $fwrite(fd, "%h", s2.mem[k]); $fdisplay(fd, "");
        $fdisplay(fd, "END cyc=%0d nw=%0d nr=%0d fault=%0d halted=%0d pc=%0d drive_high=%0d viol=%0d timeout=%0d events=%0d",
                  cyc, nw, nr, fault, halted, pc, drive_high, viol, cyc >= tmax, n_ev);
        $fclose(fd);
        $finish;
    end
endmodule
