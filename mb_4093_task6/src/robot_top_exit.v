module robot_top_exit(
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

    // =========================================================================
    // PARAMETERS  — identical to integrated module
    // =========================================================================
    localparam TICKS_PER_CELL_MIN   = 11'd1100;
    localparam TICKS_PER_CELL_MAX   = 11'd1300;
    localparam TICKS_PER_CELL_AVG   = 11'd1200;
    localparam TICKS_AFTER_TURN_MIN = 11'd700;
    localparam TICKS_AFTER_TURN_MAX = 11'd800;
    localparam TICKS_AFTER_TURN_AVG = 11'd750;

    localparam DIR_NORTH = 2'b00;
    localparam DIR_EAST  = 2'b01;
    localparam DIR_SOUTH = 2'b10;
    localparam DIR_WEST  = 2'b11;

    localparam HIGH_SPEED  = 7'd70;
    localparam MED_SPEED   = 7'd40;
    localparam SLOW_SPEED  = 7'd30;

    localparam WAIT_DELAY    = 27'd10_000_000;   // 0.2 s
    localparam IDLE_DELAY    = 27'd100_000_000;  // 2.0 s

    localparam TURN_MIN_TIME = 27'd25_000_000;   // 0.5 s
    localparam TURN_MAX_TIME = 27'd100_000_000;  // 2.0 s

    localparam signed K_CENTER = 7'sd3;

    localparam thres_l = 16'd140;
    localparam thres_r = 16'd140;
    localparam thres_f = 16'd140;

    localparam TICKS_L_90   = 16'd680;
    localparam TICKS_R_90   = 16'd730;
    localparam TURN_SPEED_H = 7'd50;
    localparam TURN_SPEED_L = 7'd0;

    // =========================================================================
    // FSM STATE ENCODING
    // =========================================================================
    // A* states (pre-start)
    localparam S_ASTAR_INIT     = 5'd0;
    localparam S_ASTAR_FIND_MIN = 5'd1;
    localparam S_ASTAR_EXPAND   = 5'd2;
    localparam S_ASTAR_RETRACE  = 5'd3;
    localparam S_ASTAR_REVERSE  = 5'd4;

    // Movement states
    localparam S_IDLE      = 5'd5;
    localparam S_EVAL      = 5'd6;
    localparam S_TURN_LEFT = 5'd7;
    localparam S_TURN_RIGHT= 5'd8;
    localparam S_MOVE_NRM  = 5'd9;
    localparam S_MOVE_POST = 5'd10;
    localparam S_WAIT_ST   = 5'd11;
    localparam S_STOP_ST   = 5'd12;

    // Motor commands
    localparam CMD_STOP  = 3'd0;
    localparam CMD_FWD   = 3'd1;
    localparam CMD_LEFT  = 3'd2;
    localparam CMD_RIGHT = 3'd3;

    // =========================================================================
    // HARDCODED MAZE WALLS
    // =========================================================================
    localparam [80:0] WALL_NORTH_CONST =
        81'b111101111_010100001_001000110_010111011_000010110_011001001_001100001_110111010_001000110;
    localparam [80:0] WALL_EAST_CONST  =
        81'b100101000_101011110_110101010_111100100_110110100_110011110_101000010_101010101_110011000;

    localparam [3:0] START_X  = 4'd4;
    localparam [3:0] START_Y  = 4'd0;
    localparam [3:0] EXIT_X   = 4'd4;
    localparam [3:0] EXIT_Y   = 4'd8;
    localparam [6:0] START_ID = 7'd4;
    localparam [6:0] EXIT_ID  = 7'd76;

    // =========================================================================
    // INTERNAL SIGNALS
    // =========================================================================
    reg [4:0]  state;
    reg [2:0]  cmd;
    reg [26:0] wait_counter;
    reg [26:0] idle_counter;
    reg [4:0]  wait_return_state;

    // Robot pose
    reg [3:0] robot_x, robot_y;
    reg [1:0] heading;
    reg post_turn_flag;
    reg front_wall_prev;

    // Odometry — exact same signals as integrated
    wire signed [16:0] left_count_wire, right_count_wire;
    reg  odom_clear, odom_clear_pulse;
    wire signed [16:0] avg_ticks;
    reg  signed [16:0] cell_start_ticks;
    wire [16:0] cell_current_ticks;
    wire cell_crossed_normal, cell_crossed_post_turn, cell_crossed;

    // Turn control — exact same as integrated
    reg signed [16:0] saved_turn_ref;
    reg turn_ref_captured;
    reg [26:0] turn_timer;

    // Sensors
    wire [15:0] distance_l, distance_r, distance_f;
    wire [2:0]  wall;
    wire deadend, mi_box, front_wall;

    // PD — exact same wiring as integrated
    wire signed [15:0] pd_input, pd_ref, pd_kp, pd_kd;
    wire signed [6:0]  corrected_val, pid_l, pid_r;
    reg  signed [6:0]  pd_clamp;

    // Motor mixer — exact same as integrated
    reg [6:0] final_duty_l, final_duty_r;
    reg dir_l, dir_r;
    reg signed [8:0] duty_l_tmp, duty_r_tmp;
    reg [6:0] adaptive_speed;

    // BT
    wire start_flag;
    wire [3:0] mpi_target;
    reg  prev_btn;
    wire bt_busy;

    // =========================================================================
    // A* DATA STRUCTURES
    // =========================================================================
    reg [6:0]  g_score   [0:80];
    reg [6:0]  came_from [0:80];
    reg [80:0] open_set;
    reg [80:0] closed_set;

    reg [6:0] astar_current;
    reg [6:0] astar_scan_idx;
    reg [6:0] astar_min_id;
    reg [7:0] astar_min_f;
    reg       astar_found;

    // Path arrays — sized to 48 (path is 43 cells)
    reg [6:0] path_cells [0:47];
    reg [6:0] path_fwd   [0:47];
    reg [5:0] path_len;
    reg [5:0] path_idx;    // index of NEXT waypoint to reach
    reg [5:0] retrace_idx;

    // Neighbour expansion scratch
    reg [6:0] nb_id   [0:3];
    reg       nb_valid[0:3];
    reg [7:0] nb_g    [0:3];
    integer   ni;

    // =========================================================================
    // PATH BITMASKS FOR BT MESSENGER
    // =========================================================================
    reg [80:0] path_mask;
    reg [80:0] remaining_mask;

    integer ri;
    reg [80:0] remain_comb;
    always @(*) begin
        remain_comb = 81'b0;
        for (ri = 0; ri < 48; ri = ri + 1) begin
            if (ri[5:0] >= path_idx && ri[5:0] < path_len)
                remain_comb[path_fwd[ri]] = 1'b1;
        end
    end
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) remaining_mask <= 81'b0;
        else          remaining_mask <= remain_comb;
    end

    reg send_path_pulse;
    reg send_step_pulse;

    // =========================================================================
    // LOOKAHEAD SPEED LOGIC
    // For the current cell (path_idx-1 just arrived at), look at:
    //   - heading needed to reach path_fwd[path_idx]   (current move)
    //   - heading needed to reach path_fwd[path_idx+1] (next move)
    // If same direction → HIGH_SPEED, else → MED_SPEED
    // =========================================================================
    wire [6:0] la_cur_cell  = (path_idx >= 6'd1 && path_idx < path_len)
                              ? path_fwd[path_idx - 6'd1] : START_ID;
    wire [6:0] la_next_cell = (path_idx < path_len)
                              ? path_fwd[path_idx] : EXIT_ID;
    wire [6:0] la_after_cell= (path_idx + 6'd1 < path_len)
                              ? path_fwd[path_idx + 6'd1] : EXIT_ID;

    wire [3:0] la_cur_x  = la_cur_cell  % 4'd9;
    wire [3:0] la_cur_y  = la_cur_cell  / 4'd9;
    wire [3:0] la_next_x = la_next_cell % 4'd9;
    wire [3:0] la_next_y = la_next_cell / 4'd9;
    wire [3:0] la_aft_x  = la_after_cell % 4'd9;
    wire [3:0] la_aft_y  = la_after_cell / 4'd9;

    // Heading of current move (cur→next)
    wire [1:0] la_h1 = (la_next_y > la_cur_y)  ? DIR_NORTH :
                       (la_next_x > la_cur_x)  ? DIR_EAST  :
                       (la_next_y < la_cur_y)  ? DIR_SOUTH : DIR_WEST;

    // Heading of next move (next→after)
    wire [1:0] la_h2 = (la_aft_y > la_next_y)  ? DIR_NORTH :
                       (la_aft_x > la_next_x)  ? DIR_EAST  :
                       (la_aft_y < la_next_y)  ? DIR_SOUTH : DIR_WEST;

    // Speed decision: HIGH only if consecutive moves share same heading
    wire lookahead_straight = (la_h1 == la_h2) && (path_idx + 6'd1 < path_len);

    // =========================================================================
    // WALL QUERY FUNCTIONS
    // =========================================================================
    function can_go_north;
        input [6:0] id;
        begin can_go_north = (id / 7'd9 < 7'd8) && !WALL_NORTH_CONST[id]; end
    endfunction
    function can_go_south;
        input [6:0] id;
        begin can_go_south = (id / 7'd9 > 7'd0) && !WALL_NORTH_CONST[id - 7'd9]; end
    endfunction
    function can_go_east;
        input [6:0] id;
        begin can_go_east = (id % 7'd9 < 7'd8) && !WALL_EAST_CONST[id]; end
    endfunction
    function can_go_west;
        input [6:0] id;
        begin can_go_west = (id % 7'd9 > 7'd0) && !WALL_EAST_CONST[id - 7'd1]; end
    endfunction

    function [6:0] heuristic;
        input [6:0] id;
        reg [3:0] cx, cy;
        begin
            cx = id % 7'd9;
            cy = id / 7'd9;
            heuristic = ((cx > EXIT_X) ? (cx - EXIT_X) : (EXIT_X - cx))
                      + ((cy > EXIT_Y) ? (cy - EXIT_Y) : (EXIT_Y - cy));
        end
    endfunction

    // =========================================================================
    // DERIVED SIGNALS  — identical to integrated module
    // =========================================================================
    assign avg_ticks          = (left_count_wire + right_count_wire) >>> 1;
    assign cell_current_ticks = avg_ticks - cell_start_ticks;

    assign cell_crossed_normal    = (cell_current_ticks >= TICKS_PER_CELL_AVG);
    assign cell_crossed_post_turn = (cell_current_ticks >= TICKS_AFTER_TURN_AVG);

    // cell_crossed mux: exact same logic as integrated
    assign cell_crossed = (state == S_MOVE_POST) ? cell_crossed_post_turn : cell_crossed_normal;

    assign debug_x       = robot_x;
    assign debug_y       = robot_y;
    assign debug_heading = heading;

    // PD wiring — identical to integrated
    assign pd_ref   = wall[1] ? 16'd70 : 16'd60;
    assign pd_input = wall[1] ? distance_l : (wall[0] ? distance_r : 16'd70);
    assign pd_kp    = 16'sd30;
    assign pd_kd    = 16'sd10;
    assign pid_l    =  wall[1]              ? corrected_val : 7'sd0;
    assign pid_r    = (!wall[1] && wall[0]) ? corrected_val : 7'sd0;

    // Required heading to reach next waypoint
    wire [6:0] id_next = (path_idx < path_len) ? path_fwd[path_idx] : {7{1'b0}};
    wire [3:0] next_x  = id_next % 4'd9;
    wire [3:0] next_y  = id_next / 4'd9;

    wire [1:0] required_heading =
        (next_y > robot_y) ? DIR_NORTH :
        (next_x > robot_x) ? DIR_EAST  :
        (next_y < robot_y) ? DIR_SOUTH : DIR_WEST;

    // =========================================================================
    // ADAPTIVE SPEED  — lookahead replaces distance_f check
    // HIGH_SPEED only when next two moves are in the same direction
    // MED_SPEED when a turn is coming (or near end of path)
    // pd_clamp tracks with speed as in integrated
    // =========================================================================
    always @(*) begin
        if ((state == S_MOVE_NRM) && lookahead_straight) begin
            adaptive_speed = HIGH_SPEED;
            pd_clamp       = 7'sd20;
        end else begin
            adaptive_speed = MED_SPEED;
            pd_clamp       = 7'sd15;
        end
    end

    // =========================================================================
    // MOTOR MIXER  — identical to integrated module
    // =========================================================================
    always @(*) begin
        final_duty_l = 0; final_duty_r = 0;
        dir_l = 1;        dir_r = 1;
        duty_l_tmp = 0;   duty_r_tmp = 0;

        case (cmd)
            CMD_FWD: begin
                duty_l_tmp = $signed({1'b0, adaptive_speed}) + pid_l - pid_r;
                duty_r_tmp = $signed({1'b0, adaptive_speed}) - pid_l + pid_r;
                if      (duty_l_tmp < 20) final_duty_l = 20;
                else if (duty_l_tmp > 90) final_duty_l = 90;
                else                      final_duty_l = duty_l_tmp[6:0];
                if      (duty_r_tmp < 20) final_duty_r = 20;
                else if (duty_r_tmp > 90) final_duty_r = 90;
                else                      final_duty_r = duty_r_tmp[6:0];
            end
            CMD_LEFT: begin
                final_duty_l = TURN_SPEED_L; dir_l = 1;
                final_duty_r = TURN_SPEED_H; dir_r = 0;
            end
            CMD_RIGHT: begin
                final_duty_l = TURN_SPEED_H; dir_l = 0;
                final_duty_r = TURN_SPEED_L; dir_r = 1;
            end
            CMD_STOP: begin
                final_duty_l = 0; final_duty_r = 0;
            end
            default: begin
                final_duty_l = 0; final_duty_r = 0;
            end
        endcase
    end

    // =========================================================================
    // COORDINATE UPDATE TASK
    // Used identically in S_MOVE_NRM and S_MOVE_POST to avoid duplication
    // =========================================================================
    // (inline macro-style — done in both move states below)

    // =========================================================================
    // MAIN FSM
    // =========================================================================
    integer i;

    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            // ------------------------------------------------------------------
            // RESET
            // ------------------------------------------------------------------
            state             <= S_ASTAR_INIT;
            cmd               <= CMD_STOP;
            heading           <= DIR_NORTH;
            robot_x           <= START_X;
            robot_y           <= START_Y;
            post_turn_flag    <= 1'b0;
            front_wall_prev   <= 1'b0;
            uturn_count       <= 4'd0;
            prev_btn          <= 1'b0;

            odom_clear        <= 1'b1;
            odom_clear_pulse  <= 1'b0;
            cell_start_ticks  <= 17'sd0;

            saved_turn_ref    <= 17'sd0;
            turn_ref_captured <= 1'b0;
            turn_timer        <= 27'd0;

            wait_counter      <= 27'd0;
            idle_counter      <= 27'd0;
            wait_return_state <= S_IDLE;

            path_len          <= 6'd0;
            path_idx          <= 6'd0;
            path_mask         <= 81'b0;

            open_set          <= 81'b0;
            closed_set        <= 81'b0;
            astar_current     <= 7'd0;
            astar_scan_idx    <= 7'd0;
            astar_min_id      <= 7'd0;
            astar_min_f       <= 8'hFF;
            astar_found       <= 1'b0;
            retrace_idx       <= 6'd0;

            send_path_pulse   <= 1'b0;
            send_step_pulse   <= 1'b0;

            speed_l           <= 7'd0;
            speed_r           <= 7'd0;
            state_check       <= 5'd0;
            pd_check          <= 7'sd0;
            debug_us          <= 16'd0;

            for (i = 0; i < 81; i = i + 1) begin
                g_score[i]   <= 7'h7F;
                came_from[i] <= 7'h7F;
            end
            for (i = 0; i < 48; i = i + 1) begin
                path_cells[i] <= 7'd0;
                path_fwd[i]   <= 7'd0;
            end
        end
        else begin
            // ------------------------------------------------------------------
            // REGISTERED OUTPUTS each cycle
            // ------------------------------------------------------------------
            send_path_pulse <= 1'b0;
            send_step_pulse <= 1'b0;

            speed_l     <= final_duty_l;
            speed_r     <= final_duty_r;
            state_check <= state;
            pd_check    <= corrected_val;
            debug_us    <= distance_f;

            front_wall_prev <= front_wall;

            // ------------------------------------------------------------------
            // ODOMETRY CLEAR — identical to integrated
            // odom_clear_pulse fires one cycle, odom_clear follows one cycle later
            // ------------------------------------------------------------------
            odom_clear_pulse <= 1'b0;
            if (cell_crossed) begin
                cell_start_ticks <= avg_ticks;
                odom_clear_pulse <= 1'b1;
            end
            odom_clear <= odom_clear_pulse;

            prev_btn <= ir_top;

            // ------------------------------------------------------------------
            // STATE MACHINE
            // ------------------------------------------------------------------
            case (state)

                // ==============================================================
                // A* PHASE — completes before start_flag arrives
                // ==============================================================

                S_ASTAR_INIT: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b1;

                    for (i = 0; i < 81; i = i + 1) begin
                        g_score[i]   <= 7'h7F;
                        came_from[i] <= 7'h7F;
                    end
                    g_score[START_ID]  <= 7'd0;
                    open_set           <= 81'b0;
                    open_set[START_ID] <= 1'b1;
                    closed_set         <= 81'b0;
                    astar_found        <= 1'b0;
                    astar_scan_idx     <= 7'd0;
                    astar_min_f        <= 8'hFF;
                    astar_min_id       <= START_ID;
                    path_mask          <= 81'b0;
                    state              <= S_ASTAR_FIND_MIN;
                end

                // --------------------------------------------------------------
                S_ASTAR_FIND_MIN: begin
                    cmd <= CMD_STOP;
                    if (open_set == 81'b0) begin
                        state <= S_STOP_ST;   // no path
                    end
                    else if (astar_scan_idx < 7'd81) begin
                        if (open_set[astar_scan_idx]) begin
                            if ((g_score[astar_scan_idx] + heuristic(astar_scan_idx)) < astar_min_f) begin
                                astar_min_f  <= g_score[astar_scan_idx] + heuristic(astar_scan_idx);
                                astar_min_id <= astar_scan_idx;
                            end
                        end
                        astar_scan_idx <= astar_scan_idx + 7'd1;
                    end
                    else begin
                        astar_current  <= astar_min_id;
                        astar_scan_idx <= 7'd0;
                        astar_min_f    <= 8'hFF;
                        astar_min_id   <= 7'd0;
                        if (astar_min_id == EXIT_ID) begin
                            astar_found <= 1'b1;
                            retrace_idx <= 6'd0;
                            state       <= S_ASTAR_RETRACE;
                        end
                        else
                            state <= S_ASTAR_EXPAND;
                    end
                end

                // --------------------------------------------------------------
                S_ASTAR_EXPAND: begin
                    cmd <= CMD_STOP;

                    open_set[astar_current]   <= 1'b0;
                    closed_set[astar_current] <= 1'b1;

                    if (can_go_north(astar_current)) begin
                        nb_id[0]    = astar_current + 7'd9;
                        nb_valid[0] = !closed_set[astar_current + 7'd9];
                        nb_g[0]     = g_score[astar_current] + 8'd1;
                    end else begin nb_valid[0]=1'b0; nb_id[0]=7'd0; nb_g[0]=8'hFF; end

                    if (can_go_south(astar_current)) begin
                        nb_id[1]    = astar_current - 7'd9;
                        nb_valid[1] = !closed_set[astar_current - 7'd9];
                        nb_g[1]     = g_score[astar_current] + 8'd1;
                    end else begin nb_valid[1]=1'b0; nb_id[1]=7'd0; nb_g[1]=8'hFF; end

                    if (can_go_east(astar_current)) begin
                        nb_id[2]    = astar_current + 7'd1;
                        nb_valid[2] = !closed_set[astar_current + 7'd1];
                        nb_g[2]     = g_score[astar_current] + 8'd1;
                    end else begin nb_valid[2]=1'b0; nb_id[2]=7'd0; nb_g[2]=8'hFF; end

                    if (can_go_west(astar_current)) begin
                        nb_id[3]    = astar_current - 7'd1;
                        nb_valid[3] = !closed_set[astar_current - 7'd1];
                        nb_g[3]     = g_score[astar_current] + 8'd1;
                    end else begin nb_valid[3]=1'b0; nb_id[3]=7'd0; nb_g[3]=8'hFF; end

                    for (ni = 0; ni < 4; ni = ni + 1) begin
                        if (nb_valid[ni] && (nb_g[ni] < g_score[nb_id[ni]])) begin
                            g_score[nb_id[ni]]   <= nb_g[ni][6:0];
                            came_from[nb_id[ni]] <= astar_current;
                            open_set[nb_id[ni]]  <= 1'b1;
                        end
                    end

                    astar_min_f    <= 8'hFF;
                    astar_min_id   <= 7'd0;
                    astar_scan_idx <= 7'd0;
                    state <= S_ASTAR_FIND_MIN;
                end

                // --------------------------------------------------------------
                // Walk came_from[] from EXIT back to START
                // path_cells[0]=EXIT, path_cells[N]=START
                // --------------------------------------------------------------
                S_ASTAR_RETRACE: begin
                    cmd <= CMD_STOP;
                    if (astar_current == START_ID || came_from[astar_current] == 7'h7F) begin
                        path_cells[retrace_idx] <= START_ID;
                        path_len    <= retrace_idx + 6'd1;
                        retrace_idx <= 6'd0;
                        state       <= S_ASTAR_REVERSE;
                    end
                    else begin
                        path_cells[retrace_idx] <= astar_current;
                        retrace_idx             <= retrace_idx + 6'd1;
                        astar_current           <= came_from[astar_current];
                    end
                end

                // --------------------------------------------------------------
                // Reverse into path_fwd[] and build path_mask
                // path_fwd[0]=START, path_fwd[path_len-1]=EXIT
                // --------------------------------------------------------------
                S_ASTAR_REVERSE: begin
                    cmd <= CMD_STOP;
                    if (retrace_idx < path_len) begin
                        path_fwd[retrace_idx]                                          <= path_cells[(path_len - 6'd1) - retrace_idx];
                        path_mask[path_cells[(path_len - 6'd1) - retrace_idx]]         <= 1'b1;
                        retrace_idx <= retrace_idx + 6'd1;
                    end
                    else begin
                        // Path ready — path_fwd[0]=START, skip it, begin at [1]
                        path_idx        <= 6'd1;
                        send_path_pulse <= 1'b1;
                        state           <= S_IDLE;
                    end
                end

                // ==============================================================
                // IDLE — wait for start_flag from BT (START-x-#)
                // Identical delay logic to integrated module
                // ==============================================================
                S_IDLE: begin
                    cmd            <= CMD_STOP;
                    odom_clear     <= 1'b1;
                    post_turn_flag <= 1'b0;

                    if (idle_counter >= IDLE_DELAY && start_flag) begin
                        cell_start_ticks <= avg_ticks;
                        idle_counter     <= 27'd0;
                        odom_clear       <= 1'b0;
                        state            <= S_EVAL;
                    end
                    else
                        idle_counter <= idle_counter + 27'd1;
                end

                // ==============================================================
                // S_EVAL — mirrors S_DFS_EVALUATE in integrated module
                //
                // Handles:
                //   1. post_turn_flag: came back from a turn → post-turn move
                //   2. Path exhausted → STOP
                //   3. Next waypoint straight ahead → MOVE_NORMAL
                //   4. Turn needed → WAIT → TURN_L/R
                //
                // WAIT is inserted BEFORE every turn (same as integrated)
                // ==============================================================
                S_EVAL: begin
                    cmd <= CMD_STOP;

                    if (post_turn_flag) begin
                        // Just finished a turn — do post-turn forward burst
                        post_turn_flag   <= 1'b0;
                        cell_start_ticks <= avg_ticks;
                        state            <= S_MOVE_POST;
                    end
                    else if (path_idx >= path_len) begin
                        state <= S_STOP_ST;
                    end
                    else if (required_heading == heading) begin
                        // Straight ahead — no turn needed
                        cell_start_ticks <= avg_ticks;
                        state            <= S_MOVE_NRM;
                    end
                    else if (required_heading == ((heading + 2'd1) & 2'd3)) begin
                        // Need right turn — wait 0.2s first (same as integrated)
                        wait_return_state <= S_TURN_RIGHT;
                        state             <= S_WAIT_ST;
                        wait_counter      <= 27'd0;
                    end
                    else if (required_heading == ((heading + 2'd3) & 2'd3)) begin
                        // Need left turn
                        wait_return_state <= S_TURN_LEFT;
                        state             <= S_WAIT_ST;
                        wait_counter      <= 27'd0;
                    end
                    else begin
                        // 180° needed — two right turns, no U-turn
                        // First right turn; S_EVAL will detect the remaining 90° on return
                        wait_return_state <= S_TURN_RIGHT;
                        state             <= S_WAIT_ST;
                        wait_counter      <= 27'd0;
                    end
                end

                // ==============================================================
                // S_MOVE_NRM — mirrors S_MOVE_NORMAL in integrated module exactly
                //
                // Coordinate update happens HERE (on cell_crossed or front_wall),
                // NOT in S_EVAL. After update → WAIT → S_EVAL.
                // ==============================================================
                S_MOVE_NRM: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        // IR safety override — treat as cell reached
                        // Update coordinates
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase

                        path_idx          <= path_idx + 6'd1;
                        send_step_pulse   <= 1'b1;
                        cmd               <= CMD_STOP;
                        // Wait 0.2s then go back to evaluate
                        wait_return_state <= S_EVAL;
                        state             <= S_WAIT_ST;
                        wait_counter      <= 27'd0;
                    end
                    else if (cell_crossed_normal) begin
                        // Tick counter confirms cell crossed
                        cell_start_ticks <= avg_ticks;

                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase

                        path_idx        <= path_idx + 6'd1;
                        send_step_pulse <= 1'b1;

                        if (path_idx + 6'd1 >= path_len)
                            state <= S_STOP_ST;
                        else
                            state <= S_EVAL;
                    end
                end

                // ==============================================================
                // S_MOVE_POST — mirrors S_MOVE_POST_TURN in integrated exactly
                // Entered after every turn via post_turn_flag
                // Uses TICKS_AFTER_TURN_AVG (750) not full cell ticks
                // Coordinate update happens here too
                // ==============================================================
                S_MOVE_POST: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase

                        path_idx          <= path_idx + 6'd1;
                        send_step_pulse   <= 1'b1;
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_EVAL;
                        state             <= S_WAIT_ST;
                        wait_counter      <= 27'd0;
                    end
                    else if (cell_crossed_post_turn) begin
                        cell_start_ticks <= avg_ticks;

                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase

                        path_idx        <= path_idx + 6'd1;
                        send_step_pulse <= 1'b1;

                        if (path_idx + 6'd1 >= path_len)
                            state <= S_STOP_ST;
                        else
                            state <= S_EVAL;
                    end
                end

                // ==============================================================
                // S_TURN_LEFT — identical encoder-differential logic to integrated
                //
                // Flow: S_EVAL → S_WAIT_ST → S_TURN_LEFT
                //       S_TURN_LEFT finishes → S_WAIT_ST → S_EVAL
                //       S_EVAL sees post_turn_flag → S_MOVE_POST
                // ==============================================================
                S_TURN_LEFT: begin
                    odom_clear <= 1'b0;

                    if (!turn_ref_captured) begin
                        // Capture reference on first entry cycle
                        saved_turn_ref    <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_LEFT;
                        turn_timer        <= 27'd0;
                    end
                    else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_LEFT;

                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_L_90)
                                || turn_timer >= TURN_MAX_TIME)
                            begin
                                cmd               <= CMD_STOP;
                                heading           <= (heading + 2'd3) & 2'd3;  // -1 mod 4
                                turn_ref_captured <= 1'b0;
                                post_turn_flag    <= 1'b1;
                                // Wait 0.2s after turn then go to S_EVAL
                                // S_EVAL will see post_turn_flag and go to S_MOVE_POST
                                wait_return_state <= S_EVAL;
                                state             <= S_WAIT_ST;
                                wait_counter      <= 27'd0;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_TURN_RIGHT — identical to integrated
                // ==============================================================
                S_TURN_RIGHT: begin
                    odom_clear <= 1'b0;

                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= right_count_wire - left_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_RIGHT;
                        turn_timer        <= 27'd0;
                    end
                    else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_RIGHT;

                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(right_count_wire - left_count_wire) - saved_turn_ref) >= $signed(TICKS_R_90)
                                || turn_timer >= TURN_MAX_TIME)
                            begin
                                cmd               <= CMD_STOP;
                                heading           <= (heading + 2'd1) & 2'd3;
                                turn_ref_captured <= 1'b0;
                                post_turn_flag    <= 1'b1;
                                wait_return_state <= S_EVAL;
                                state             <= S_WAIT_ST;
                                wait_counter      <= 27'd0;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_WAIT_ST — generic 0.2s delay, identical to integrated S_WAIT
                // ==============================================================
                S_WAIT_ST: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b0;

                    if (wait_counter >= WAIT_DELAY) begin
                        wait_counter <= 27'd0;
                        state        <= wait_return_state;
                    end
                    else
                        wait_counter <= wait_counter + 27'd1;
                end

                // ==============================================================
                // S_STOP_ST — bot has reached exit or path failed
                // ==============================================================
                S_STOP_ST: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b1;
                    if (ir_top && !prev_btn) state <= S_IDLE;
                end

                default: state <= S_IDLE;

            endcase
        end
    end

    // =========================================================================
    // DEBUG OUTPUT
    // =========================================================================
    always @(posedge clk_50M) begin
        wall_status <= wall;
    end

    // =========================================================================
    // MODULE INSTANTIATIONS
    // =========================================================================

    bt_receiver u_bt_rx (
        .clk_50     (clk_50M),
        .reset      (~reset_n),
        .rx         (bt_rx_pin),
        .start_signal(start_flag),
        .mpi_count  (mpi_target)
    );

    bt_exit_messenger u_bt_exit (
        .clk           (clk_50M),
        .reset         (~reset_n),
        .send_path     (send_path_pulse),
        .send_step     (send_step_pulse),
        .path_mask     (path_mask),
        .remaining_mask(remaining_mask),
        .tx            (bt_tx_pin),
        .busy          (bt_busy)
    );

    pd_control_dd u_pid (
        .clk_50M      (clk_50M),
        .reset_n      (reset_n),
        .input_val    (pd_input),
        .ref_val      (pd_ref),
        .kp           (pd_kp),
        .kd           (pd_kd),
        .clamp        (pd_clamp),
        .corrected_val(corrected_val)
    );

    drive u_drive (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .duty_l (final_duty_r),   // swapped as in original
        .duty_r (final_duty_l),
        .dir_l  (dir_l),
        .dir_r  (dir_r),
        .IN1(IN1), .IN2(IN2), .IN3(IN3), .IN4(IN4),
        .ENA(ENA), .ENB(ENB)
    );

    odometry u_odom (
        .clk_50M    (clk_50M),
        .reset_n    (reset_n),
        .enc_l_a    (enc_l_a),
        .enc_r_a    (enc_r_a),
        .dir_l      (dir_l),
        .dir_r      (dir_r),
        .clear      (odom_clear),
        .left_count (left_count_wire),
        .right_count(right_count_wire)
    );

    sensor_interface u_sensors (
        .clk_50M   (clk_50M),
        .reset_n   (reset_n),
        .us_echo_f (us_echo_f),
        .us_echo_l (us_echo_l),
        .us_echo_r (us_echo_r),
        .ir_top    (ir_top),
        .ir_down   (ir_down),
        .ir_middle (ir_middle),
        .thres_f   (thres_f),
        .thres_l   (thres_l),
        .thres_r   (thres_r),
        .us_trig_f (us_trig_f),
        .us_trig_l (us_trig_l),
        .us_trig_r (us_trig_r),
        .wall      (wall),
        .deadend   (deadend),
        .mi_box    (mi_box),
        .front_wall(front_wall),
        .distance_l(distance_l),
        .distance_r(distance_r),
        .distance_f(distance_f)
    );

    // =========================================================================
    // UNUSED PORT TIE-OFFS
    // =========================================================================
    assign dht_data_pin  = 1'bz;
    assign servo_pwm_pin = 1'b0;
    assign adc_cs_n      = 1'b1;
    assign adc_sclk      = 1'b0;
    assign adc_saddr     = 1'b0;

endmodule