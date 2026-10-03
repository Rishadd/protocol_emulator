module robot_top_dd(
    // Clock and Reset
    input clk_50M, reset_n,
    
    // Sensor Inputs
    input us_echo_f, us_echo_l, us_echo_r,
    input ir_top, ir_down,
    input enc_l_a, enc_r_a,
    inout dht_data_pin,
    
    // Servo Output
    output servo_pwm_pin,

    // ADC Pins
    input  adc_sdat,        
    output adc_cs_n,        
    output adc_sclk,        
    output adc_saddr,        

    // Bluetooth
    input  bt_rx_pin,
    output bt_tx_pin,
    
    // Motor Driver Outputs
    output IN1, IN2, IN3, IN4, 
    output ENA, ENB,
    
    // Ultrasonic Triggers
    output us_trig_f, us_trig_l, us_trig_r,
    
    // Status Outputs
    output reg [2:0] wall_status,
    output reg [2:0] state_check,
    
    // Debug Outputs
    output reg signed [6:0] pd_check, 
    output reg [6:0] speed_l, speed_r,
    output reg signed [15:0] l_count, r_count,
    
    // Turn Counters
    output reg [6:0] count_turn_l,
    output reg [6:0] count_turn_r,
    output reg [6:0] count_turn_u
);

    // ==========================================
    // PARAMETERS
    // ==========================================
    
    // Speed Parameters
    localparam BASE_SPEED      = 7'd50;
    localparam TURN_SPEED_H    = 7'd50;
    localparam TURN_SPEED_L    = 7'd20;
    localparam TURN_SPEED_U    = 7'd50;
    localparam CRAWL_SPEED     = 7'd27;
    
    // Centering Parameters
    localparam signed K_CENTER = 7'sd2;
    
    // Ultrasonic Thresholds
    localparam thres_f = 16'd140;
    localparam thres_l = 16'd140;
    localparam thres_r = 16'd140;
    
    // Encoder Ticks for Turns
    localparam TICKS_L_90 = 16'd700;
    localparam TICKS_R_90 = 16'd780;
    localparam TICKS_180  = 16'd1500;
    
    // Timing Parameters
    localparam IDLE_DELAY       = 27'd100_000_000; // 2 seconds at 50MHz clock
    localparam MPI_WAIT_DELAY   = 27'd25_000_000;  // 0.5s wait before dipping
    localparam CRAWL_REV_DELAY  = 27'd70_000_000;  
    localparam SWITCH_DELAY     = 27'd50_000_000;  
    localparam FINAL_DELAY      = 27'd250_000_000; // 5 seconds at 50MHz clock
    
    // FSM States
    localparam IDLE               = 0;
    localparam FOLLOW             = 1;
    localparam TURN_L_READY       = 2;
    localparam TURN_L_PERFORM     = 3;
    localparam TURN_R_READY       = 4;
    localparam TURN_R_PERFORM     = 5;
    localparam CRAWL_REV          = 6;
    localparam CRAWL_FWD          = 7;
    localparam MEASURE_WAIT       = 8;
    localparam MEASURE_ACTIVE     = 9;
    localparam UTURN_READY        = 10;
    localparam UTURN_PERFORM      = 11;
    localparam FINAL_FOLLOW       = 12;
    localparam STOP               = 13;
    
    // Motor Commands
    localparam CMD_STOP        = 3'd0;
    localparam CMD_FWD         = 3'd1;
    localparam CMD_LEFT        = 3'd2;
    localparam CMD_RIGHT       = 3'd3;
    localparam CMD_UTURN       = 3'd4;
    localparam CMD_CRAWL_FWD   = 3'd5;
    localparam CMD_CRAWL_REV   = 3'd6;

    // ==========================================
    // INTERNAL SIGNALS
    // ==========================================
    
    // FSM Control Signals
    reg [2:0] cmd;
    reg [3:0] state;
    
    wire [15:0] threshold_dis;
    wire signed [6:0] clamp_in;
    reg send_end = 1'b0;
    reg send_end_done = 1'b0;  // NEW: One-shot latch for send_end pulse
    
    // Delay counters
    reg [26:0] idle_counter;
    reg [26:0] mpi_wait_counter;
    reg [26:0] crawl_rev_counter;
    reg [26:0] switch_delay_counter;
    reg [26:0] final_delay_counter;
    
    // Wall follow transition management
    reg wall_follow_active;
    
    // Sensor Inputs
    wire [2:0] wall;
    wire [15:0] distance_l, distance_r, distance_f, distance_pid_in;
    wire deadend, mi_box;
    reg mpi_flag;
    wire mpi_done;
    
    // Odometry Signals
    wire signed [15:0] left_count, right_count;
    reg odom_clear;
    
    wire wall_follow;
    wire signed [15:0] kp_in, kd_in;
    
    // Motor Control Signals
    wire signed [6:0] corrected_val, pid_l, pid_r;
    reg [6:0] final_duty_l, final_duty_r;
    reg dir_l, dir_r;
    reg signed [8:0] duty_l_tmp, duty_r_tmp;
    
    // Centering correction
    wire signed [15:0] distance_diff;
    wire signed [6:0] deadend_correction;
    
    // Internal Turn Counters
    reg [6:0] cnt_u;
    reg [6:0] cnt_l;
    reg [6:0] cnt_r;

    // Bluetooth Receiver Signals
    wire bt_start_signal;
    wire [3:0] bt_mpi_count_in;
    reg [3:0] mpi_target_count;
    reg [3:0] current_mpi_index;
    reg [3:0] deadend_count;
    reg [3:0] boxes_measured;

    // NEW: Exit Detection Logic
    reg [6:0] exit_counter;
    wire exit_detected;

    // ==========================================
    // EXIT DETECTION LOGIC (from second code)
    // ==========================================
    assign exit_detected = (distance_f > 16'd1000) && (distance_r > 16'd1000);

    // ==========================================
    // CENTERING LOGIC
    // ==========================================
    assign distance_diff = $signed(distance_l) - $signed(distance_r);
    assign deadend_correction = (distance_diff * K_CENTER) >>> 0;

    // ==========================================
    // ODOMETRY RESET LOGIC
    // ==========================================
    always @(*) begin
        if (state == TURN_L_PERFORM || state == TURN_R_PERFORM || state == UTURN_PERFORM) 
            odom_clear = 0;
        else 
            odom_clear = 1;
    end

    // ==========================================
    // WALL FOLLOW LOGIC - PURE LEFT WALL FOLLOWER
    // ==========================================
    assign wall_follow = 1'b1;  // Always left wall follow
    
    assign threshold_dis = wall_follow_active ? 16'd70 : 16'd70;
    assign pid_l = wall_follow_active ? corrected_val : 7'sd0;
    assign pid_r = wall_follow_active ? 7'sd0 : corrected_val;
    assign kp_in = wall_follow_active ? 16'sd30 : 16'sd30;
    assign kd_in = wall_follow_active ? 16'sd30 : 16'sd35;
    assign clamp_in = wall_follow_active ? 7'sd33 : 7'sd45;
    assign distance_pid_in = wall_follow_active ? distance_l : distance_r;

    // ==========================================
    // MOTOR MIXER
    // ==========================================
    always @(*) begin
        final_duty_l = 0;
        final_duty_r = 0;
        dir_l = 1;
        dir_r = 1;
        duty_l_tmp = 0;
        duty_r_tmp = 0;
        
        case (cmd)
            CMD_FWD: begin
                duty_l_tmp = $signed({1'b0, BASE_SPEED}) + pid_l - pid_r;
                duty_r_tmp = $signed({1'b0, BASE_SPEED}) - pid_l + pid_r;
                
                if (duty_l_tmp < 0)        final_duty_l = 0;
                else if (duty_l_tmp > 70)  final_duty_l = 70;
                else                       final_duty_l = duty_l_tmp[6:0];
                
                if (duty_r_tmp < 0)        final_duty_r = 0;
                else if (duty_r_tmp > 70)  final_duty_r = 70;
                else                       final_duty_r = duty_r_tmp[6:0];
            end
            
            CMD_CRAWL_FWD: begin
                duty_l_tmp = $signed({1'b0, CRAWL_SPEED}) - deadend_correction;
                duty_r_tmp = $signed({1'b0, CRAWL_SPEED}) + deadend_correction;
                
                if (duty_l_tmp < 0)        final_duty_l = 0;
                else if (duty_l_tmp > 40)  final_duty_l = 40;
                else                       final_duty_l = duty_l_tmp[6:0];
                
                if (duty_r_tmp < 0)        final_duty_r = 0;
                else if (duty_r_tmp > 40)  final_duty_r = 40;
                else                       final_duty_r = duty_r_tmp[6:0];
            end
            
            CMD_CRAWL_REV: begin
                duty_l_tmp = $signed({1'b0, CRAWL_SPEED}) + deadend_correction;
                duty_r_tmp = $signed({1'b0, CRAWL_SPEED}) - deadend_correction;
                
                if (duty_l_tmp < 0)        final_duty_l = 0;
                else if (duty_l_tmp > 40)  final_duty_l = 40;
                else                       final_duty_l = duty_l_tmp[6:0];
                
                if (duty_r_tmp < 0)        final_duty_r = 0;
                else if (duty_r_tmp > 40)  final_duty_r = 40;
                else                       final_duty_r = duty_r_tmp[6:0];
                dir_l = 0;
                dir_r = 0;
            end
            
            CMD_LEFT: begin
                final_duty_l = TURN_SPEED_L; dir_l = 1;
                final_duty_r = TURN_SPEED_H; dir_r = 0;
            end
            
            CMD_RIGHT: begin
                final_duty_l = TURN_SPEED_H; dir_l = 0;
                final_duty_r = TURN_SPEED_L; dir_r = 1;
            end
            
            CMD_UTURN: begin
                final_duty_l = TURN_SPEED_U; dir_l = 0;
                final_duty_r = TURN_SPEED_U; dir_r = 1;
            end
            
            CMD_STOP: begin
                final_duty_l = 0;
                final_duty_r = 0;
            end
            
            default: begin
                final_duty_l = 0;
                final_duty_r = 0;
            end
        endcase
    end

    // ==========================================
    // MAIN FINITE STATE MACHINE (Navigation from second code)
    // ==========================================
    always @(posedge clk_50M or negedge reset_n) begin
        // Debug outputs
        wall_status <= wall;
        state_check <= state;
        pd_check <= corrected_val;
        speed_l <= final_duty_l;
        speed_r <= final_duty_r;
        l_count <= left_count;
        r_count <= right_count;
        
        count_turn_l <= cnt_l;
        count_turn_r <= cnt_r;
        count_turn_u <= cnt_u;

        if (!reset_n) begin
            cmd <= CMD_STOP;
            state <= IDLE;
            cnt_u <= 0;
            cnt_l <= 0;
            cnt_r <= 0;
            idle_counter <= 0;
            mpi_wait_counter <= 0;
            crawl_rev_counter <= 0;
            switch_delay_counter <= 0;
            final_delay_counter <= 0;
            wall_follow_active <= 1'b1;
            mpi_flag <= 1'b0;
            
            mpi_target_count <= 0;
            current_mpi_index <= 4'd1;
            deadend_count <= 4'd0;
            boxes_measured <= 4'd0;
            
            exit_counter <= 0;
            send_end <= 1'b0;
            send_end_done <= 1'b0;
        end
        else begin
            // Default: Pull send_end low every cycle (creates pulse behavior)
            send_end <= 1'b0;
            
            // Wall follow switch logic
            if (wall_follow != wall_follow_active) begin
                if (switch_delay_counter >= SWITCH_DELAY) begin
                    wall_follow_active <= wall_follow;
                    switch_delay_counter <= 0;
                end
                else begin
                    switch_delay_counter <= switch_delay_counter + 1;
                end
            end
            else begin
                switch_delay_counter <= 0;
            end
            
            case (state)

                 // =====================================================
                 // IDLE
                 // =====================================================
                 IDLE: begin
                    cmd <= CMD_STOP;
                    exit_counter <= 0;
                    send_end_done <= 1'b0;
                    if (bt_start_signal) begin
                        mpi_target_count <= bt_mpi_count_in;
                        current_mpi_index <= 4'd1;
                        boxes_measured <= 4'd0;
                        deadend_count <= 4'd0;
                        state <= FOLLOW;
                    end
                 end

                 // =====================================================
                 // FOLLOW - EXIT DETECTION LOGIC
                 // =====================================================
                 FOLLOW: begin
                      // NEW: Exit detection from second code
                      if (exit_detected) begin
                          if (exit_counter >= 7'd100) begin
                              // Send one-shot pulse
                              if (!send_end_done) begin
                                  send_end <= 1'b1;
                                  send_end_done <= 1'b1;
                              end
                              state <= STOP;
                          end
                          else begin
                              exit_counter <= exit_counter + 1;
                              cmd <= CMD_FWD;  // Keep moving forward
                          end
                      end
                      else begin
                          // Reset exit counter if exit not detected
                          exit_counter <= 0;
                          
                          // Check if all required boxes measured and deadend detected
                          if (boxes_measured >= bt_mpi_count_in && wall == 3'b111) begin
                              cmd <= CMD_STOP;
                              state <= UTURN_READY;
                          end
                          // ONLY LEFT WALL FOLLOWER LOGIC
                          else begin
                              case (wall)
                                  3'b011: cmd <= CMD_FWD;  // corridor
                                  3'b010: cmd <= CMD_FWD;  // left wall only
                                  3'b001: cmd <= CMD_FWD;  // right wall only (PID corrects)

                                  3'b110: begin            // front + left blocked → RIGHT turn
                                      cmd   <= CMD_STOP;
                                      state <= TURN_R_READY;
                                  end

                                  3'b111: begin            // dead end
                                      cmd   <= CMD_STOP;
                                      deadend_count <= deadend_count + 1;
                                      
                                      // Check deadend flag
                                      if (deadend == 1'b1) begin
                                          // True deadend with MI box → full measurement sequence
                                          state <= CRAWL_REV;
                                          crawl_rev_counter <= 0;
                                      end
                                      else begin
                                          // Not a deadend (just 3 walls) → skip to uturn
                                          state <= UTURN_READY;
                                      end
                                  end

                                  default: cmd <= CMD_FWD;
                              endcase
                          end
                      end
                 end
                 
                 TURN_L_READY: begin
                    cmd   <= CMD_LEFT;
                    state <= TURN_L_PERFORM;
                 end

                 TURN_L_PERFORM: begin
                    if ((left_count - right_count) >= $signed(TICKS_L_90)) begin
                        cmd   <= CMD_STOP;
                        cnt_l <= cnt_l + 1;
                        state <= FOLLOW;
                    end
                    else begin
                        cmd <= CMD_LEFT;
                    end
                 end

                 TURN_R_READY: begin
                    cmd   <= CMD_RIGHT;
                    state <= TURN_R_PERFORM;
                 end

                 TURN_R_PERFORM: begin
                    if ((right_count - left_count) >= $signed(TICKS_R_90)) begin
                        cmd   <= CMD_STOP;
                        cnt_r <= cnt_r + 1;
                        state <= FOLLOW;
                    end
                    else begin
                        cmd <= CMD_RIGHT;
                    end
                 end

                 CRAWL_REV: begin
                    cmd <= CMD_CRAWL_REV;
                    if (crawl_rev_counter >= CRAWL_REV_DELAY) begin
                        state <= CRAWL_FWD;
                        crawl_rev_counter <= 0;
                    end
                    else begin
                        crawl_rev_counter <= crawl_rev_counter + 1;
                    end
                 end

                 CRAWL_FWD: begin
                    cmd <= CMD_CRAWL_FWD;
                    if (mi_box == 1) begin
                        cmd <= CMD_STOP;
                        
                        // Check deadend flag for measurement
                        if (deadend == 1'b1) begin
                            state <= MEASURE_WAIT;
                            mpi_wait_counter <= 0;
                            mpi_flag <= 1'b0;
                        end
                        else begin
                            // Skip measurement, go directly to U-turn
                            state <= UTURN_READY;
                        end
                    end
                 end

                 MEASURE_WAIT: begin
                    cmd <= CMD_STOP;
                    if (mpi_wait_counter >= MPI_WAIT_DELAY) begin
                        mpi_flag <= 1'b1;
                        state <= MEASURE_ACTIVE;
                        mpi_wait_counter <= 0;
                    end
                    else begin
                        mpi_wait_counter <= mpi_wait_counter + 1;
                    end
                 end

                 MEASURE_ACTIVE: begin
                    cmd <= CMD_STOP;
                    if (mpi_done) begin
                        mpi_flag <= 1'b0;
                        boxes_measured <= boxes_measured + 1;
                        state <= UTURN_READY;
                    end
                 end

                 UTURN_READY: begin
                    cmd   <= CMD_UTURN;
                    state <= UTURN_PERFORM;
                 end

                 UTURN_PERFORM: begin
                    if ((right_count - left_count) >= $signed(TICKS_180)) begin
                        cmd   <= CMD_STOP;
                        cnt_u <= cnt_u + 1;
                        current_mpi_index <= current_mpi_index + 1;
                        state <= FOLLOW;
                    end
                    else begin
                        cmd <= CMD_UTURN;
                    end
                 end
                 
                 FINAL_FOLLOW: begin
                    // Not used in second code's navigation logic
                    state <= STOP;
                 end
                 
                 STOP: begin
                    cmd <= CMD_STOP;
                    state <= STOP;
                    mpi_flag <= 1'b0;
                 end
                    
                endcase
        end
    end
    
    // ==========================================
    // MODULE INSTANTIATIONS
    // ==========================================

    bt_receiver u_bt_rx (
        .clk_50(clk_50M),
        .reset(!reset_n),
        .rx(bt_rx_pin),
        .start_signal(bt_start_signal),
        .mpi_count(bt_mpi_count_in)
    );

    pd_control_dd u_pd_dd (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .input_val(distance_pid_in),
        .ref_val(threshold_dis),
        .kp(kp_in),
        .kd(kd_in),
        .clamp(clamp_in),
        .corrected_val(corrected_val)
    );

    drive u_drive (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .duty_l(final_duty_r),
        .duty_r(final_duty_l),
        .dir_l(dir_l),
        .dir_r(dir_r),
        .IN1(IN1), .IN2(IN2), .IN3(IN3), .IN4(IN4),
        .ENA(ENA), .ENB(ENB)
    );

    odometry u_odom (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .enc_l_a(enc_l_a),
        .enc_r_a(enc_r_a),
        .dir_l(dir_l),
        .dir_r(dir_r),
        .clear(odom_clear),
        .left_count(left_count),
        .right_count(right_count)
    );
    
    sensor_interface u_sensors (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .us_echo_f(us_echo_f),
        .us_echo_l(us_echo_l),
        .us_echo_r(us_echo_r),
        .ir_top(ir_top),
        .ir_down(ir_down),
        .thres_f(thres_f),
        .thres_l(thres_l),
        .thres_r(thres_r),
        .us_trig_f(us_trig_f),
        .us_trig_l(us_trig_l),
        .us_trig_r(us_trig_r),
        .wall(wall),
        .deadend(deadend),
        .mi_box(mi_box),
        .distance_l(distance_l),
        .distance_r(distance_r),
        .distance_f(distance_f)
    );
    
    mpi_top u_mpi_top (
        .clk(clk_50M),
        .reset_n(reset_n),
        .mpi_flag_pin(mpi_flag),
        .mpi_id(current_mpi_index),
        .dht_data_pin(dht_data_pin),
        .servo_pwm_pin(servo_pwm_pin),
        .adc_sdat(adc_sdat),
        .adc_cs_n(adc_cs_n),
        .adc_sclk(adc_sclk),
        .adc_saddr(adc_saddr),
        .bt_tx_pin(bt_tx_pin),
        .send_end(send_end),
        .mpi_done(mpi_done)
    );

endmodule