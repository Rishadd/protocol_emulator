/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: motor.v
# File Description: Single motor PWM controller.
# Global variables: None
*/

module motor(
    input clk_50M, reset_n, dir,
    input [3:0] duty_cycle,
    output reg IN1, IN2,
	 output reg [3:0] LED
);

    // 100Hz PWM Config: 50MHz / 16 steps / 31250 ticks = 100Hz
    reg [14:0] prescaler;
    reg [3:0] cnt;
    wire tick = (prescaler == 31250);
    wire pwm_on = (cnt < duty_cycle);

    /*
    Purpose:
    ---
    Generate PWM counter and prescaler.
    */
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            prescaler <= 0;
            cnt <= 0;
				LED <= 0;
        end else begin
				LED <= duty_cycle;
            prescaler <= tick ? 0 : prescaler + 1;
            if (tick) cnt <= cnt + 1;
        end
    end

    /*
    Purpose:
    ---
    Drive H-bridge according to direction and PWM.
    */
    always @(posedge clk_50M) begin
        IN1 <= dir ? pwm_on : 1'b0;
        IN2 <= dir ? 1'b0 : pwm_on;
    end

endmodule