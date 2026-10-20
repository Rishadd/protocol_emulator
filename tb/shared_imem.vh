// Shared instruction memory (-DSHARED_IMEM): engine 1's image sits at physical word 256 (engine 0's at 0), so every jump target of engine 1's image needs
// address bit 8, which is operand bit 11. JMP DJNZ JPH JPL JPO JCC are opcodes 2 5 17 18 19 23.
function [31:0] shw(input [31:0] w, input e1);
    begin
        shw = (e1 && (w[31:27] == 5'd2 || w[31:27] == 5'd5 || w[31:27] == 5'd17 || w[31:27] == 5'd18 || w[31:27] == 5'd19 || w[31:27] == 5'd23)) ?
              (w | 32'h0000_0800) : w;
    end
endfunction
