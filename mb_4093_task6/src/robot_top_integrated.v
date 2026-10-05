module robot_top_integrated(
    // Clock and Reset
    input clk_50M, reset_n, start_n,
    
    // Sensor Inputs
    input us_echo_f, us_echo_l, us_echo_r,
    input ir_top, ir_down, ir_middle,
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
    
    // Debug
    output reg [2:0] wall_status,
    output reg [4:0] state_check,
    
    output reg signed [6:0] pd_check, 
    output reg [6:0] speed_l, speed_r,
    
    output reg [3:0] uturn_count,
    
    output reg [15:0] debug_us,
    output [3:0] debug_x,
    output [3:0] debug_y,
    output [1:0] debug_heading
);

    // ==========================================
    // PARAMETERS
    // ==========================================
    localparam TICKS_PER_CELL_MIN = 11'd1100; 
    localparam TICKS_PER_CELL_MAX = 11'd1300;
    localparam TICKS_PER_CELL_AVG = 11'd1200;
    
    localparam TICKS_AFTER_TURN_MIN = 11'd700;
    localparam TICKS_AFTER_TURN_MAX = 11'd800;
    localparam TICKS_AFTER_TURN_AVG = 11'd750;
    
    // ticks after U-turn (half of normal cell)
    localparam TICKS_AFTER_UTURN_AVG = 11'd500;
    
    localparam DIR_NORTH = 2'b00;
    localparam DIR_EAST  = 2'b01;
    localparam DIR_SOUTH = 2'b10;
    localparam DIR_WEST  = 2'b11;
    
    localparam HIGH_SPEED = 7'd70;       
    localparam MED_SPEED = 7'd40;   
    localparam SLOW_SPEED = 7'd30;
    localparam CRAWL_SPEED = 7'd27;
    
    localparam WAIT_DELAY = 27'd10_000_000;  // 0.1 seconds
    localparam IDLE_DELAY = 27'd100_000_000;
    
    // turn timing parameters
    localparam TURN_MIN_TIME = 27'd25_000_000;  // 0.5 s
    localparam TURN_MAX_TIME = 27'd100_000_000;  // 2 s
    
    localparam MPI_WAIT_DELAY = 27'd15_000_000; // 0.3 seconds
    localparam CRAWL_REV_DELAY = 27'd50_000_000;
    localparam signed K_CENTER = 7'sd3;
    
    localparam BT_SEND_INTERVAL = 27'd200_000_000; 
    localparam COORD_INTERVAL   = 26'd50_000_000;  

    localparam thres_l = 16'd140; 
    localparam thres_r = 16'd140;
    localparam thres_f = 16'd140; 

    localparam TICKS_L_90   = 16'd680;
    localparam TICKS_R_90   = 16'd730;
    localparam TICKS_U_180  = 16'd1300;
    localparam TURN_SPEED_H = 7'd50;
    localparam TURN_SPEED_L = 7'd0;
    localparam UTURN_SPEED  = 7'd50;

    localparam S_IDLE           = 5'd0;
    localparam S_DFS_UPDATE     = 5'd1;
    localparam S_DFS_EVALUATE   = 5'd2;
    localparam S_DFS_POP_TURN   = 5'd3;
    localparam S_MOVE_NORMAL    = 5'd4;
    localparam S_MOVE_POST_TURN = 5'd5;
    localparam S_TURN_L         = 5'd6;
    localparam S_TURN_R         = 5'd7;
    localparam S_WAIT           = 5'd8;
    localparam S_STOP           = 5'd9;
    localparam S_TURN_U         = 5'd10;
    localparam S_CRAWL_REV      = 5'd11;
    localparam S_CRAWL_FWD      = 5'd12;
    localparam S_MEASURE_WAIT   = 5'd13;
    localparam S_MEASURE_ACTIVE = 5'd14;
    localparam S_MOVE_POST_UTURN = 5'd15;

    localparam CMD_STOP      = 3'd0;
    localparam CMD_FWD       = 3'd1;
    localparam CMD_LEFT      = 3'd2;
    localparam CMD_RIGHT     = 3'd3;
    localparam CMD_UTURN     = 3'd4;
    localparam CMD_CRAWL_FWD = 3'd5;
    localparam CMD_CRAWL_REV = 3'd6;

    // ==========================================
    // INTERNAL SIGNALS
    // ==========================================
    reg [3:0] cmd;
    reg [4:0] state; 
    reg [26:0] wait_counter;
    reg [26:0] idle_counter;
    
    wire signed [16:0] left_count_wire, right_count_wire;
    reg odom_clear;
    
    reg signed [16:0] turn_ref_diff;
    reg signed [16:0] saved_turn_ref;  // Save turn reference (captured at turn start)
    reg [1:0] heading;
    reg post_turn_flag;
    reg post_uturn_flag;                 // flag for after a U-turn
    
    wire [15:0] distance_l, distance_r, distance_f;
    wire [2:0] wall;
    wire deadend, mi_box, front_wall;

    reg [6:0] final_duty_l, final_duty_r;
    reg dir_l, dir_r;
    reg signed [8:0] duty_l_tmp, duty_r_tmp;
    
    wire signed [15:0] pd_input, pd_ref, pd_kp, pd_kd;
    wire signed [6:0]  corrected_val, pid_l, pid_r; 
    reg signed [6:0] pd_clamp;
    
    wire cell_crossed_normal, cell_crossed_post_turn, cell_crossed_post_uturn, cell_crossed;
    reg prev_btn;
    
    reg [3:0] robot_x;
    reg [3:0] robot_y;
    
    wire bt_tx_wire, bt_busy;
    reg bt_send_trigger;
    reg [26:0] bt_send_counter;
    
    reg [6:0] adaptive_speed;
    
    wire signed [16:0] avg_ticks;
    reg signed [16:0] cell_start_ticks;
    wire [16:0] cell_current_ticks;
    reg odom_clear_pulse;

    wire start_flag;
    wire [3:0] mpi_target;
    reg coord_send_trigger;
    reg [25:0] coord_timer;

    reg [80:0] visited_cells;          
    reg [80:0] wall_north;
    reg [80:0] wall_east;
    reg [6:0] stack_memory [0:63];     
    reg [5:0] stack_ptr;               
    reg [3:0] mpi_found_count;         
    reg front_wall_prev;

    reg [26:0] mpi_wait_counter;
    reg [26:0] crawl_rev_counter;
    reg mpi_flag;
    wire mpi_done;
    reg [3:0] boxes_measured;
    reg [3:0] mpi_target_count;
    reg [3:0] current_mpi_index;
    wire signed [15:0] distance_diff;
    wire signed [6:0] deadend_correction;
    reg send_end;
    reg send_end_done;
    
    reg bt_mux_sel;
    wire bt_tx_messenger;
    wire bt_tx_mpi;

    reg [6:0] parent_id;
    
    // State routing register for WAIT
    reg [4:0] wait_return_state;

    // flag to capture turn reference only once per turn
    reg turn_ref_captured;

    // turn timer
    reg [26:0] turn_timer;

    // ==========================================
    // LOGIC ASSIGNMENTS
    // ==========================================
    assign avg_ticks = (left_count_wire + right_count_wire) >>> 1;
    assign cell_current_ticks = avg_ticks - cell_start_ticks;
    
    assign cell_crossed_normal = (cell_current_ticks >= TICKS_PER_CELL_AVG);
    assign cell_crossed_post_turn = (cell_current_ticks >= TICKS_AFTER_TURN_AVG);
    assign cell_crossed_post_uturn = (cell_current_ticks >= TICKS_AFTER_UTURN_AVG);
    
    assign cell_crossed = (state == S_MOVE_POST_TURN) ? cell_crossed_post_turn : 
                          (state == S_MOVE_POST_UTURN) ? 1'b0 : cell_crossed_normal;
     
    assign debug_x = robot_x;
    assign debug_y = robot_y;
    assign debug_heading = heading;

    assign distance_diff = $signed(distance_l) - $signed(distance_r);
    assign deadend_correction = (distance_diff * K_CENTER) >>> 0;
    
    assign bt_tx_pin = bt_mux_sel ? bt_tx_mpi : bt_tx_messenger;

    wire abs_wall_n = (heading == DIR_NORTH && wall[2]) || (heading == DIR_EAST && wall[1]) || (heading == DIR_WEST && wall[0]);
    wire abs_wall_e = (heading == DIR_EAST && wall[2]) || (heading == DIR_SOUTH && wall[1]) || (heading == DIR_NORTH && wall[0]);
    wire abs_wall_s = (heading == DIR_SOUTH && wall[2]) || (heading == DIR_WEST && wall[1]) || (heading == DIR_EAST && wall[0]);
    wire abs_wall_w = (heading == DIR_WEST && wall[2]) || (heading == DIR_NORTH && wall[1]) || (heading == DIR_SOUTH && wall[0]);

    reg [3:0] front_x, front_y, left_x, left_y, right_x, right_y;
    always @(*) begin
        case(heading)
            2'b00: begin front_x=robot_x; front_y=robot_y+1; left_x=robot_x-1; left_y=robot_y; right_x=robot_x+1; right_y=robot_y; end
            2'b01: begin front_x=robot_x+1; front_y=robot_y; left_x=robot_x; left_y=robot_y+1; right_x=robot_x; right_y=robot_y-1; end
            2'b10: begin front_x=robot_x; front_y=robot_y-1; left_x=robot_x+1; left_y=robot_y; right_x=robot_x-1; right_y=robot_y; end
            2'b11: begin front_x=robot_x-1; front_y=robot_y; left_x=robot_x; left_y=robot_y-1; right_x=robot_x; right_y=robot_y+1; end
        endcase
    end
    
    wire valid_front = (front_x < 9 && front_y < 9);
    wire valid_left  = (left_x < 9  && left_y < 9);
    wire valid_right = (right_x < 9 && right_y < 9);
    
    wire [6:0] id_front = (front_y * 9) + front_x;
    wire [6:0] id_left  = (left_y * 9)  + left_x;
    wire [6:0] id_right = (right_y * 9) + right_x;
    wire [6:0] id_current = (robot_y * 9) + robot_x;

    wire trap_front = (front_x == 4 && front_y == 8 && boxes_measured < mpi_target_count);
    wire trap_left  = (left_x == 4 && left_y == 8 && boxes_measured < mpi_target_count);
    wire trap_right = (right_x == 4 && right_y == 8 && boxes_measured < mpi_target_count);

    wire [3:0] parent_x = parent_id % 9;
    wire [3:0] parent_y = parent_id / 9;
    wire [1:0] target_heading_from_parent;
    assign target_heading_from_parent = (parent_y > robot_y) ? DIR_NORTH :
                                         (parent_x > robot_x) ? DIR_EAST :
                                         (parent_y < robot_y) ? DIR_SOUTH : DIR_WEST;

    // ==========================================
    // PID PARAMETER SELECTION
    // ==========================================
    assign pd_ref = wall[1] ? 16'd70 : 16'd60;
    assign pd_input = wall[1] ? distance_l : (wall[0] ? distance_r : 16'd70);
    assign pd_kp = wall[1] ? 16'sd30 : 16'sd30;
    assign pd_kd = 16'sd10;
    assign pid_l = wall[1] ? corrected_val : 7'sd0;
    assign pid_r = (!wall[1] && wall[0]) ? corrected_val : 7'sd0;
          
    // ==========================================
    // ADAPTIVE SPEED AND PID CLAMP – MODIFIED
    // ==========================================
    always @(*) begin
        if ( (state == S_MOVE_NORMAL) && (distance_f > 16'd300) ) begin
            adaptive_speed = HIGH_SPEED;   // 70
            pd_clamp = 7'sd20;
        end else begin
            adaptive_speed = MED_SPEED;    // 40
            pd_clamp = 7'sd15;
        end
    end

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
                duty_l_tmp = $signed({1'b0, adaptive_speed}) + pid_l - pid_r;
                duty_r_tmp = $signed({1'b0, adaptive_speed}) - pid_l + pid_r;
                
                if (duty_l_tmp < 20)       final_duty_l = 20;
                else if (duty_l_tmp > 90)  final_duty_l = 90;
                else                       final_duty_l = duty_l_tmp[6:0];
                
                if (duty_r_tmp < 20)       final_duty_r = 20;
                else if (duty_r_tmp > 90)  final_duty_r = 90;
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
                final_duty_l = UTURN_SPEED+5; dir_l = 1;
                final_duty_r = UTURN_SPEED; dir_r = 0;
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
    // MAIN FSM
    // ==========================================
    integer i;

    always @(posedge clk_50M or negedge reset_n) begin
        speed_l <= final_duty_l;
        speed_r <= final_duty_r;
        state_check <= state;
        pd_check <= corrected_val;
        front_wall_prev <= front_wall;
        
        debug_us = distance_f;

        if (!reset_n) begin
            state <= S_IDLE;
            cmd <= CMD_STOP;
            heading <= DIR_NORTH;
            post_turn_flag <= 1'b0;
            post_uturn_flag <= 1'b0;
            
            robot_x <= 4'd4;
            robot_y <= 4'd0;
            uturn_count <= 4'd0;
            front_wall_prev <= 1'b0;
            
            visited_cells <= 81'b0;
            wall_north <= 81'b0;
            wall_east <= 81'b0;
            stack_ptr <= 6'd0;
            mpi_found_count <= 4'd0;
            for (i = 0; i < 64; i = i + 1) stack_memory[i] <= 7'd0;
            
            cell_start_ticks <= 16'd0;
            turn_ref_diff <= 0;
            saved_turn_ref <= 0;
            wait_counter <= 0;
            idle_counter <= 0;
            prev_btn <= 0;
            odom_clear <= 1'b1;
            odom_clear_pulse <= 1'b0;
            
            bt_send_trigger <= 1'b0;
            bt_send_counter <= 27'd0;
            coord_send_trigger <= 1'b0;
            coord_timer <= 26'd0;
            
            mpi_wait_counter <= 0;
            crawl_rev_counter <= 0;
            mpi_flag <= 1'b0;
            boxes_measured <= 4'd0;
            current_mpi_index <= 4'd1;
            mpi_target_count <= 4'd0;
            send_end <= 1'b0;
            send_end_done <= 1'b0;
            bt_mux_sel <= 1'b0;

            parent_id <= 7'd0;
            wait_return_state <= S_IDLE;
            turn_ref_captured <= 1'b0;
            turn_timer <= 27'd0;
        end
        else begin
            prev_btn <= ir_top;
            send_end <= 1'b0;
            
            odom_clear_pulse <= 1'b0;
            if (cell_crossed) begin
                cell_start_ticks <= avg_ticks;
                odom_clear_pulse <= 1'b1;
            end
            odom_clear <= odom_clear_pulse;
            
            if (bt_send_counter >= BT_SEND_INTERVAL) begin bt_send_trigger <= 1'b1; bt_send_counter <= 27'd0; end
            else bt_send_counter <= bt_send_counter + 27'd1;
            if (!bt_busy && bt_send_trigger) bt_send_trigger <= 1'b0;
            
            if (coord_timer >= COORD_INTERVAL) begin coord_send_trigger <= 1'b1; coord_timer <= 26'd0; end
            else coord_timer <= coord_timer + 26'd1;
            if (!bt_busy && coord_send_trigger) coord_send_trigger <= 1'b0;
            
            case (state)
                
                S_IDLE: begin
                    cmd <= CMD_STOP;
                    post_turn_flag <= 1'b0;
                    post_uturn_flag <= 1'b0;
                    odom_clear <= 1'b1;
                    bt_mux_sel <= 1'b0;
                    
                    if (idle_counter >= IDLE_DELAY && start_flag) begin
                        mpi_target_count <= mpi_target;
                        boxes_measured <= 4'd0;
                        current_mpi_index <= 4'd1;
                        send_end_done <= 1'b0;
                        
                        cell_start_ticks <= avg_ticks;
                        idle_counter <= 0;
                        odom_clear <= 1'b0;
                        state <= S_DFS_UPDATE;                              
                    end
                    else idle_counter <= idle_counter + 1;
                end

                S_DFS_UPDATE: begin
                    cmd <= CMD_STOP;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    visited_cells[id_current] <= 1'b1;
                    
                    if (abs_wall_n) wall_north[id_current] <= 1'b1;
                    if (abs_wall_e) wall_east[id_current] <= 1'b1;
                    if (abs_wall_s && robot_y > 0) wall_north[id_current - 9] <= 1'b1;
                    if (abs_wall_w && robot_x > 0) wall_east[id_current - 1] <= 1'b1;
                    
                    state <= S_DFS_EVALUATE;
                end

                S_DFS_EVALUATE: begin
                    bt_mux_sel <= 1'b0;
                    
                    if (post_uturn_flag) begin
                        cell_start_ticks <= avg_ticks;
                        post_uturn_flag <= 1'b0;
                        state <= S_MOVE_POST_UTURN;
                    end
                    else if (post_turn_flag) begin
                        cell_start_ticks <= avg_ticks;
                        post_turn_flag <= 1'b0;
                        state <= S_MOVE_POST_TURN;
                    end
                    else begin
                        if (!wall[2] && valid_front && !visited_cells[id_front] && !trap_front) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr <= stack_ptr + 1;
                            cell_start_ticks <= avg_ticks; 
                            state <= S_MOVE_NORMAL;
                        end
                        else if (!wall[1] && valid_left && !visited_cells[id_left] && !trap_left) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr <= stack_ptr + 1;
                            wait_return_state <= S_TURN_L;
                            state <= S_WAIT;
                            wait_counter <= 0;
                        end
                        else if (!wall[0] && valid_right && !visited_cells[id_right] && !trap_right) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr <= stack_ptr + 1;
                            wait_return_state <= S_TURN_R;
                            state <= S_WAIT;
                            wait_counter <= 0;
                        end
                        else begin
                            if (wall[0] && wall[1] && wall[2]) begin
                                mpi_found_count <= mpi_found_count + 1;
                                
                                if (deadend == 1'b1 && boxes_measured < mpi_target_count) begin
                                    parent_id <= stack_memory[stack_ptr - 1];
                                    state <= S_CRAWL_REV;
                                    crawl_rev_counter <= 0;
                                end
                                else begin
                                    if (stack_ptr > 0) begin
                                        parent_id <= stack_memory[stack_ptr - 1];
                                        wait_return_state <= S_DFS_POP_TURN;
                                        state <= S_WAIT;
                                        wait_counter <= 0;
                                    end else begin
                                        state <= S_STOP;
                                    end
                                end
                            end
                            else begin
                                if (stack_ptr > 0) begin
                                    parent_id <= stack_memory[stack_ptr - 1];
                                    wait_return_state <= S_DFS_POP_TURN;
                                    state <= S_WAIT;
                                    wait_counter <= 0;
                                end else begin
                                    state <= S_STOP;
                                end
                            end
                        end
                    end
                end

                S_DFS_POP_TURN: begin
                    bt_mux_sel <= 1'b0;
                    stack_ptr <= stack_ptr - 1;
                    
                    if (target_heading_from_parent == heading) begin
                        cell_start_ticks <= avg_ticks;
                        state <= S_MOVE_NORMAL;
                    end 
                    else if (target_heading_from_parent == (heading + 2'd1)) begin
                        state <= S_TURN_R;
                    end 
                    else if (target_heading_from_parent == (heading + 2'd3)) begin
                        state <= S_TURN_L;
                    end 
                    else begin
                        state <= S_TURN_U;
                    end
                end

                S_MOVE_NORMAL: begin
                    cmd <= CMD_FWD;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
                        cmd <= CMD_STOP;
                        wait_return_state <= S_DFS_UPDATE;
                        state <= S_WAIT;
                        wait_counter <= 0;
                    end
                    else if (cell_crossed_normal) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
                        state <= S_DFS_UPDATE;
                    end
                end

                S_MOVE_POST_TURN: begin
                    cmd <= CMD_FWD;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
                        cmd <= CMD_STOP;
                        wait_return_state <= S_DFS_UPDATE;
                        state <= S_WAIT;
                        wait_counter <= 0;
                    end
                    else if (cell_crossed_post_turn) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
                        state <= S_DFS_UPDATE;
                    end
                end

                S_MOVE_POST_UTURN: begin
                    cmd <= CMD_FWD;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
                        cmd <= CMD_STOP;
                        wait_return_state <= S_DFS_UPDATE;
                        state <= S_WAIT;
                        wait_counter <= 0;
                    end
                    else if (cell_crossed_post_uturn) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
                        state <= S_DFS_UPDATE;
                    end
                end

                // ========== TURN STATES with reference capture and timer ==========
                S_TURN_L: begin
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (!turn_ref_captured) begin
                        saved_turn_ref <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd <= CMD_LEFT;
                        turn_timer <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 1;
                        cmd <= CMD_LEFT;
                        
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_L_90)) begin
                                cmd <= CMD_STOP;
                                post_turn_flag <= 1'b1;
                                heading <= heading + 2'd3;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                state <= S_WAIT;
                                wait_counter <= 0;
                            end
                            else if (turn_timer >= TURN_MAX_TIME) begin
                                cmd <= CMD_STOP;
                                post_turn_flag <= 1'b1;
                                heading <= heading + 2'd3;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                state <= S_WAIT;
                                wait_counter <= 0;
                            end
                        end
                    end
                end

                S_TURN_R: begin
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (!turn_ref_captured) begin
                        saved_turn_ref <= right_count_wire - left_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd <= CMD_RIGHT;
                        turn_timer <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 1;
                        cmd <= CMD_RIGHT;
                        
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(right_count_wire - left_count_wire) - saved_turn_ref) >= $signed(TICKS_R_90)) begin
                                cmd <= CMD_STOP;
                                post_turn_flag <= 1'b1;
                                heading <= heading + 2'd1;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                state <= S_WAIT;
                                wait_counter <= 0;
                            end
                            else if (turn_timer >= TURN_MAX_TIME) begin
                                cmd <= CMD_STOP;
                                post_turn_flag <= 1'b1;
                                heading <= heading + 2'd1;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                state <= S_WAIT;
                                wait_counter <= 0;
                            end
                        end
                    end
                end

                S_TURN_U: begin
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (!turn_ref_captured) begin
                        saved_turn_ref <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd <= CMD_UTURN;
                        turn_timer <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 1;
                        cmd <= CMD_UTURN;
                        
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_U_180)) begin
                                cmd <= CMD_STOP;
                                post_uturn_flag <= 1'b1;
                                if (uturn_count < 4'd15) uturn_count <= uturn_count + 4'd1;
                                heading <= heading + 2'd2;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                state <= S_WAIT;
                                wait_counter <= 0;
                            end
                            else if (turn_timer >= TURN_MAX_TIME) begin
                                cmd <= CMD_STOP;
                                post_uturn_flag <= 1'b1;
                                if (uturn_count < 4'd15) uturn_count <= uturn_count + 4'd1;
                                heading <= heading + 2'd2;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                state <= S_WAIT;
                                wait_counter <= 0;
                            end
                        end
                    end
                end

                S_CRAWL_REV: begin
                    cmd <= CMD_CRAWL_REV;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (crawl_rev_counter >= CRAWL_REV_DELAY) begin
                        cmd <= CMD_STOP;
                        state <= S_CRAWL_FWD;
                        crawl_rev_counter <= 0;
                    end
                    else begin
                        crawl_rev_counter <= crawl_rev_counter + 1;
                    end
                end

                S_CRAWL_FWD: begin
                    cmd <= CMD_CRAWL_FWD;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (mi_box) begin
                        cmd <= CMD_STOP;
                        state <= S_MEASURE_WAIT;
                        mpi_wait_counter <= 0;
                    end
                end

                S_MEASURE_WAIT: begin
                    cmd <= CMD_STOP;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (mpi_wait_counter >= MPI_WAIT_DELAY) begin
                        mpi_flag <= 1'b1;
                        bt_mux_sel <= 1'b1;
                        state <= S_MEASURE_ACTIVE;
                        mpi_wait_counter <= 0;
                    end
                    else begin
                        mpi_wait_counter <= mpi_wait_counter + 1;
                    end
                end

                S_MEASURE_ACTIVE: begin
                    cmd <= CMD_STOP;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b1;
                    
                    if (mpi_done) begin
                        mpi_flag <= 1'b0;
                        boxes_measured <= boxes_measured + 1;
                        current_mpi_index <= current_mpi_index + 1;
                        bt_mux_sel <= 1'b0;
                        
                        if (stack_ptr > 0) begin
                            wait_return_state <= S_DFS_POP_TURN;
                            state <= S_WAIT;
                            wait_counter <= 0;
                        end
                        else begin
                            state <= S_STOP;
                        end
                    end
                end

                S_WAIT: begin
                    cmd <= CMD_STOP;
                    odom_clear <= 1'b0;
                    bt_mux_sel <= 1'b0;
                    
                    if (wait_counter >= WAIT_DELAY) begin
                        wait_counter <= 0;
                        state <= wait_return_state;
                    end
                    else wait_counter <= wait_counter + 1;
                end

                S_STOP: begin
                    cmd <= CMD_STOP;
                    odom_clear <= 1'b1;
                    bt_mux_sel <= 1'b0;
                    
                    if (boxes_measured >= mpi_target_count && !send_end_done) begin
                        send_end <= 1'b1;
                        send_end_done <= 1'b1;
                    end
                    
                    if (ir_top && !prev_btn) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ==========================================
    // MODULE INSTANTIATIONS (unchanged)
    // ==========================================

    bt_receiver u_bt_rx (
        .clk_50(clk_50M),
        .reset(~reset_n), 
        .rx(bt_rx_pin),
        .start_signal(start_flag),
        .mpi_count(mpi_target)
    );

    bt_messenger u_bt_tx (
        .clk(clk_50M),
        .reset(~reset_n),
        .send_mpi(1'b0), 
        .send_mm(1'b0), 
        .send_th(1'b0), 
        .send_end(1'b0),
        .send_coord(coord_send_trigger),
        
        .visited_cells(visited_cells), 
        .wall_north(wall_north),
        .wall_east(wall_east),
        
        .mpi_id(4'd0), 
        .moisture_val(12'd0), 
        .temp_int(8'd0), 
        .temp_dec(8'd0), 
        .hum_int(8'd0), 
        .hum_dec(8'd0),
        .tx(bt_tx_messenger),
        .busy(bt_busy)
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
        .bt_tx_pin(bt_tx_mpi),
        .send_end(send_end),
        .mpi_done(mpi_done)
    );

    pd_control_dd u_pid_crawl (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .input_val(pd_input),
        .ref_val(pd_ref),
        .kp(pd_kp),
        .kd(pd_kd),
        .clamp(pd_clamp),
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
        .left_count(left_count_wire),
        .right_count(right_count_wire)
    );
    
    sensor_interface u_sensors (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .us_echo_f(us_echo_f),
        .us_echo_l(us_echo_l),
        .us_echo_r(us_echo_r),
        .ir_top(ir_top),
        .ir_down(ir_down),
        .ir_middle(ir_middle),
        .thres_f(thres_f), 
        .thres_l(thres_l), 
        .thres_r(thres_r),
        .us_trig_f(us_trig_f),
        .us_trig_l(us_trig_l),
        .us_trig_r(us_trig_r),
        .wall(wall),
        .deadend(deadend),
        .mi_box(mi_box),
        .front_wall(front_wall),
        .distance_l(distance_l),
        .distance_r(distance_r),
        .distance_f(distance_f)
    );

    always @(posedge clk_50M) begin
        wall_status <= wall; 
    end

endmodule