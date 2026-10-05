/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: moisture_sensor.v
# File Description: Top-level moisture sensor module combining ADC controller and clock divider.
# Global variables: None
*/

module moisture_sensor(
    input  wire        dout, 
    input  wire        clk50,
    output wire        adc_cs_n, 
    output wire        din, 
    output wire        adc_sck,
    output wire [11:0] d_out_ch0
);

    // COUNTER: 4-bit free-running counter to generate ADC clock
    reg [3:0] counter;
    always @(posedge clk50) begin
        counter <= counter + 1;
    end

    assign adc_sck = counter[3]; // 50MHz / 16 = 3.125MHz

    // Inner ADC Controller
    adc_controller adc_inst(
        .dout(dout),
        .adc_sck(adc_sck),
        .adc_cs_n(adc_cs_n),
        .din(din),
        .d_out_ch0(d_out_ch0)
    );

endmodule