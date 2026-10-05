/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: bt_receiver.v
# File Description: Bluetooth receiver that decodes "START-X-#" command and outputs start signal and count.
# Global variables: None
*/

module bt_receiver(
    input clk_50,         // 50 MHz Clock
    input reset,          // System Reset
    input rx,             // RX Pin (Connect to Bluetooth TX)
    output reg start_signal, // Goes HIGH when "START-X-#" is received
    output reg [3:0] mpi_count // Stores the 'X' value (e.g., 4)
);

    // --- Internal Signals ---
    wire [7:0] rx_msg;     // The character received
    wire rx_ready;         // Flag when a new character is ready

    // --- Instantiate the 8N1 UART Receiver ---
    uart_rx uart_inst (
        .clk_50(clk_50),
        .rx(rx),
        .rx_msg(rx_msg),
        .rx_complete(rx_ready)
    );

    // --- ASCII Constants ---
    localparam CHAR_S    = 8'h53; // 'S'
    localparam CHAR_T    = 8'h54; // 'T'
    localparam CHAR_A    = 8'h41; // 'A'
    localparam CHAR_R    = 8'h52; // 'R'
    localparam CHAR_DASH = 8'h2D; // '-'
    localparam CHAR_HASH = 8'h23; // '#'

    // --- State Machine ---
    localparam IDLE      = 0;
    localparam WAIT_T1   = 1;
    localparam WAIT_A    = 2;
    localparam WAIT_R    = 3;
    localparam WAIT_T2   = 4;
    localparam WAIT_D1   = 5; // First Dash
    localparam GET_NUM   = 6; // The Number
    localparam WAIT_D2   = 7; // Second Dash
    localparam WAIT_HASH = 8; // The terminator '#'
    localparam DONE      = 9;

    reg [3:0] state = IDLE;

    /*
    Purpose:
    ---
    FSM that matches the exact sequence "START-X-#" and extracts X.
    On success, raises start_signal and stores X in mpi_count.
    */
    always @(posedge clk_50 or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            start_signal <= 0;
            mpi_count <= 0;
        end else begin
            
            // We only check logic when a new byte arrives
            if (rx_ready) begin
                case (state)
                    
                    // Sequence: S
                    IDLE: begin
                        if (rx_msg == CHAR_S) state <= WAIT_T1;
                    end

                    // Sequence: S -> T
                    WAIT_T1: begin
                        if (rx_msg == CHAR_T) state <= WAIT_A;
                        else if (rx_msg == CHAR_S) state <= WAIT_T1; // Re-start if 'S'
                        else state <= IDLE;
                    end

                    // Sequence: S -> T -> A
                    WAIT_A: begin
                        if (rx_msg == CHAR_A) state <= WAIT_R;
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end

                    // Sequence: S -> T -> A -> R
                    WAIT_R: begin
                        if (rx_msg == CHAR_R) state <= WAIT_T2;
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end

                    // Sequence: S -> T -> A -> R -> T
                    WAIT_T2: begin
                        if (rx_msg == CHAR_T) state <= WAIT_D1;
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end

                    // Sequence: S -> T -> A -> R -> T -> -
                    WAIT_D1: begin
                        if (rx_msg == CHAR_DASH) state <= GET_NUM;
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end

                    // Sequence: ... - -> [NUMBER]
                    GET_NUM: begin
                        // Check if character is a digit '0' (0x30) to '9' (0x39)
                        if (rx_msg >= 8'h30 && rx_msg <= 8'h39) begin
                            // Convert ASCII to Integer (e.g., '4' -> 4)
                            mpi_count <= rx_msg - 8'h30; 
                            state <= WAIT_D2;
                        end 
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end

                    // Sequence: ... [NUMBER] -> -
                    WAIT_D2: begin
                        if (rx_msg == CHAR_DASH) state <= WAIT_HASH;
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end

                    // Sequence: ... - -> #
                    WAIT_HASH: begin
                        if (rx_msg == CHAR_HASH) begin
                            start_signal <= 1; // TRIGGER THE ROBOT!
                            state <= DONE;
                        end 
                        else if (rx_msg == CHAR_S) state <= WAIT_T1;
                        else state <= IDLE;
                    end
                    
                    // Stay here until reset (or you can add logic to restart)
                    DONE: begin
                        // start_signal remains High
                    end

                endcase
            end
        end
    end

endmodule