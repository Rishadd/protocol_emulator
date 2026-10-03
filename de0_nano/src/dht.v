/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: dht.v
# File Description: DHT11 temperature and humidity sensor interface with FSM.
# Global variables: None
*/

module dht(
    input clk_50M,
    input reset,
    inout sensor,
    output reg [7:0] T_integral,
    output reg [7:0] RH_integral,
    output reg [7:0] T_decimal,
    output reg [7:0] RH_decimal,
    output reg [7:0] Checksum,
    output reg data_valid
);

    // ==========================================
    // Internal Signals
    // ==========================================
    reg sensor_out = 0;      // Output value when driving sensor line
    reg sensor_oe = 0;       // Output enable for tri-state
    reg [2:0] state = 0;     // FSM state
    reg [31:0] cnt = 0;      // General purpose counter
    reg [39:0] shift_reg = 0;// Shift register for incoming 40 bits
    reg [5:0] bit_cnt = 0;   // Counts received bits
    
    // Input Synchronization & Edge Detection
    reg sensor_sync1, sensor_in, sensor_last;

    // Tri-state buffer
    assign sensor = sensor_oe ? sensor_out : 1'bz;

    // State Definitions
    localparam IDLE         = 0,
               PULL_LOW     = 1,
               RELEASE_HIGH = 2,
               WAIT_LOW     = 3,
               WAIT_HIGH    = 4,
               READ_LOW     = 5,
               READ_HIGH    = 6,
               VALIDATE     = 7;

    initial begin
        T_integral = 0; RH_integral = 0;
        T_decimal = 0;  RH_decimal = 0;
        Checksum = 0;   data_valid = 0;
    end

    // ==========================================
    // Main FSM
    // ==========================================
    /*
    Purpose:
    ---
    Implements the DHT11 communication protocol:
    1. Host pulls line low for 18ms, then releases.
    2. Sensor responds with 80us low, 80us high.
    3. Sensor sends 40 data bits: each bit starts with 50us low,
       followed by high pulse length determining 0 (26-28us) or 1 (70us).
    4. After all bits, validate checksum.
    */
    always @(posedge clk_50M or negedge reset) begin
        if (!reset) begin
            state       <= IDLE;
            sensor_oe   <= 0;
            sensor_out  <= 1; 
            cnt         <= 0;
            bit_cnt     <= 0;
            shift_reg   <= 0;
            data_valid  <= 0;
            
            T_integral  <= 0; RH_integral <= 0;
            T_decimal   <= 0; RH_decimal  <= 0;
            Checksum    <= 0;
            
            sensor_sync1 <= 1;
            sensor_in    <= 1;
            sensor_last  <= 1;
        end 
        else begin
            // ----------------------------------------------
            // Edge Detection Pipeline
            // ----------------------------------------------
            sensor_sync1 <= sensor;       // Raw input
            sensor_in    <= sensor_sync1; // Stable input
            sensor_last  <= sensor_in;    // Previous cycle
            
            // Auto-clear data_valid
            if (data_valid) data_valid <= 0;

            case(state)
                // -------------------------------------------------
                // IDLE: Wait ~2 seconds
                // -------------------------------------------------
                IDLE: begin
                    sensor_oe <= 0;
                    if (cnt >= 100000000) begin 
                        state <= PULL_LOW;
                        cnt   <= 0;
                    end else cnt <= cnt + 1;
                end

                // -------------------------------------------------
                // PULL_LOW: Start Signal (18ms)
                // -------------------------------------------------
                PULL_LOW: begin
                    sensor_oe  <= 1;
                    sensor_out <= 0;
                    if (cnt >= 900000) begin 
                        sensor_oe <= 0;
                        state <= RELEASE_HIGH;
                        cnt   <= 0;
                    end else cnt <= cnt + 1;
                end

                // -------------------------------------------------
                // RELEASE_HIGH: Wait for Sensor Response (Falling Edge)
                // -------------------------------------------------
                RELEASE_HIGH: begin
                    sensor_oe <= 0;
                    
                    // Edge detection: wait for line to go from HIGH to LOW
                    if (sensor_last == 1 && sensor_in == 0) begin
                        state <= WAIT_LOW;
                        cnt   <= 0;
                    end
                    else if (cnt > 50000) begin // Timeout
                         state <= IDLE;
                         cnt <= 0;
                    end
                    else cnt <= cnt + 1;
                end

                // -------------------------------------------------
                // WAIT_LOW: Wait for Rising Edge (End of Presence Low)
                // -------------------------------------------------
                WAIT_LOW: begin
                    // Edge Detection: 0 -> 1
                    if (sensor_last == 0 && sensor_in == 1) begin
                        state <= WAIT_HIGH;
                        cnt   <= 0;
                    end
                end

                // -------------------------------------------------
                // WAIT_HIGH: Wait for Falling Edge (End of Presence High)
                // -------------------------------------------------
                WAIT_HIGH: begin
                    // Edge Detection: 1 -> 0
                    if (sensor_last == 1 && sensor_in == 0) begin
                        state   <= READ_LOW;
                        cnt     <= 0;
                        bit_cnt <= 0;
                    end
                end

                // -------------------------------------------------
                // READ_LOW: Wait for Rising Edge (Start of High Pulse)
                // -------------------------------------------------
                READ_LOW: begin
                    // Edge Detection: 0 -> 1
                    if (sensor_last == 0 && sensor_in == 1) begin
                        state <= READ_HIGH;
                        cnt   <= 0;
                    end
                end

                // -------------------------------------------------
                // READ_HIGH: Measure Pulse Width (Falling Edge Ends it)
                // -------------------------------------------------
                READ_HIGH: begin
                    // Detect Falling Edge (End of High Pulse)
                    if (sensor_last == 1 && sensor_in == 0) begin
                        // Threshold: 35us (1750 ticks) separates 0 and 1
                        if (cnt > 1750) 
                            shift_reg <= {shift_reg[38:0], 1'b1};
                        else
                            shift_reg <= {shift_reg[38:0], 1'b0};
                        
                        if (bit_cnt == 39) begin
                            state <= VALIDATE;
                        end else begin
                            bit_cnt <= bit_cnt + 1;
                            state   <= READ_LOW;
                        end
                    end 
                    // Timeout protection
                    else if (cnt > 5000) begin
                        state <= IDLE;
                        cnt <= 0;
                    end
                    else cnt <= cnt + 1;
                end

                // -------------------------------------------------
                // VALIDATE: Checksum
                // -------------------------------------------------
                VALIDATE: begin
                    // Checksum is sum of first 4 bytes; if matches 5th byte, data is valid
                    if ((shift_reg[39:32] + shift_reg[31:24] + 
                         shift_reg[23:16] + shift_reg[15:8]) == shift_reg[7:0]) begin
                        
                        RH_integral <= shift_reg[39:32];
                        RH_decimal  <= shift_reg[31:24];
                        T_integral  <= shift_reg[23:16];
                        T_decimal   <= shift_reg[15:8];
                        Checksum    <= shift_reg[7:0];
                        data_valid  <= 1;
                    end
                    
                    state <= IDLE;
                    cnt   <= 0;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

endmodule