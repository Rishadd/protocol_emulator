/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: ir.v
# File Description: Infrared sensor debouncer and output filter.
# Global variables: None
*/

module ir(
    input clk_50M, 
    input reset_n,
    input ir,
    output reg op
);

    // COUNTER_MAX: 49999 gives ~1ms at 50MHz
    reg [15:0] counter_1ms;

    /*
    Purpose:
    ---
    Debounce IR sensor by sampling every 1ms and inverting output.
    */
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            counter_1ms <= 0;
            op <= 0;
        end
        else begin
            if (counter_1ms >= 49999) begin
                counter_1ms <= 0;
                op <= ~ir; 
            end
            else begin
                counter_1ms <= counter_1ms + 1;
            end
        end
    end

endmodule
