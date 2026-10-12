// Reference L2 arbiter for testbenches (two-tier plan I4), written from the plan's §2.5 table, not from
// src/l2_mem.v. host = a host access this clock; req/hi per engine; last = engine granted last
// (round-robin state, kept by the caller: after any engine grant, last = gnt[1]).
function [1:0] arb_ref(input host, input [1:0] req, input [1:0] hi, input [1:0] pol, input last);
    reg [1:0] c;
    begin
        c = ((req & hi) != 2'b00) ? (req & hi) : req;        // only the best class competes
        if (host || req == 2'b00) arb_ref = 2'b00;           // class 1 wins; nothing to grant
        else if (c != 2'b11)      arb_ref = c;               // one engine in the best class
        else if (pol == 2'd1)     arb_ref = 2'b01;           // engine 0 first
        else if (pol == 2'd2)     arb_ref = 2'b10;           // engine 1 first
        else                      arb_ref = last ? 2'b01 : 2'b10;   // round-robin: not the last winner
    end
endfunction
