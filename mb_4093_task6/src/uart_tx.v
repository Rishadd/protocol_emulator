/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: uart_tx.v
# File Description: UART transmitter for 115200 baud with parity (parity fixed to 1 in current logic).
# Global variables: None
*/

module uart_tx(
    input clk_3125,
    input parity_type,tx_start,
    input [7:0] data,
    output reg tx, tx_done
);

initial begin
    tx = 1'b1;
    tx_done = 1'b0;
end

 // --- Parameters ---
    
    // BAUD_CYCLES: 3.125Mhz / 27 = 115740 Hz (closest to 115200 baud)
	 // BAUD_CYCLES: 50Mhz / 434 = 115200 Hz (closest to )
    parameter BAUD_CYCLES = 434;
    
    // FSM state definitions
    parameter S_IDLE         = 3'd0; // S_IDLE: Idle state, waiting for tx_start
    parameter S_START_BIT  = 3'd1; // S_START_BIT: Transmitting the start bit
    parameter S_DATA_BITS  = 3'd2; // S_DATA_BITS: Transmitting the 8 data bits
    parameter S_PARITY_BIT = 3'd3; // S_PARITY_BIT: Transmitting the parity bit
    parameter S_STOP_BIT   = 3'd4; // S_STOP_BIT: Transmitting the stop bit

    // --- Internal Registers & Wires ---

    // state: Holds the current state of the FSM
    reg [2:0] state = S_IDLE;

    // bit_index: Counter for which data bit is being sent (0-7)
    reg [2:0] bit_index; 
    // baud_counter: Counter to divide clk_3125 to get the baud rate
    reg [15:0] baud_counter = 0;
    
    // baud_tick: Pulses high for one clock when baud_counter reaches max
    wire baud_tick;
    assign baud_tick = (baud_counter == BAUD_CYCLES - 1);


    // --- 1. Baud Rate Generator (Sequential) ---
    always @(posedge clk_3125) begin
    /*
    Purpose:
    ---
    Generates a single-cycle 'baud_tick' pulse every 27 clock cycles.
    It only runs when the FSM is not in the IDLE state.
    */
        if (state == S_IDLE) begin
            baud_counter <= 0;
        end else begin
            if (baud_tick) begin
                baud_counter <= 0; // Reset counter
            end else begin
                baud_counter <= baud_counter + 1; // Increment counter
            end
        end
    end


    // --- 2. Main FSM (Sequential) ---
    always @(posedge clk_3125) begin
    /*
    Purpose:
    ---
    This is the main state machine. It controls the state transitions
    and updates internal registers (like bit_index) based
    on 'tx_start' and 'baud_tick'.
    */
        case (state)
            
            S_IDLE: begin
                if (tx_start == 1) begin
                    // Reset bit index and start transmission
                    bit_index <= 0;
                    state <= S_START_BIT;
                end
            end
            
            S_START_BIT: begin
                if (baud_tick) begin
                    state <= S_DATA_BITS;
                end
            end
            
            S_DATA_BITS: begin
                if (baud_tick) begin
                    if (bit_index == 7) begin
                        state <= S_PARITY_BIT;
                    end else begin
                        bit_index <= bit_index + 1;
                    end
                end
            end
            
            S_PARITY_BIT: begin
                if (baud_tick) begin
                    state <= S_STOP_BIT;
                end
            end
            
            S_STOP_BIT: begin
                if (baud_tick) begin
                    state <= S_IDLE; // Go back to IDLE
                end
            end
            
            default: begin
                state <= S_IDLE;
            end
            
        endcase
    end


    // --- 3. Output Logic (Combinatorial) ---
    always @(*) begin
    /*
    Purpose:
    ---
    Drives the 'tx' and 'tx_done' outputs combinatorially based
    on the current FSM state. This prevents any one-clock-cycle
    delays and ensures outputs match the testbench.
    */
        // Set default values for outputs
        tx = 1;      // Idle HIGH
        tx_done = 0; // Default LOW
        
        case (state)
            S_IDLE:
                tx = 1;
                
            S_START_BIT:
                tx = 0;
                
            S_DATA_BITS:
                // Read directly from the 'data' input, reversing bits for TB
                tx = data[bit_index ]; 
                
            S_PARITY_BIT:
//                // Calculate and transmit parity on-the-fly
//                if (parity_type == 1'b0) begin
//                    tx = ^data; // Even parity (XOR)
//                end else begin
//                    tx = ~(^data); // Odd parity (XNOR)
//                end
					tx = 1;
                
            S_STOP_BIT: begin
                tx = 1; // Stop bit is HIGH
                
                // Pulse tx_done HIGH only on the last clock
                // cycle of the S_STOP_BIT state.
                if (baud_tick == 1) begin
                    tx_done = 1;
                end
            end
            
            default:
                tx = 1;
        endcase
    end

endmodule

