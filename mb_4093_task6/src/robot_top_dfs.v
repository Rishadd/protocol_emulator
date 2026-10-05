module robot_top_dfs(
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
    
     //Debug
    output reg [2:0] wall_status,
    output reg [4:0] state_check,
    
    output reg signed [6:0] pd_check, 
    output reg [6:0] speed_l, speed_r,
    
    // Turn Counter
    output reg [3:0] uturn_count,
    
    output [3:0] debug_x,
    output [3:0] debug_y,
    output [1:0] debug_heading
);

    // ==========================================
    // 1. PARAMETERS
    // ==========================================
    localparam TICKS_PER_CELL_MIN = 11'd1100; 
    localparam TICKS_PER_CELL_MAX = 11'd1300;
    localparam TICKS_PER_CELL_AVG = 11'd1200;
    
    localparam TICKS_AFTER_TURN_MIN = 11'd700;
    localparam TICKS_AFTER_TURN_MAX = 11'd800;
    localparam TICKS_AFTER_TURN_AVG = 11'd750;
    
    localparam DIR_NORTH = 2'b00;
    localparam DIR_EAST  = 2'b01;
    localparam DIR_SOUTH = 2'b10;
    localparam DIR_WEST  = 2'b11;
    
    localparam BASE_SPEED = 7'd60;       
    localparam MED_SPEED = 7'd40;   
    localparam SLOW_SPEED = 7'd20;  
    localparam APPROACH_THRESHOLD_MID = 11'd400;  
    localparam APPROACH_THRESHOLD_FINAL = 11'd200; 
    localparam WAIT_DELAY = 27'd25_000_000;  
    localparam IDLE_DELAY = 27'd100_000_000;  
    
    // ===== BLUETOOTH PARAMETERS =====
    localparam BT_SEND_INTERVAL = 27'd250_000_000; 
    localparam COORD_INTERVAL   = 26'd50_000_000;  

    localparam thres_l = 16'd140; 
    localparam thres_r = 16'd140;
    localparam thres_f = 16'd130; 

    localparam TICKS_L_90   = 16'd620;
    localparam TICKS_R_90   = 16'd720;
    localparam TICKS_U_180  = 16'd1300;
    localparam TURN_SPEED_H = 7'd50;
    localparam TURN_SPEED_L = 7'd0;
    localparam UTURN_SPEED  = 7'd50;

    // --- EXPANDED FSM STATES ---
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

    localparam CMD_STOP  = 3'd0;
    localparam CMD_FWD   = 3'd1;
    localparam CMD_LEFT  = 3'd2;
    localparam CMD_RIGHT = 3'd3;
    localparam CMD_UTURN = 3'd4;

    // ==========================================
    // 2. INTERNAL SIGNALS & DFS MEMORY
    // ==========================================
    reg [3:0] cmd;
    reg [4:0] state; 
    reg [26:0] wait_counter;
    reg [26:0] idle_counter;
    
    wire signed [15:0] left_count_wire, right_count_wire;
    reg odom_clear;
    
    reg signed [15:0] turn_ref_diff;
    reg [1:0] heading;
    reg post_turn_flag;
    
    wire [15:0] distance_l, distance_r, distance_f;
    wire [2:0] wall;
    wire deadend, mi_box;

    reg [6:0] final_duty_l, final_duty_r;
    reg dir_l, dir_r;
    reg signed [8:0] duty_l_tmp, duty_r_tmp;
    
    wire signed [15:0] pd_input, pd_ref, pd_kp, pd_kd;
    wire signed [6:0]  pd_clamp, corrected_val, pid_l, pid_r; 
    
    wire cell_crossed_normal, cell_crossed_post_turn, cell_crossed;
    reg prev_btn;
    
    reg [3:0] robot_x;
    reg [3:0] robot_y;
    
    wire bt_tx_wire, bt_busy;
    reg bt_send_trigger;
    reg [26:0] bt_send_counter;
    
    reg [6:0] adaptive_speed;
    
    // Odometry Variables
    wire signed [15:0] avg_ticks;
    reg signed [15:0] cell_start_ticks;
    wire [15:0] cell_current_ticks;
    reg odom_clear_pulse;

    // --- BLUETOOTH SIGNALS ---
    wire start_flag;
    wire [3:0] mpi_target;
    reg coord_send_trigger;
    reg [25:0] coord_timer;

    // --- DFS MEMORY STRUCTURES ---
    reg [80:0] visited_cells;          
    reg [80:0] wall_north;
    reg [80:0] wall_east;
    reg [6:0] stack_memory [0:63];     
    reg [5:0] stack_ptr;               
    reg [3:0] mpi_found_count;         
	 
	 reg mi_box_prev;   // Previous value of mi_box for rising edge detection

    // ==========================================
    // 3. LOGIC ASSIGNMENTS & COMBINATIONAL DFS
    // ==========================================
    assign avg_ticks = (left_count_wire + right_count_wire) >>> 1;
    assign cell_current_ticks = avg_ticks - cell_start_ticks;
    
    assign cell_crossed_normal = (cell_current_ticks >= TICKS_PER_CELL_MIN);
    assign cell_crossed_post_turn = (cell_current_ticks >= TICKS_AFTER_TURN_MIN);
    assign cell_crossed = (state == S_MOVE_POST_TURN) ? cell_crossed_post_turn : cell_crossed_normal;
     
    assign debug_x = robot_x;
    assign debug_y = robot_y;
    assign debug_heading = heading;

    // --- Absolute Wall Translation ---
    wire abs_wall_n = (heading == DIR_NORTH && wall[2]) || (heading == DIR_EAST && wall[1]) || (heading == DIR_WEST && wall[0]);
    wire abs_wall_e = (heading == DIR_EAST && wall[2]) || (heading == DIR_SOUTH && wall[1]) || (heading == DIR_NORTH && wall[0]);
    wire abs_wall_s = (heading == DIR_SOUTH && wall[2]) || (heading == DIR_WEST && wall[1]) || (heading == DIR_EAST && wall[0]);
    wire abs_wall_w = (heading == DIR_WEST && wall[2]) || (heading == DIR_NORTH && wall[1]) || (heading == DIR_SOUTH && wall[0]);

    // --- Dynamic Look-Ahead Cells ---
    reg [3:0] front_x, front_y, left_x, left_y, right_x, right_y;
    always @(*) begin
        case(heading)
            2'b00: begin front_x=robot_x; front_y=robot_y+1; left_x=robot_x-1; left_y=robot_y; right_x=robot_x+1; right_y=robot_y; end
            2'b01: begin front_x=robot_x+1; front_y=robot_y; left_x=robot_x; left_y=robot_y+1; right_x=robot_x; right_y=robot_y-1; end
            2'b10: begin front_x=robot_x; front_y=robot_y-1; left_x=robot_x+1; left_y=robot_y; right_x=robot_x-1; right_y=robot_y; end
            2'b11: begin front_x=robot_x-1; front_y=robot_y; left_x=robot_x; left_y=robot_y-1; right_x=robot_x; right_y=robot_y+1; end
        endcase
    end
    
    // Boundary and Trap Logic
    wire valid_front = (front_x < 9 && front_y < 9);
    wire valid_left  = (left_x < 9  && left_y < 9);
    wire valid_right = (right_x < 9 && right_y < 9);
    
    wire [6:0] id_front = (front_y * 9) + front_x;
    wire [6:0] id_left  = (left_y * 9)  + left_x;
    wire [6:0] id_right = (right_y * 9) + right_x;
    wire [6:0] id_current = (robot_y * 9) + robot_x;

    wire trap_front = (front_x == 4 && front_y == 8 && mpi_found_count < 9);
    wire trap_left  = (left_x == 4 && left_y == 8 && mpi_found_count < 9);
    wire trap_right = (right_x == 4 && right_y == 8 && mpi_found_count < 9);

    // Turn Target Calculation for Backtracking
    reg [1:0] target_heading;
    wire [6:0] popped_id = stack_memory[stack_ptr - 1]; 
    wire [3:0] popped_x = popped_id % 9;
    wire [3:0] popped_y = popped_id / 9;
    
    always @(*) begin
        if (popped_y > robot_y) target_heading = 2'b00; 
        else if (popped_x > robot_x) target_heading = 2'b01; 
        else if (popped_y < robot_y) target_heading = 2'b10; 
        else target_heading = 2'b11; 
    end

    // ===========================
    // 4. PID PARAMETER SELECTION
    // ===========================
	 
	 
	 
    assign pd_ref = wall[1] ? 16'd70 : 16'd70;
    assign pid_l = wall[1] ? corrected_val : 7'sd0;
    assign pid_r = wall[1] ? 7'sd0 : corrected_val;
    assign pd_kp = wall[1] ? 16'sd18 : 16'sd12;
    assign pd_kd = wall[1] ? 16'sd30 : 16'sd30;
    assign pd_clamp = wall[1] ? 7'sd15 : 7'sd15;
    assign pd_input = wall[1] ? distance_l : distance_r;
          
    // ======================================
    // 5. ADAPTIVE SPEED CALCULATION 2 STAGE
    // ======================================
    always @(*) begin
        if (state == S_MOVE_POST_TURN) begin
            if (cell_current_ticks >= (TICKS_AFTER_TURN_AVG - APPROACH_THRESHOLD_FINAL))
                adaptive_speed = SLOW_SPEED;
            else if (cell_current_ticks >= (TICKS_AFTER_TURN_AVG - APPROACH_THRESHOLD_MID))
                adaptive_speed = MED_SPEED;
            else
                adaptive_speed = BASE_SPEED;
        end
        else if (state == S_MOVE_NORMAL) begin
            if (cell_current_ticks >= (TICKS_PER_CELL_AVG - APPROACH_THRESHOLD_FINAL))
                adaptive_speed = SLOW_SPEED;
            else if (cell_current_ticks >= (TICKS_PER_CELL_AVG - APPROACH_THRESHOLD_MID))
                adaptive_speed = MED_SPEED;
            else
                adaptive_speed = BASE_SPEED;
        end
        else begin
            adaptive_speed = BASE_SPEED;
        end
    end

    // ===============
    // 6. MOTOR MIXER
    // ===============
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

    // ============
    // 7. MAIN FSM
    // ============
    integer i;

    always @(posedge clk_50M or negedge reset_n) begin
        speed_l <= final_duty_l;
        speed_r <= final_duty_r;
        state_check <= state;
        pd_check <= corrected_val;

        if (!reset_n) begin
            state <= S_IDLE;
            cmd <= CMD_STOP;
            heading <= DIR_NORTH;
            post_turn_flag <= 1'b0;
            
            robot_x <= 4'd4;
            robot_y <= 4'd0;
            uturn_count <= 4'd0;
				
				mi_box_prev <= 1'b0;   // Initialize mi_box previous value
            
            // DFS Initializations
            visited_cells <= 81'b0;
            wall_north <= 81'b0;
            wall_east <= 81'b0;
            stack_ptr <= 6'd0;
            mpi_found_count <= 4'd0;
            for (i = 0; i < 64; i = i + 1) stack_memory[i] <= 7'd0;
            
            cell_start_ticks <= 16'd0;
            turn_ref_diff <= 0;
            wait_counter <= 0;
            idle_counter <= 0;
            prev_btn <= 0;
            odom_clear <= 1'b1;
            odom_clear_pulse <= 1'b0;
            
            bt_send_trigger <= 1'b0;
            bt_send_counter <= 27'd0;
            coord_send_trigger <= 1'b0;
            coord_timer <= 26'd0;
        end
        else begin
            prev_btn <= ir_top;
            
            // Odometry Pulse Logic
            odom_clear_pulse <= 1'b0;
            if (cell_crossed) begin
                cell_start_ticks <= avg_ticks;
                odom_clear_pulse <= 1'b1;
            end
            odom_clear <= odom_clear_pulse;
            
            // Bluetooth Timers
            if (bt_send_counter >= BT_SEND_INTERVAL) begin bt_send_trigger <= 1'b1; bt_send_counter <= 27'd0; end
            else bt_send_counter <= bt_send_counter + 27'd1;
            if (!bt_busy && bt_send_trigger) bt_send_trigger <= 1'b0;
            
            // 1-Second Grid Output Timer
            if (coord_timer >= COORD_INTERVAL) begin coord_send_trigger <= 1'b1; coord_timer <= 26'd0; end
            else coord_timer <= coord_timer + 26'd1;
            if (!bt_busy && coord_send_trigger) coord_send_trigger <= 1'b0;
            
            case (state)
                
                S_IDLE: begin
                    cmd <= CMD_STOP;
                    post_turn_flag <= 1'b0;
                    odom_clear <= 1'b1;
                    
                    // Triggered by start_flag from BT
                    if (idle_counter >= IDLE_DELAY && start_flag) begin
                        cell_start_ticks <= avg_ticks;
                        idle_counter <= 0;
                        odom_clear <= 1'b0;
                        state <= S_DFS_UPDATE;                              
                    end
                    else idle_counter <= idle_counter + 1;
                end

                // --- DFS ENGINE ---
                S_DFS_UPDATE: begin
                    cmd <= CMD_STOP;
                    odom_clear <= 1'b0;
                    
                    // Mark current cell as visited
                    visited_cells[id_current] <= 1'b1;
                    
                    // Permanently memorize walls in absolute directions
                    if (abs_wall_n) wall_north[id_current] <= 1'b1;
                    if (abs_wall_e) wall_east[id_current] <= 1'b1;
                    if (abs_wall_s && robot_y > 0) wall_north[id_current - 9] <= 1'b1;
                    if (abs_wall_w && robot_x > 0) wall_east[id_current - 1] <= 1'b1;
                    
                    state <= S_DFS_EVALUATE;
                end

                S_DFS_EVALUATE: begin
                    if (post_turn_flag) begin
                        cell_start_ticks <= avg_ticks;
                        post_turn_flag <= 1'b0;
                        state <= S_MOVE_POST_TURN;
                    end
                    else begin
                        // 1. FRONT
                        if (!wall[2] && valid_front && !visited_cells[id_front] && !trap_front) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr <= stack_ptr + 1;
                            cell_start_ticks <= avg_ticks; 
                            state <= S_MOVE_NORMAL;
                        end
                        // 2. LEFT
                        else if (!wall[1] && valid_left && !visited_cells[id_left] && !trap_left) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr <= stack_ptr + 1;
                            turn_ref_diff <= left_count_wire - right_count_wire;
                            state <= S_TURN_L;
                        end
                        // 3. RIGHT
                        else if (!wall[0] && valid_right && !visited_cells[id_right] && !trap_right) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr <= stack_ptr + 1;
                            turn_ref_diff <= right_count_wire - left_count_wire;
                            state <= S_TURN_R;
                        end
                        // DEAD END OR FULLY VISITED
                        else begin
                            if (stack_ptr > 0) begin
                                if (wall[0] && wall[1] && wall[2]) mpi_found_count <= mpi_found_count + 1;
                                state <= S_DFS_POP_TURN;
                            end else state <= S_STOP; // End of run
                        end
                    end
                end

                S_DFS_POP_TURN: begin
                    stack_ptr <= stack_ptr - 1; 
                    
                    if (target_heading == heading) begin
                        cell_start_ticks <= avg_ticks;
                        state <= S_MOVE_NORMAL;
                    end 
                    else if (target_heading == (heading + 2'd1)) begin
                        turn_ref_diff <= right_count_wire - left_count_wire;
                        state <= S_TURN_R;
                    end 
                    else if (target_heading == (heading + 2'd3)) begin
                        turn_ref_diff <= left_count_wire - right_count_wire;
                        state <= S_TURN_L;
                    end 
                    else begin
                        turn_ref_diff <= left_count_wire - right_count_wire;
                        state <= S_TURN_U;
                    end
                end

                // --- MOVEMENT STATES ---
                S_MOVE_NORMAL: begin
                    cmd <= CMD_FWD;
                    odom_clear <= 1'b0;
                    
                    if (mi_box && !mi_box_prev) begin   // Previous value of mi_box for rising edge detection) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
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
                        
                        state <= S_WAIT;
                        wait_counter <= 0;
                    end
                end

                S_MOVE_POST_TURN: begin
                    cmd <= CMD_FWD;
                    odom_clear <= 1'b0;
                    
                    if (mi_box && !mi_box_prev) begin
                        cell_start_ticks <= avg_ticks;
                        
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        
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
                        
                        state <= S_WAIT;
                        wait_counter <= 0;
                    end
                end

                // --- TURN STATES ---
                S_TURN_L: begin
                     odom_clear <= 1'b0;
                    if (($signed(left_count_wire - right_count_wire) - turn_ref_diff) >= $signed(TICKS_L_90)) begin
                        cmd <= CMD_STOP;
                        post_turn_flag <= 1'b1;
                        heading <= heading + 2'd3; 
                        state <= S_WAIT; wait_counter <= 0;
                    end else cmd <= CMD_LEFT;
                end

                S_TURN_R: begin
                     odom_clear <= 1'b0;
                    if (($signed(right_count_wire - left_count_wire) - turn_ref_diff) >= $signed(TICKS_R_90)) begin
                        cmd <= CMD_STOP;
                        post_turn_flag <= 1'b1;
                        heading <= heading + 2'd1;
                        state <= S_WAIT; wait_counter <= 0;
                    end else cmd <= CMD_RIGHT;
                end

                S_TURN_U: begin
                     odom_clear <= 1'b0;
                    if (($signed(left_count_wire - right_count_wire) - turn_ref_diff) >= $signed(TICKS_U_180)) begin
                        cmd <= CMD_STOP;
                        post_turn_flag <= 1'b1;
                        if (uturn_count < 4'd9) uturn_count <= uturn_count + 4'd1;
                        heading <= heading + 2'd2;
                        state <= S_WAIT; wait_counter <= 0;
                    end else cmd <= CMD_UTURN;
                end

                S_WAIT: begin
                    cmd <= CMD_STOP;
                          odom_clear <= 1'b0;
                    if (wait_counter >= WAIT_DELAY) begin
                        wait_counter <= 0;
                        state <= S_DFS_UPDATE; 
                    end
                    else wait_counter <= wait_counter + 1;
                end

                S_STOP: begin
                    cmd <= CMD_STOP;
                          odom_clear <= 1'b1;
                    if (ir_top && !prev_btn) state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // ==========================================
    // 8. MODULE INSTANTIATIONS
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
        
        // --- Output Map Data ---
        .visited_cells(visited_cells), 
        .wall_north(wall_north),
        .wall_east(wall_east),
        
        .mpi_id(4'd0), .moisture_val(12'd0), .temp_int(8'd0), .temp_dec(8'd0), .hum_int(8'd0), .hum_dec(8'd0),
        .tx(bt_tx_wire),
        .busy(bt_busy)
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
        .duty_l(final_duty_r), .duty_r(final_duty_l),
        .dir_l(dir_l), .dir_r(dir_r),
        .IN1(IN1), .IN2(IN2), .IN3(IN3), .IN4(IN4),
        .ENA(ENA), .ENB(ENB)
    );

    odometry u_odom (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .enc_l_a(enc_l_a), .enc_r_a(enc_r_a),
        .dir_l(dir_l), .dir_r(dir_r),
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
        .thres_f(thres_f), .thres_l(thres_l), .thres_r(thres_r),
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

    // ==========================================
    // 9. UNUSED OUTPUTS
    // ==========================================
    assign servo_pwm_pin = 1'b0;
    assign adc_cs_n = 1'b1;
    assign adc_sclk = 1'b0;
    assign adc_saddr = 1'b0;
    assign bt_tx_pin = bt_tx_wire;
    assign dht_data_pin = 1'bz;

    always @(posedge clk_50M) begin
        wall_status <= wall; 
    end

endmodule