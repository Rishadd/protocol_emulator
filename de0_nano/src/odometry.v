/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: odometry.v
# File Description: Wheel encoder counter with direction and clear.
# Global variables: None
*/

module odometry(
    input clk_50M, reset_n,
    input enc_l_a,
    input enc_r_a,      
    input dir_l,        // (1=Fwd, 0=Rev)
    input dir_r,        
    input clear,        // NEW: High = Reset counts to 0, Low = Count
    output reg signed [16:0] left_count, // Signed is important for turning logic
    output reg signed [16:0] right_count
);

    // Previous values for edge detection
    reg prev_l, prev_r;

    /*
    Purpose:
    ---
    Count encoder pulses for left and right wheels.
    Direction determines increment/decrement.
    Clear signal resets counts to a known offset (1000) to avoid negative after reset.
    */
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            left_count  <= 0;
            right_count <= 0;
            prev_l <= 1;
            prev_r <= 1;
        end 
        else if (clear) begin
            left_count  <= 17'd1000;
            right_count <= 17'd1000;
            prev_l <= enc_l_a; 
            prev_r <= enc_r_a;
        end
        else begin
            // ================= LEFT MOTOR =================
            if (!prev_l && enc_l_a) 
                 left_count <= dir_l ? left_count + 1 : left_count - 1;
            prev_l <= enc_l_a;

            // ================= RIGHT MOTOR =================
            if (!prev_r && enc_r_a) 
                 right_count <= dir_r ? right_count + 1 : right_count - 1;
            prev_r <= enc_r_a;
        end
    end

endmodule