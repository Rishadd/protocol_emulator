/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: bt_messenger.v
# File Description: Bluetooth message formatter that sends MPI, moisture, temp/hum, END, and ASCII maze data.
# Global variables: None
*/

module bt_messenger(
    input clk,             
    input reset,           
    
    input send_mpi,        
    input send_mm,         
    input send_th,         
    input send_end,        
    input send_coord,      
    
    input [3:0]  mpi_id,       
    input [11:0] moisture_val, 
    input [7:0] temp_int,      
    input [7:0] temp_dec,      
    input [7:0] hum_int,       
    input [7:0] hum_dec,       
    
    // --- Map Memory Inputs ---
    input [80:0] visited_cells, 
    input [80:0] wall_north,
    input [80:0] wall_east,

    output tx,
    output reg busy
);

    // MOISTURE_THRESHOLD: Value above which soil is considered dry
    parameter MOISTURE_THRESHOLD = 12'd2650; 

    reg [7:0] tx_data;      // Byte to transmit
    reg tx_start;           // Pulse to start UART transmission
    wire tx_done;           // UART transmission complete flag
    
    uart_tx uart_inst (.clk_3125(clk), .parity_type(1'b1), .tx_start(tx_start), .data(tx_data), .tx(tx), .tx_done(tx_done));

    // ASCII character constants
    localparam CHAR_HASH    = 8'h23; 
    localparam CHAR_DASH    = 8'h2D; 
    localparam CHAR_NEWLINE = 8'h0A; 
    localparam CHAR_SPACE   = 8'h20; 
    localparam CHAR_PLUS    = 8'h2B; // "+"
    localparam CHAR_PIPE    = 8'h7C; // "|"
    localparam CHAR_DOT     = 8'h2E; // "."
    localparam CHAR_X       = 8'h58; // "X"
    
    // Restored letters for Moisture and End messages
    localparam CHAR_M       = 8'h4D; // "M"
    localparam CHAR_D       = 8'h44; // "D"
    localparam CHAR_E       = 8'h45; // "E"
    localparam CHAR_N       = 8'h4E; // "N"

    // FSM states
    localparam S_IDLE = 0, S_TX = 1, S_WAIT = 2;
    reg [2:0] state = S_IDLE;
    reg [7:0] char_index;      // Index of character being sent in current message
    reg [2:0] msg_type;        // 1=MPI, 2=MM, 3=TH, 4=END, 5=COORD

    // Advanced Grid Tracking for ASCII maze
    reg [3:0] grid_row;        // Current row (0-8) while building maze
    reg [3:0] grid_col;        // Current column (0-8) while building maze
    reg [2:0] maze_phase;      // 0=Header, 1=Ceilings, 2=Rooms, 3=BottomFloor, 4=Footer
    reg       cell_step;       // 0=Wall/Corner, 1=Path/Cell

    // Helper functions to convert numbers to ASCII
    function [7:0] get_digit_ascii; input [3:0] val; begin get_digit_ascii = 8'h30 + val; end endfunction
    function [7:0] get_tens_ascii; input [7:0] val; begin get_tens_ascii = 8'h30 + (val / 10); end endfunction
    function [7:0] get_units_ascii; input [7:0] val; begin get_units_ascii = 8'h30 + (val % 10); end endfunction

    /*
    Purpose:
    ---
    Main FSM that sequences message transmission. Handles both simple messages
    and the multi‑phase maze generation.
    */
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= S_IDLE; tx_start <= 0; busy <= 0; char_index <= 0; 
            grid_row <= 8; grid_col <= 0; maze_phase <= 0; cell_step <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    busy <= 0; tx_start <= 0; char_index <= 0; 
                    grid_row <= 8; grid_col <= 0; maze_phase <= 0; cell_step <= 0;
                    
                    if (send_mpi) begin msg_type <= 1; state <= S_TX; busy <= 1; end 
                    else if (send_mm) begin msg_type <= 2; state <= S_TX; busy <= 1; end 
                    else if (send_th) begin msg_type <= 3; state <= S_TX; busy <= 1; end 
                    else if (send_end) begin msg_type <= 4; state <= S_TX; busy <= 1; end 
                    else if (send_coord) begin msg_type <= 5; state <= S_TX; busy <= 1; end
                end

                S_TX: begin
                    tx_start <= 1; state <= S_WAIT;
                    
                    // Select character based on message type and current index
                    case (msg_type)
                        1: case (char_index) 0: tx_data<="M"; 1: tx_data<="P"; 2: tx_data<="I"; 3: tx_data<="M"; 4: tx_data<=CHAR_DASH; 5: tx_data<=get_digit_ascii(mpi_id); 6: tx_data<=CHAR_DASH; 7: tx_data<=CHAR_HASH; 8: tx_data<=CHAR_NEWLINE; default: state<=S_IDLE; endcase
                        2: case (char_index) 0: tx_data<="M"; 1: tx_data<="M"; 2: tx_data<=CHAR_DASH; 3: tx_data<=get_digit_ascii(mpi_id); 4: tx_data<=CHAR_DASH; 5: tx_data<=(moisture_val>MOISTURE_THRESHOLD)?CHAR_D:CHAR_M; 6: tx_data<=CHAR_DASH; 7: tx_data<=CHAR_HASH; 8: tx_data<=CHAR_NEWLINE; default: state<=S_IDLE; endcase
                        3: case (char_index) 0: tx_data<="T"; 1: tx_data<="H"; 2: tx_data<=CHAR_DASH; 3: tx_data<=get_digit_ascii(mpi_id); 4: tx_data<=CHAR_DASH; 5: tx_data<=get_tens_ascii(temp_int); 6: tx_data<=get_units_ascii(temp_int); 7: tx_data<=CHAR_DASH; 8: tx_data<=get_tens_ascii(hum_int); 9: tx_data<=get_units_ascii(hum_int); 10: tx_data<=CHAR_DASH; 11: tx_data<=CHAR_HASH; 12: tx_data<=CHAR_NEWLINE; default: state<=S_IDLE; endcase
                        4: case (char_index) 0: tx_data<="E"; 1: tx_data<="N"; 2: tx_data<="D"; 3: tx_data<=CHAR_DASH; 4: tx_data<=CHAR_HASH; 5: tx_data<=CHAR_NEWLINE; default: state<=S_IDLE; endcase
                           
                        // === Message 5: ASCII MAZE GENERATOR ===
                        5: case (maze_phase)
                            0: begin // Header
                                if (char_index==0) tx_data<="M"; else if (char_index==1) tx_data<="A"; else if (char_index==2) tx_data<="Z"; else if (char_index==3) tx_data<="E"; else if (char_index==4) tx_data<=":"; else if (char_index==5) tx_data<=CHAR_NEWLINE;
                            end
                            
                            1: begin // Ceilings (North Walls)
                                if (grid_col == 9) begin
                                    tx_data <= (cell_step == 0) ? CHAR_PLUS : CHAR_NEWLINE;
                                end else begin
                                    if (cell_step == 0) tx_data <= CHAR_PLUS;
                                    else tx_data <= (wall_north[(grid_row * 9) + grid_col] || grid_row == 8) ? CHAR_DASH : CHAR_SPACE;
                                end
                            end

                            2: begin // Rooms (Visited & East Walls)
                                if (grid_col == 9) begin
                                    tx_data <= (cell_step == 0) ? CHAR_PIPE : CHAR_NEWLINE;
                                end else begin
                                    if (cell_step == 0) tx_data <= (grid_col == 0 || wall_east[(grid_row * 9) + grid_col - 1]) ? CHAR_PIPE : CHAR_SPACE;
                                    else tx_data <= visited_cells[(grid_row * 9) + grid_col] ? CHAR_X : CHAR_DOT;
                                end
                            end

                            3: begin // Bottom Floor (Y=0)
                                if (grid_col == 9) begin
                                    tx_data <= (cell_step == 0) ? CHAR_PLUS : CHAR_NEWLINE;
                                end else begin
                                    if (cell_step == 0) tx_data <= CHAR_PLUS;
                                    else tx_data <= CHAR_DASH;
                                end
                            end

                            4: begin // Footer
                                if (char_index==0) tx_data<=CHAR_DASH; else if (char_index==1) tx_data<=CHAR_HASH; else if (char_index==2) tx_data<=CHAR_NEWLINE; else state<=S_IDLE;
                            end
                        endcase
                    endcase
                    if (state == S_IDLE) begin tx_start <= 0; busy <= 0; end
                end

                S_WAIT: begin
                    tx_start <= 0;
                    if (tx_done) begin
                        state <= S_TX;
                        
                        // Update counters based on message type
                        if (msg_type == 5) begin
                            // Maze generation requires complex state updates
                            if (maze_phase == 0) begin
                                if (char_index == 5) begin maze_phase <= 1; char_index <= 0; end 
                                else char_index <= char_index + 1;
                            end 
                            else if (maze_phase == 1 || maze_phase == 2 || maze_phase == 3) begin 
                                if (cell_step == 0) cell_step <= 1;
                                else begin // cell_step == 1
                                    cell_step <= 0;
                                    if (grid_col == 9) begin 
                                        grid_col <= 0;
                                        if (maze_phase == 1) maze_phase <= 2;
                                        else if (maze_phase == 2) begin
                                            if (grid_row == 0) maze_phase <= 3;
                                            else begin grid_row <= grid_row - 1; maze_phase <= 1; end 
                                        end
                                        else if (maze_phase == 3) maze_phase <= 4;
                                    end else begin
                                        grid_col <= grid_col + 1;
                                    end
                                end
                            end
                            else if (maze_phase == 4) begin 
                                if (char_index == 2) state <= S_IDLE; else char_index <= char_index + 1;
                            end
                        end else begin
                            char_index <= char_index + 1;
                        end
                    end
                end
            endcase
        end
    end
endmodule