/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: uart_rx.v
# File Description: UART receiver for 115200 baud, 8N1.
# Global variables: None
*/

module uart_rx(
    input clk_50,
    input rx,
    output reg [7:0] rx_msg,
    output reg rx_complete
    // Note: 'rx_parity' output is removed because 8N1 has no parity
    );

    // --- Parameters for 115200 Baud at 50 MHz ---
    parameter CLKS_PER_BIT = 434;
    parameter CLKS_PER_BIT_HALF = 217;

    // --- State Definitions ---
    parameter S_IDLE   = 3'd0;
    parameter S_START  = 3'd1;
    parameter S_DATA   = 3'd2;
    parameter S_STOP   = 3'd3; // Moved Stop to 3

    reg [2:0] state = S_IDLE;
    reg [8:0] clk_count = 0; 
    reg [2:0] bit_index = 0; 
    reg [7:0] rx_data_reg;   

    initial begin
        rx_msg = 0;
        rx_complete = 0;
    end

    /*
    Purpose:
    ---
    UART receiver FSM: samples start bit, then 8 data bits, then stop bit.
    Uses oversampling at 50MHz to achieve 115200 baud.
    */
    always @(posedge clk_50) begin
        rx_complete <= 1'b0;
        
        case (state)
            // 1. IDLE
            S_IDLE: begin
                clk_count <= 0;
                bit_index <= 0;
                if (rx == 1'b0) state <= S_START;
            end
            
            // 2. START BIT
            S_START: begin
                if (clk_count == CLKS_PER_BIT_HALF) begin
                    if (rx == 1'b1) state <= S_IDLE; 
                end
                if (clk_count == CLKS_PER_BIT - 1) begin 
                    state <= S_DATA;
                    clk_count <= 0;
                end else clk_count <= clk_count + 1;
            end
            
            // 3. DATA BITS (0-7)
            S_DATA: begin
                if (clk_count == CLKS_PER_BIT_HALF) begin
                    rx_data_reg[bit_index] <= rx; 
                end
                if (clk_count == CLKS_PER_BIT - 1) begin 
                    clk_count <= 0;
                    if (bit_index == 7) begin
                        state <= S_STOP; // <--- Jump straight to STOP (Skip Parity)
                    end else begin
                        bit_index <= bit_index + 1; 
                    end
                end else clk_count <= clk_count + 1;
            end
            
            // 4. STOP BIT
            S_STOP: begin
                // Check at cycle 10 (Fast Exit for Bursts)
                if (clk_count == 10) begin 
                    rx_complete <= 1'b1; 
                    rx_msg <= rx_data_reg; // No parity check needed
                    state <= S_IDLE;
                end else clk_count <= clk_count + 1;
            end
            
            default: state <= S_IDLE;
        endcase
    end
endmodule