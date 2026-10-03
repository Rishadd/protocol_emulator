/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: drive.v
# File Description: Motor driver PWM generator for two motors with direction control.
# Global variables: None
*/

module drive(
    input clk_50M, reset_n,
    input [6:0] duty_l,    // 0 to 100 Speed
    input [6:0] duty_r,    // 0 to 100 Speed
    input dir_l,           // 1 = Forward, 0 = Reverse
    input dir_r,           // 1 = Forward, 0 = Reverse
    output reg IN1, IN2, IN3, IN4,
	output ENA,ENB
);

    // PRESCALER_MAX: 500 gives 100 kHz tick from 50 MHz
    reg [14:0] prescaler;
    reg [6:0] cnt;         // 7-bit counter for 0-100
    
    // 50MHz / 500 = 100kHz tick
    // 100kHz / 100 steps = 1kHz PWM frequency
    wire tick = (prescaler == 500); 

    /*
    Purpose:
    ---
    Generate PWM counter and prescaler for speed control.
    */
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            prescaler <= 0;
            cnt <= 0;
        end else begin
            prescaler <= tick ? 0 : prescaler + 1;
            
            if (tick) begin
                if (cnt >= 100) cnt <= 0;
                else cnt <= cnt + 1;
            end
        end
    end

    assign ENA = (cnt < duty_l);
    assign ENB = (cnt < duty_r);

    /*
    Purpose:
    ---
    Set H-bridge control signals based on direction.
    */
    always @(posedge clk_50M) begin
        IN1 <= dir_l ? 1'b1 : 1'b0;
        IN2 <= dir_l ? 1'b0 : 1'b1;
        
        IN3 <= dir_r ? 1'b1 : 1'b0;
        IN4 <= dir_r ? 1'b0 : 1'b1;
		  
    end

endmodule
