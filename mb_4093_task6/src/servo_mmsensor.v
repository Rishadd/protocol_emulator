/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: servo_mmsensor.v
# File Description: Servo-controlled moisture measurement arm FSM.
# Global variables: None
*/

module servo_mmsensor (
    input  wire        clk_50,        
    input  wire        reset,         
    input  wire        mpi_flag,      
    input  wire        adc_sdat,      
    output wire        adc_cs_n, 
    output wire        adc_sclk, 
    output wire        adc_saddr,     
    output wire        servo_pwm,
    output [11:0]      final_moisture_value,
    
    // NEW: The "Done" Signal
    output reg         measurement_done 
);

    // State Definitions
    localparam IDLE         = 3'b000;
    localparam MOVE_SWEEP   = 3'b001;
    localparam WAIT_2S      = 3'b010;
    localparam READ_ADC     = 3'b011;
    localparam MOVE_HOME    = 3'b100;
    localparam WAIT_RELEASE = 3'b101;

    reg [2:0]  current_state;
    reg [27:0] delay_timer; 
    reg        dip_signal;      // Controls servo direction
    reg [11:0] final_moisture_value_reg;

    // Output of the Moisture Module
    wire [11:0] live_moisture_data;

    assign final_moisture_value = final_moisture_value_reg;
    
    // --- Moisture Sensor Module Instance ---
    moisture_sensor moisture_unit (
        .dout(adc_sdat),
        .clk50(clk_50),
        .adc_cs_n(adc_cs_n),
        .din(adc_saddr),
        .adc_sck(adc_sclk), 
        .d_out_ch0(live_moisture_data)
    );

    // --- Servo Instance ---
    servo servo_inst (
        .clk(adc_sclk), 
        .reset(reset), 
        .dip_signal(dip_signal), 
        .pwm_out(servo_pwm)
    );

    // --- Main Control FSM ---
    /*
    Purpose:
    ---
    Controls servo arm: on MPI flag, sweep down, wait, read moisture,
    return home, and wait for flag to clear.
    */
    always @(posedge clk_50) begin
        if (!reset) begin
            current_state <= IDLE;
            dip_signal <= 0;
            delay_timer <= 0;
            final_moisture_value_reg <= 0;
            measurement_done <= 0; // Reset signal
        end else begin
            case (current_state)
                IDLE: begin
                    measurement_done <= 0; // Ensure it is low
                    dip_signal <= 0;
                    delay_timer <= 0;
                    if (mpi_flag) current_state <= MOVE_SWEEP;
                end

                MOVE_SWEEP: begin
                    dip_signal <= 1;          // Move to measurement position
                    if (delay_timer < 50_000_000) delay_timer <= delay_timer + 1;
                    else begin
                        delay_timer <= 0;
                        current_state <= WAIT_2S;
                    end
                end

                WAIT_2S: begin
                    // Allow sensor to settle
                    if (delay_timer < 100_000_000) delay_timer <= delay_timer + 1;
                    else begin
                        delay_timer <= 0;
                        current_state <= READ_ADC;
                    end
                end

                READ_ADC: begin
                    // Grab the result
                    final_moisture_value_reg <= live_moisture_data;
                    
                    // Signal that we are done!
                    measurement_done <= 1; 
                    
                    current_state <= MOVE_HOME;
                end

                MOVE_HOME: begin
                    // Clear the done signal
                    measurement_done <= 0; 
                    
                    dip_signal <= 0;           // Return to home
                    if (delay_timer < 50_000_000) delay_timer <= delay_timer + 1;
                    else begin
                        delay_timer <= 0;
                        current_state <= WAIT_RELEASE;
                    end
                end

                WAIT_RELEASE: begin
                    if (!mpi_flag) current_state <= IDLE;
                end
                
                default: begin
                    current_state <= IDLE;
                    measurement_done <= 0;
                end
            endcase
        end
    end
endmodule