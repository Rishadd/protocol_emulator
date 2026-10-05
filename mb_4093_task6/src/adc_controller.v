/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: adc_controller.v
# File Description: ADC controller for reading moisture sensor channel 0.
# Global variables: None
*/

module adc_controller(
    input  wire        dout, 
    input  wire        adc_sck,
    output wire        adc_cs_n, 
    output wire        din, 
    output reg [11:0]  d_out_ch0
);
    // Internal counters and registers
    reg [3:0]  din_counter = 0;   // Counts ADC clock cycles for CS toggle
    reg [3:0]  sp_counter = 0;    // Counts serial clock cycles within a frame
    reg        adc_cs = 1;         // Internal chip-select (active low output)
    reg [11:0] dout_chx = 0;       // Temporary shift register for incoming data

    /*
    Purpose:
    ---
    Toggle chip-select every 16 cycles to start a new ADC conversion.
    */
    always @(negedge adc_sck) begin
        din_counter <= din_counter + 1;
        if(din_counter == 15) adc_cs <= !adc_cs;
    end

    /*
    Purpose:
    ---
    Sample data bits from ADC on positive edges of serial clock.
    Bits arrive MSB first; store them in reverse order.
    */
    always @(posedge adc_sck) begin
        if((sp_counter >= 4) && (sp_counter <= 15)) begin
            // Data bits are valid from cycle 4 to 15
            dout_chx[15 - sp_counter] <= dout; 
        end
        sp_counter <= sp_counter + 1'b1;
    end

    /*
    Purpose:
    ---
    Latch the complete 12-bit value at the end of a frame.
    */
    always @(posedge adc_sck) begin
        if ((sp_counter == 15) && (!adc_cs)) begin
            d_out_ch0 <= dout_chx;
        end
    end

    assign adc_cs_n = adc_cs;   // Invert for active-low output
    assign din      = 1'b0;      // Fixed to Channel 0

endmodule
