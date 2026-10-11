// Protocol-side SPI peers for the SPI testbenches (include inside a module), all 4 modes.
// Independent of the engine firmware: they follow the SPI mode table, not the programs.
// The including module declares the pad lines `wire p_cs, p_sclk, p_mosi, p_miso;` before this include.
// Timing is in ns and independent of clk.
//   master model: drives m_cs/m_sclk/m_mosi, frame f sends mtx[f]; call m_run(n)
//   slave model : drives s_miso while s_en, frame k replies stx[k] (k counts CS falls)
// Frame f of the master model gets only m_abits clocks if f == m_abort (short / aborted CS).
// Values are right-aligned p_bits-bit numbers, sent MSB- or LSB-first per p_lsb.
integer p_cpol = 0, p_cpha = 0, p_bits = 8, p_lsb = 0;
integer m_half = 100, m_css = 100, m_csh = 100, m_gap = 200, m_jit = 0, m_abort = -1, m_abits = 0;
integer s_tco = 0, p_seed = 1, p_fd = 0;
reg     m_cs = 1'b1, m_sclk = 1'b0, m_mosi = 1'b0, s_miso = 1'b0, s_en = 1'b0;
reg [31:0] mtx [0:4095];
reg [31:0] stx [0:4095];
reg [31:0] s_word = 0;
integer    s_idx = 0, s_bit = 0;

function bitof(input [31:0] v, input integer i);
    bitof = p_lsb ? v[i] : v[p_bits - 1 - i];
endfunction

// ---- slave model: shift edge = trailing for CPHA=0 (first bit at CS fall), leading for CPHA=1
task s_shift;
    begin
        s_miso <= #(s_tco) (s_bit < p_bits) ? bitof(s_word, s_bit) : 1'b0;
        s_bit = s_bit + 1;
    end
endtask
always @(negedge p_cs) if (s_en) begin
    s_word = stx[s_idx]; s_idx = s_idx + 1; s_bit = 0;
    if (p_cpha == 0) s_shift;
end
always @(p_sclk) if (s_en && p_cs === 1'b0 && ((p_sclk !== p_cpol[0]) == p_cpha[0])) s_shift;

// ---- master model: data changes on the shift edge, so hold after the sampling edge = half
function integer m_hp;          // half period with optional uniform jitter +-m_jit
    input dummy;
    m_hp = m_half + (m_jit ? $random(p_seed) % (m_jit + 1) : 0);
endfunction
task m_run(input integer n);
    integer f, i, nb;
    begin
        for (f = 0; f < n; f = f + 1) begin
            nb = (f == m_abort) ? m_abits : p_bits;
            m_cs = 1'b0;
            if (p_cpha || nb == 0) #(m_css);      // m_css = CS fall to first SCLK edge in every mode
            for (i = 0; i < nb; i = i + 1) begin
                if (p_cpha == 0) begin
                    m_mosi = bitof(mtx[f], i); #(i ? m_hp(0) : m_css);
                    m_sclk = !p_cpol;          #(m_hp(0));
                    m_sclk = p_cpol;
                end else begin
                    m_sclk = !p_cpol; m_mosi = bitof(mtx[f], i); #(m_hp(0));
                    m_sclk = p_cpol;                             #(m_hp(0));
                end
            end
            #(m_csh); m_cs = 1'b1; #(m_gap);
        end
    end
endtask

// ---- pad log: every change of the 4 lines (Python keeps the last line per timestamp)
always @(p_cs or p_sclk or p_mosi or p_miso) p_log;
task p_log;
    if (p_fd) $fdisplay(p_fd, "P %0d %b%b%b%b", $time, p_cs, p_sclk, p_mosi, p_miso);
endtask

task p_args;    // common plusargs
    begin
        if ($value$plusargs("MODE=%d", p_cpol)) begin p_cpha = p_cpol & 1; p_cpol = p_cpol >> 1; end
        if ($value$plusargs("BITS=%d", p_bits)) ;
        if ($value$plusargs("LSB=%d", p_lsb)) ;
        if ($value$plusargs("HALF_NS=%d", m_half)) ;
        if ($value$plusargs("CSS_NS=%d", m_css)) ;
        if ($value$plusargs("CSH_NS=%d", m_csh)) ;
        if ($value$plusargs("GAP_NS=%d", m_gap)) ;
        if ($value$plusargs("JIT_NS=%d", m_jit)) ;
        if ($value$plusargs("ABORT=%d", m_abort)) ;
        if ($value$plusargs("ABITS=%d", m_abits)) ;
        if ($value$plusargs("TCO_NS=%d", s_tco)) ;
        if ($value$plusargs("SEED=%d", p_seed)) ;
        m_sclk = p_cpol;
    end
endtask
