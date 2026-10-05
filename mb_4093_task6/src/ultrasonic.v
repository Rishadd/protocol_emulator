/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: ultrasonic.v
# File Description: Ultrasonic sensor ranging with median filter and hysteresis.
# Global variables: None
*/

module ultrasonic(
    input clk_50M, reset_n, echo,
    input [15:0] threshold,
    output reg trig,
    output reg op,
    output reg [15:0] distance
);

    parameter IDLE        = 0;
    parameter TRIGGER     = 1;
    parameter WAIT_FOR_ECHO = 2;
    parameter MEASURE_ECHO  = 3;
    parameter COOL_DOWN     = 4;
    
    // Hysteresis parameters
    parameter HYST_COUNT_THRESHOLD = 5;
    parameter WALL_DETECT_THRESHOLD = 3;
    parameter WALL_OPEN_THRESHOLD = 1;

    reg [21:0] count = 0;
    reg [2:0] state = 0;
    
    // History Buffers for Median Filter (3-Tap)
    reg [15:0] d0, d1, d2; 
    reg [15:0] raw_dist;
    
    // Hysteresis counter
    reg [3:0] wall_count = 0;

    // --- 3-TAP MEDIAN FILTER FUNCTION ---
    function [15:0] get_median;
        input [15:0] a, b, c;
        begin
            // Sort to find the middle value
            if ((a >= b && a <= c) || (a >= c && a <= b)) get_median = a;
            else if ((b >= a && b <= c) || (b >= c && b <= a)) get_median = b;
            else get_median = c;
        end
    endfunction

    initial begin
        trig = 0;
        d0 = 100; d1 = 100; d2 = 100;
        distance = 100;
        op = 0;
        wall_count = 0;
    end

    /*
    Purpose:
    ---
    Ultrasonic measurement FSM:
    1. Trigger pulse.
    2. Wait for echo rising edge.
    3. Measure echo pulse width, convert to distance.
    4. Apply median filter and hysteresis for wall detection.
    5. Cool down before next measurement.
    */
    always @(posedge clk_50M) begin
        if (~reset_n) begin
            state <= IDLE; 
            count <= 0; 
            trig <= 0;
            d0 <= 100; d1 <= 100; d2 <= 100;
            distance <= 100;
            op <= 0;
            wall_count <= 0;
        end
        else begin
            case(state)
                IDLE: begin
                    count <= 0;
                    state <= TRIGGER;
                end
                
                TRIGGER: begin
                    if (count < 500) begin  // 10us trigger pulse @ 50MHz
                        count <= count + 1;
                        trig <= 1;
                    end
                    else begin
                        count <= 0;
                        trig <= 0;
                        state <= WAIT_FOR_ECHO;
                    end
                end
                
                WAIT_FOR_ECHO: begin
                    if (echo == 1) begin
                        count <= 0;
                        state <= MEASURE_ECHO;
                    end
                    else begin
                        // Reduced timeout for faster recovery
                        if (count > 750000) state <= COOL_DOWN;
                        else count <= count + 1;
                    end
                end
                
                MEASURE_ECHO: begin
                    if (echo == 1) begin
                        count <= count + 1;
                    end
                    else begin
                        // 1. Calculate Raw Distance
                        raw_dist = (count * 34) / 10000;
                        
                        // 2. Shift History (3-tap buffer)
                        d2 <= d1;
                        d1 <= d0;
                        d0 <= raw_dist;
                        
                        // 3. Apply 3-Tap Median Filter
                        distance <= get_median(raw_dist, d0, d1);
                        
                        // 4. Hysteresis Logic
                        if (get_median(raw_dist, d0, d1) < threshold) begin
                            // Wall detected - increment counter
                            if (wall_count < HYST_COUNT_THRESHOLD)
                                wall_count <= wall_count + 1;
                        end
                        else begin
                            // No wall - decrement counter
                            if (wall_count > 0)
                                wall_count <= wall_count - 1;
                        end
                        
                        // 5. Update output based on hysteresis thresholds
                        if (wall_count >= WALL_DETECT_THRESHOLD)
                            op <= 1;  // Wall detected
                        else if (wall_count <= WALL_OPEN_THRESHOLD)
                            op <= 0;  // Wall open
                        
                        count <= 0;
                        state <= COOL_DOWN;
                    end
                end
                
                COOL_DOWN: begin
                    if (count < 250000) begin  // 5ms @ 50MHz
                        count <= count + 1;
                    end
                    else begin
                        state <= IDLE;
                    end
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule