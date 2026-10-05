/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: mpi_top.v
# File Description: Top module for MPI (moisture probe interface) that coordinates sensor readings and Bluetooth messages.
# Global variables: None
*/

module mpi_top(
    input clk,              // 50 MHz Clock
    input reset_n,          // Reset button (Active Low) - PIN_J15
    
    // --- Sensors ---
    input mpi_flag_pin,     // IR/Proximity Sensor
    inout dht_data_pin,     // DHT11 Data Pin
	 input send_end,         //Trigger to send END-#,
    
    // --- Configuration Input ---
    input [3:0] mpi_id,     // Input to select the current ID (e.g., from Switches)
    
    // --- Servo Output ---
    output servo_pwm_pin,   // Connect to Servo Signal Wire

    // --- ADC Pins ---
    input  adc_sdat,        
    output adc_cs_n,        
    output adc_sclk,        
    output adc_saddr,       

    // --- Bluetooth ---
    output bt_tx_pin,       // Bluetooth RXD
    
    // --- Status Output ---
    output reg mpi_done     // High when sequence is finished
);

    // ==========================================
    // STATE DEFINITIONS
    // ==========================================
    localparam STATE_IDLE            = 3'd0;
    localparam STATE_WAIT_MEASUREMENT = 3'd1;
    localparam STATE_MM_WAIT_GAP     = 3'd2;
    localparam STATE_SEND_TH         = 3'd3;
    localparam STATE_WAIT_TH_COMPLETE = 3'd4;
    localparam STATE_RESET_DEBOUNCE  = 3'd5;

    // ==========================================
    // SIGNAL DECLARATIONS
    // ==========================================
    wire [7:0] dht_temp_int, dht_temp_dec, dht_rh_int, dht_rh_dec;
    wire dht_valid;
    wire [11:0] adc_raw_value; 
    wire servo_measurement_done;

    // Storage registers for DHT data
    reg [7:0] stored_temp_int = 0;
    reg [7:0] stored_temp_dec = 0;
    reg [7:0] stored_hum_int  = 0;
    reg [7:0] stored_hum_dec  = 0;

    reg send_mpi = 0;
    reg send_mm  = 0;
    reg send_th  = 0;
    wire busy; 
    
    reg [2:0] master_state = STATE_IDLE;
    reg last_mpi_state = 0;      // For edge detection on mpi_flag_pin
    
    // Timer to space out the messages
    reg [31:0] spacing_timer = 0;

    // ==========================================
    // DHT SENSOR INSTANTIATION
    // ==========================================
    dht my_dht_sensor (
        .clk_50M(clk),
        .reset(1'b1), 
        .sensor(dht_data_pin),
        .T_integral(dht_temp_int),
        .RH_integral(dht_rh_int),
        .T_decimal(dht_temp_dec),
        .RH_decimal(dht_rh_dec),
        .data_valid(dht_valid)
    );
    
    /*
    Purpose:
    ---
    Latch DHT data when valid.
    */
    always @(posedge clk) begin
        if (dht_valid) begin
            stored_temp_int <= dht_temp_int;
            stored_temp_dec <= dht_temp_dec;
            stored_hum_int  <= dht_rh_int;
            stored_hum_dec  <= dht_rh_dec;
        end
    end

    // ==========================================
    // SERVO & MOISTURE SENSOR INSTANTIATION
    // ==========================================
    servo_mmsensor arm_controller (
        .clk_50(clk),
        .reset(reset_n), 
        .mpi_flag(mpi_flag_pin),   
        .adc_sdat(adc_sdat),
        .adc_cs_n(adc_cs_n),
        .adc_sclk(adc_sclk),
        .adc_saddr(adc_saddr),
        .servo_pwm(servo_pwm_pin),
        .final_moisture_value(adc_raw_value), 
        .measurement_done(servo_measurement_done) 
    );

    // ==========================================
    // BLUETOOTH MESSENGER INSTANTIATION
    // ==========================================
    bt_messenger my_messenger (
        .clk(clk),
        .reset(1'b0), 
        .send_mpi(send_mpi),
        .send_mm(send_mm),
        .send_th(send_th),
        .mpi_id(mpi_id), 
		  .send_end(send_end),
        .moisture_val(adc_raw_value), 
        .temp_int(stored_temp_int),
        .temp_dec(stored_temp_dec),
        .hum_int(stored_hum_int),
        .hum_dec(stored_hum_dec),
        .tx(bt_tx_pin),
        .busy(busy)
    );

    // ==========================================
    // MASTER COORDINATOR FSM
    // ==========================================
    /*
    Purpose:
    ---
    Controls the sequence of operations when MPI flag is triggered:
    1. Send MPI message.
    2. Wait for servo arm to measure moisture.
    3. Send moisture message.
    4. Wait 1 second.
    5. Send temperature/humidity message.
    6. Wait 1 second and signal done.
    */
    always @(posedge clk) begin
        // Default assignments
        send_mpi <= 0;
        send_mm  <= 0;
        send_th  <= 0;
        mpi_done <= 0;

        last_mpi_state <= mpi_flag_pin;

        case (master_state)
            
            // STATE_IDLE: Waiting for MPI Flag trigger
            STATE_IDLE: begin
                spacing_timer <= 0; // Reset timer
                if (mpi_flag_pin == 1 && last_mpi_state == 0) begin
                    send_mpi <= 1;             // Send MPI message
                    master_state <= STATE_WAIT_MEASUREMENT;  
                end
            end

            // STATE_WAIT_MEASUREMENT: Waiting for arm to dip & measure moisture
            STATE_WAIT_MEASUREMENT: begin
                if (servo_measurement_done) begin
                    send_mm <= 1;             // Send moisture data
                    master_state <= STATE_MM_WAIT_GAP;
                end
            end

            // STATE_MM_WAIT_GAP: Wait 1 second after moisture transmission
            STATE_MM_WAIT_GAP: begin
                // 50,000,000 cycles = 1 second at 50 MHz
                if (spacing_timer < 50000000) begin
                    spacing_timer <= spacing_timer + 1;
                end else begin
                    spacing_timer <= 0;
                    master_state <= STATE_SEND_TH;
                end
            end

            // STATE_SEND_TH: Send temperature & humidity data
            STATE_SEND_TH: begin
                send_th <= 1;
                master_state <= STATE_WAIT_TH_COMPLETE;
            end

            // STATE_WAIT_TH_COMPLETE: Wait for TH transmission + 1 second
            STATE_WAIT_TH_COMPLETE: begin
                if (!busy) begin
                    // Bluetooth is not busy (TH transmission complete)
                    if (spacing_timer < 50000000) begin
                        spacing_timer <= spacing_timer + 1;
                    end else begin
                        spacing_timer <= 0;
                        mpi_done <= 1;        // All data transmitted and wait complete
                        master_state <= STATE_RESET_DEBOUNCE;
                    end
                end
            end

            // STATE_RESET_DEBOUNCE: Clear done signal and wait for MPI flag to go low
            STATE_RESET_DEBOUNCE: begin
                mpi_done <= 0;  // Clear done signal
                if (mpi_flag_pin == 0) begin
                    master_state <= STATE_IDLE; 
                end
            end
            
            default: master_state <= STATE_IDLE;
        endcase
    end

endmodule