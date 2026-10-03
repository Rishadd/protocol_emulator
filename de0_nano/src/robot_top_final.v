/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: robot_top_final.v
# File Description: Top-level module for the eYRC maze solver robot.
# Global variables: None
*/

// =============================================================================
//
// Phase 1 — DFS Exploration:
//   The robot navigates a 9x9 grid using iterative depth-first search,
//   recording north and east walls as it goes. At each dead-end flagged
//   by the sensor interface, it performs an MPI measurement cycle
//   (moisture, temperature, humidity) via mpi_top.
//
// Phase 2 — A* Exit Navigation:
//   Once all requested measurements are complete, the robot hands its
//   current position and the fully-explored wall map to exit_nav, which
//   computes an A* path to cell (4,8). The master FSM then follows that
//   path using the same turn/forward primitives as DFS. On reaching (4,8)
//   the robot drives one extra cell to physically clear the maze structure,
//   then halts and sends a run-end message over Bluetooth.
//
// Bluetooth traffic:
//   RX — START-*-# command (mpi_count parsed by bt_receiver)
//   TX — MPI measurement results only (via mpi_top) + one end message
//        No map data, no coordinate broadcasts.
//
// Grid convention: cell id = (y * 9) + x.  Origin (0,0) is bottom-left.
//   wall_north[id] = wall on the NORTH face of cell id
//   wall_east[id]  = wall on the EAST  face of cell id
//
// =============================================================================


module robot_top_final (
    // Clock and reset
    input  clk_50M,
    input  reset_n,

    // Sensor inputs
    input  us_echo_f, us_echo_l, us_echo_r,   // ultrasonic echo signals
    input  ir_top, ir_down, ir_middle,         // IR sensors
    input  enc_l_a, enc_r_a,                  // encoder channel A (left, right)
    inout  dht_data_pin,                       // DHT humidity/temp sensor (bidirectional)

    // Actuator outputs
    output servo_pwm_pin,                      // servo for MPI arm positioning
    output IN1, IN2, IN3, IN4,                 // motor direction pins
    output ENA, ENB,                           // motor PWM enable pins
    output us_trig_f, us_trig_l, us_trig_r,   // ultrasonic trigger outputs

    // ADC (moisture sensor)
    input  adc_sdat,
    output adc_cs_n,
    output adc_sclk,
    output adc_saddr,

    // Bluetooth
    input  bt_rx_pin,
    output bt_tx_pin,

    // Debug outputs (wired to FPGA LEDs / logic analyser)
    output reg [2:0]        wall_status,    // live wall[2:0] snapshot
    output reg [4:0]        state_check,    // current FSM state
    output reg signed [6:0] pd_check,       // PD corrected_val
    output reg [6:0]        speed_l,        // left  motor duty (%)
    output reg [6:0]        speed_r,        // right motor duty (%)
    output reg [3:0]        uturn_count,    // number of U-turns executed
    output reg [15:0]       debug_us,       // front ultrasonic distance (cm)
    output [3:0]            debug_x,        // robot X coordinate
    output [3:0]            debug_y,        // robot Y coordinate
    output [1:0]            debug_heading   // robot heading (00=N 01=E 10=S 11=W)
);

    // =========================================================================
    // TIMING / TICK PARAMETERS
    // =========================================================================
    // All tick counts are measured in encoder pulses (avg of L and R wheels).
    // Empirically tuned for the physical maze cell size.
    localparam TICKS_PER_CELL_AVG    = 11'd1200; // encoder ticks to cross one full cell
    localparam TICKS_AFTER_TURN_AVG  = 11'd750;  // shorter burst after a 90° turn
    localparam TICKS_AFTER_UTURN_AVG = 11'd500;  // shorter burst after a 180° U-turn

    // Turn completion: a valid turn must last at least TURN_MIN_TIME clock cycles
    // before the encoder threshold is checked, and is forced complete at TURN_MAX_TIME.
    // At 50 MHz: TURN_MIN_TIME = 0.5 s, TURN_MAX_TIME = 1.5 s.
    localparam TURN_MIN_TIME   = 27'd25_000_000;
    localparam TURN_MAX_TIME   = 27'd70_000_000;

    // Encoder-tick thresholds for each turn type
    localparam TICKS_L_90  = 16'd680;   // left-wheel minus right-wheel ticks for 90° left
    localparam TICKS_R_90  = 16'd730;   // right-wheel minus left-wheel ticks for 90° right
    localparam TICKS_U_180 = 16'd1300;  // differential ticks for a 180° U-turn

    // S_WAIT inter-state pause (0.2 s).  Inserted before/after every turn.
    localparam WAIT_DELAY      = 27'd10_000_000;

    // MPI measurement timing
    localparam MPI_WAIT_DELAY  = 27'd15_000_000;  // settle time before triggering sensor (0.3 s)
    localparam CRAWL_REV_DELAY = 27'd50_000_000;  // reverse-crawl duration before creeping forward (1.0 s)

    // =========================================================================
    // HEADING AND DIRECTION CONSTANTS
    // =========================================================================
    localparam DIR_NORTH = 2'b00;
    localparam DIR_EAST  = 2'b01;
    localparam DIR_SOUTH = 2'b10;
    localparam DIR_WEST  = 2'b11;

    // =========================================================================
    // SPEED PARAMETERS (percent duty cycle, 0–100)
    // =========================================================================
    localparam HIGH_SPEED  = 7'd70;  // open corridor — robot accelerates
    localparam MED_SPEED   = 7'd40;  // near walls or approaching turns

    // Crawl speed for the dead-end approach/retreat sequence.
    // Slightly asymmetric (27 vs 30) compensates for motor trim differences.
    localparam CRAWL_SPEED = 7'd27;

    // Turn duty cycles: one wheel stops, the other drives.
    localparam TURN_SPEED_H = 7'd50;  // driving wheel during turn
    localparam TURN_SPEED_L = 7'd0;   // stopped wheel during turn
    localparam UTURN_SPEED  = 7'd50;  // both wheels, opposite directions

    // =========================================================================
    // ULTRASONIC WALL-DETECTION THRESHOLDS (cm)
    // =========================================================================
    // A reading below these thresholds is treated as a wall present.
    localparam thres_f = 16'd140;  // front
    localparam thres_l = 16'd140;  // left
    localparam thres_r = 16'd140;  // right

    // =========================================================================
    // PD CONTROLLER — WALL-FOLLOWING GAIN
    // =========================================================================
    // K_CENTER is the proportional gain applied to the left-right distance error
    // during the dead-end crawl so the robot centres itself in the corridor.
    localparam signed K_CENTER = 7'sd3;

    // =========================================================================
    // FSM STATE ENCODING
    // =========================================================================
    // ---- DFS exploration states ----
    localparam S_IDLE            = 5'd0;   // waiting for BT start command
    localparam S_DFS_UPDATE      = 5'd1;   // record wall data for current cell
    localparam S_DFS_EVALUATE    = 5'd2;   // decide next move (front / left / right / backtrack)
    localparam S_DFS_POP_TURN    = 5'd3;   // orient toward parent cell before backtracking
    localparam S_MOVE_NORMAL     = 5'd4;   // forward, full-cell tick count
    localparam S_MOVE_POST_TURN  = 5'd5;   // forward, shorter count after a 90° turn
    localparam S_MOVE_POST_UTURN = 5'd15;  // forward, shortest count after a 180° U-turn
    localparam S_TURN_L          = 5'd6;   // in-place 90° left turn
    localparam S_TURN_R          = 5'd7;   // in-place 90° right turn
    localparam S_TURN_U          = 5'd10;  // in-place 180° U-turn
    localparam S_WAIT            = 5'd8;   // generic 0.2 s pause (shared by all phases)
    localparam S_CRAWL_REV       = 5'd11;  // reverse away from dead-end wall
    localparam S_CRAWL_FWD       = 5'd12;  // creep forward until mi_box detected
    localparam S_MEASURE_WAIT    = 5'd13;  // settle before triggering MPI
    localparam S_MEASURE_ACTIVE  = 5'd14;  // wait for mpi_top to signal mpi_done
    localparam S_STOP            = 5'd9;   // full halt; sends run-end message once

    // ---- A* exit navigation states ----
    localparam S_EXIT_INIT       = 5'd16;  // wait while exit_nav computes A* path
    localparam S_EXIT_EVAL       = 5'd17;  // decide next exit move (mirrors S_DFS_EVALUATE)
    localparam S_EXIT_MOVE_NORMAL= 5'd18;  // exit forward, full-cell ticks
    localparam S_EXIT_MOVE_POST  = 5'd19;  // exit forward, post-turn ticks
    localparam S_EXIT_MOVE_POST_U= 5'd20;  // exit forward, post-uturn ticks
    localparam S_EXIT_TURN_L     = 5'd21;  // exit 90° left
    localparam S_EXIT_TURN_R     = 5'd22;  // exit 90° right
    localparam S_EXIT_TURN_U     = 5'd23;  // exit 180° U-turn
    localparam S_EXIT_OVERSHOOT  = 5'd24;  // drive one extra cell past (4,8) to clear maze

    // =========================================================================
    // MOTOR COMMAND ENCODING
    // =========================================================================
    localparam CMD_STOP      = 3'd0;
    localparam CMD_FWD       = 3'd1;
    localparam CMD_LEFT      = 3'd2;
    localparam CMD_RIGHT     = 3'd3;
    localparam CMD_UTURN     = 3'd4;
    localparam CMD_CRAWL_FWD = 3'd5;
    localparam CMD_CRAWL_REV = 3'd6;

    // =========================================================================
    // FSM REGISTERS
    // =========================================================================
    reg [4:0]  state;
    reg [2:0]  cmd;
    reg [26:0] wait_counter;       // counts down in S_WAIT
    reg [4:0]  wait_return_state;  // S_WAIT jumps to this state when it expires

    // =========================================================================
    // ODOMETRY
    // =========================================================================
    wire signed [16:0] left_count_wire, right_count_wire;  // cumulative encoder ticks from odometry module
    reg  odom_clear;        // level signal: holds odometry counters at zero while high
    reg  odom_clear_pulse;  // one-cycle pulse that seeds the two-cycle clear pipeline

    wire signed [16:0] avg_ticks;          // (left + right) / 2 — average distance travelled
    reg  signed [16:0] cell_start_ticks;   // avg_ticks snapshot taken at the start of each cell

    wire [16:0] cell_current_ticks;        // ticks elapsed since cell_start_ticks

    // Three thresholds derived from cell_current_ticks for the three move states
    wire cell_crossed_normal;      // full cell (1200 ticks)
    wire cell_crossed_post_turn;   // post-turn burst (750 ticks)
    wire cell_crossed_post_uturn;  // post-uturn burst (500 ticks)

    // Mux that feeds the generic cell_crossed signal used by the odom-clear pipeline.
    // Each move state uses a different threshold; all others use cell_crossed_normal.
    wire cell_crossed;

    // =========================================================================
    // TURN CONTROL
    // =========================================================================
    // Turns are measured by the differential encoder count between the two wheels.
    // saved_turn_ref is captured once at the start of each turn so that only the
    // incremental rotation during the current turn is measured.
    reg signed [16:0] saved_turn_ref;
    reg  turn_ref_captured;  // prevents re-capturing the reference on subsequent cycles
    reg  [26:0] turn_timer;  // ensures TURN_MIN_TIME has elapsed before checking threshold

    // =========================================================================
    // ROBOT POSE
    // =========================================================================
    reg [3:0] robot_x, robot_y;  // current grid cell (4-bit each, range 0–8)
    reg [1:0] heading;           // current facing direction (DIR_NORTH/EAST/SOUTH/WEST)

    // Post-move flags: set by a turn state, cleared by the subsequent move state.
    // They tell S_DFS_EVALUATE / S_EXIT_EVAL to dispatch to the shorter burst state.
    reg post_turn_flag;
    reg post_uturn_flag;

    reg prev_btn;  // previous cycle ir_top sample, used for rising-edge detection in S_STOP

    // =========================================================================
    // SENSOR INTERFACE WIRES
    // =========================================================================
    wire [15:0] distance_l, distance_r, distance_f;  // ultrasonic distances (cm)
    wire [2:0]  wall;       // {front_wall_us, left_wall_us, right_wall_us} from sensor_interface
    wire deadend;           // asserted by sensor_interface when all three US walls are detected
    wire mi_box;            // asserted when the IR middle sensor detects the measurement box
    wire front_wall;        // combinational: front US reads below thres_f

    // =========================================================================
    // PD WALL-FOLLOWING CONTROLLER
    // =========================================================================
    // The PD controller corrects lateral position relative to the nearest wall.
    // Priority: left wall > right wall > no wall (open, correction = 0).
    wire signed [15:0] pd_input;      // sensor distance fed to PD
    wire signed [15:0] pd_ref;        // setpoint distance (70 cm with wall, 60 cm without)
    wire signed [15:0] pd_kp;         // proportional gain (30)
    wire signed [15:0] pd_kd;         // derivative gain (10)
    wire signed [6:0]  corrected_val; // PD output: signed correction in duty-cycle units
    wire signed [6:0]  pid_l;         // correction applied to left  motor (non-zero when left wall)
    wire signed [6:0]  pid_r;         // correction applied to right motor (non-zero when right wall only)
    reg  signed [6:0]  pd_clamp;      // saturation limit, tightened near turns/low speed

    // =========================================================================
    // MOTOR MIXER REGISTERS
    // =========================================================================
    reg [6:0]        final_duty_l, final_duty_r;  // PWM duty (0–100%) sent to drive module
    reg              dir_l, dir_r;                // direction bits (1=forward, 0=reverse)
    reg signed [8:0] duty_l_tmp, duty_r_tmp;      // signed intermediate before clamping
    reg [6:0]        adaptive_speed;              // base speed, adjusted by lookahead

    // =========================================================================
    // BLUETOOTH SIGNALS
    // =========================================================================
    wire start_flag;      // pulsed by bt_receiver when a valid START-*-# command arrives
    wire [3:0] mpi_target; // number of boxes to measure, decoded from the START command
    wire bt_tx_mpi;        // TX line from mpi_top; routed directly to bt_tx_pin

    // =========================================================================
    // DFS MAP STRUCTURES
    // =========================================================================
    reg [80:0] visited_cells;       // bit per cell: set on first entry
    reg [80:0] wall_north;          // bit per cell: north wall present
    reg [80:0] wall_east;           // bit per cell: east  wall present
    reg [6:0]  stack_memory [0:63]; // DFS backtrack stack (cell IDs)
    reg [5:0]  stack_ptr;           // points to the next free stack slot

    // =========================================================================
    // MPI MEASUREMENT STATE
    // =========================================================================
    reg [26:0] mpi_wait_counter;   // settle timer before arming sensor
    reg [26:0] crawl_rev_counter;  // counts the reverse-crawl duration
    reg  mpi_flag;                 // level signal: arms mpi_top when high
    wire mpi_done;                 // pulsed by mpi_top when measurement complete
    reg [3:0] boxes_measured;      // how many measurements have been taken so far
    reg [3:0] mpi_target_count;    // total measurements requested (from START command)
    reg [3:0] mpi_id_to_measure;   // MPI ID determined by current coordinates
    reg  send_end;                 // single-cycle pulse: triggers end message in mpi_top
    reg  send_end_done;            // prevents send_end from firing more than once

    // DFS backtrack helper: the parent cell ID popped from the stack
    reg [6:0] parent_id;

    // =========================================================================
    // DEAD-END CRAWL CENTERING
    // =========================================================================
    // During the forward crawl into a dead-end, left/right US readings are used
    // to keep the robot centred.  deadend_correction is a signed bias added to
    // one wheel and subtracted from the other.
    wire signed [15:0] distance_diff;
    wire signed [6:0]  deadend_correction;
    assign distance_diff      = $signed(distance_l) - $signed(distance_r);
    assign deadend_correction = (distance_diff * K_CENTER) >>> 0;

    // =========================================================================
    // EXIT NAVIGATION INTERFACE
    // =========================================================================
    reg        exit_start_pulse;  // one-cycle pulse to exit_nav: start A* computation
    reg        step_done_pulse;   // one-cycle pulse to exit_nav: robot crossed a cell
    wire       path_ready;        // exit_nav: A* complete, path_fwd[] is valid
    wire       path_exhausted;    // exit_nav: all waypoints consumed (robot at (4,8))
    wire [1:0] required_heading;  // exit_nav: heading needed to reach next waypoint

    // =========================================================================
    // DERIVED ODOMETRY SIGNALS
    // =========================================================================
    // avg_ticks is a running total.  cell_start_ticks is snapshotted at each cell
    // boundary, so cell_current_ticks always measures progress within the current cell.
    assign avg_ticks          = (left_count_wire + right_count_wire) >>> 1;
    assign cell_current_ticks = avg_ticks - cell_start_ticks;

    assign cell_crossed_normal     = (cell_current_ticks >= TICKS_PER_CELL_AVG);
    assign cell_crossed_post_turn  = (cell_current_ticks >= TICKS_AFTER_TURN_AVG);
    assign cell_crossed_post_uturn = (cell_current_ticks >= TICKS_AFTER_UTURN_AVG);

    // Select the correct crossing threshold based on the active move state.
    // The odom-clear pipeline samples this signal once per cycle; all move states
    // that are not specifically listed default to cell_crossed_normal.
    assign cell_crossed =
        (state == S_MOVE_POST_TURN  || state == S_EXIT_MOVE_POST)  ? cell_crossed_post_turn  :
        (state == S_MOVE_POST_UTURN || state == S_EXIT_MOVE_POST_U) ? cell_crossed_post_uturn :
                                                                       cell_crossed_normal;

    // =========================================================================
    // DEBUG ASSIGNMENTS
    // =========================================================================
    assign debug_x       = robot_x;
    assign debug_y       = robot_y;
    assign debug_heading = heading;

    // =========================================================================
    // PD CONTROLLER WIRING
    // =========================================================================
    // Prefer the left wall for correction; fall back to the right wall.
    // If neither wall is present, correction is zero (open corridor, drive straight).
    assign pd_ref   = wall[1] ? 16'd70 : 16'd60;
    assign pd_input = wall[1] ? distance_l : (wall[0] ? distance_r : 16'd70);
    assign pd_kp    = 16'sd30;
    assign pd_kd    = 16'sd10;
    assign pid_l    =  wall[1]              ? corrected_val : 7'sd0;
    assign pid_r    = (!wall[1] && wall[0]) ? corrected_val : 7'sd0;

    // =========================================================================
    // BLUETOOTH TX ROUTING
    // =========================================================================
    // mpi_top is the sole BT transmitter.  It handles both MPI data messages
    // and the end-of-run message triggered by send_end.
    assign bt_tx_pin = bt_tx_mpi;

    // =========================================================================
    // DFS ABSOLUTE WALL TRANSLATION
    // =========================================================================
    // sensor_interface reports walls relative to the robot's facing direction:
    //   wall[2] = front wall   wall[1] = left wall   wall[0] = right wall
    // These are converted to absolute compass directions for storage in the map.
    wire abs_wall_n = (heading==DIR_NORTH && wall[2]) || (heading==DIR_EAST  && wall[1]) || (heading==DIR_WEST  && wall[0]);
    wire abs_wall_e = (heading==DIR_EAST  && wall[2]) || (heading==DIR_SOUTH && wall[1]) || (heading==DIR_NORTH && wall[0]);
    wire abs_wall_s = (heading==DIR_SOUTH && wall[2]) || (heading==DIR_WEST  && wall[1]) || (heading==DIR_EAST  && wall[0]);
    wire abs_wall_w = (heading==DIR_WEST  && wall[2]) || (heading==DIR_NORTH && wall[1]) || (heading==DIR_SOUTH && wall[0]);

    // =========================================================================
    // DFS NEIGHBOUR COORDINATE COMPUTATION
    // =========================================================================
    // Computed combinationally each cycle; used in S_DFS_EVALUATE to look up
    // whether each adjacent cell has been visited and whether a wall blocks it.
    reg [3:0] front_x, front_y, left_x, left_y, right_x, right_y;
    always @(*) begin
        case (heading)
            DIR_NORTH: begin front_x=robot_x;   front_y=robot_y+1; left_x=robot_x-1; left_y=robot_y;   right_x=robot_x+1; right_y=robot_y;   end
            DIR_EAST:  begin front_x=robot_x+1; front_y=robot_y;   left_x=robot_x;   left_y=robot_y+1; right_x=robot_x;   right_y=robot_y-1; end
            DIR_SOUTH: begin front_x=robot_x;   front_y=robot_y-1; left_x=robot_x+1; left_y=robot_y;   right_x=robot_x-1; right_y=robot_y;   end
            DIR_WEST:  begin front_x=robot_x-1; front_y=robot_y;   left_x=robot_x;   left_y=robot_y-1; right_x=robot_x;   right_y=robot_y+1; end
        endcase
    end

    // Grid boundary checks prevent the DFS from pushing out-of-bounds cells onto the stack.
    wire valid_front = (front_x < 9 && front_y < 9);
    wire valid_left  = (left_x  < 9 && left_y  < 9);
    wire valid_right = (right_x < 9 && right_y < 9);

    // Flat cell IDs for visited/wall array indexing
    wire [6:0] id_front   = (front_y * 9) + front_x;
    wire [6:0] id_left    = (left_y  * 9) + left_x;
    wire [6:0] id_right   = (right_y * 9) + right_x;
    wire [6:0] id_current = (robot_y * 9) + robot_x;

    // The exit cell (4,8) is trapped during DFS exploration so the robot does not
    // enter it before all measurements are complete.  Once boxes_measured reaches
    // mpi_target_count the traps deactivate and the cell becomes reachable by A*.
    wire trap_front = (front_x == 4 && front_y == 8 && boxes_measured < mpi_target_count);
    wire trap_left  = (left_x  == 4 && left_y  == 8 && boxes_measured < mpi_target_count);
    wire trap_right = (right_x == 4 && right_y == 8 && boxes_measured < mpi_target_count);

    // =========================================================================
    // DFS BACKTRACK HEADING
    // =========================================================================
    // When backtracking, the robot needs to face the parent cell.
    // target_heading_from_parent computes this from the stored parent_id.
    wire [3:0] parent_x = parent_id % 9;
    wire [3:0] parent_y = parent_id / 9;
    wire [1:0] target_heading_from_parent =
        (parent_y > robot_y) ? DIR_NORTH :
        (parent_x > robot_x) ? DIR_EAST  :
        (parent_y < robot_y) ? DIR_SOUTH : DIR_WEST;

    // =========================================================================
    // MPI ID MAPPING BASED ON COORDINATES
    // =========================================================================
    // Maps specific (x,y) coordinates to predefined MPI IDs as per requirements
    always @(*) begin
        case ({robot_x, robot_y})
            {4'd0, 4'd3}: mpi_id_to_measure = 4'd1;
            {4'd2, 4'd7}: mpi_id_to_measure = 4'd2;
            {4'd1, 4'd6}: mpi_id_to_measure = 4'd3;
            {4'd0, 4'd8}: mpi_id_to_measure = 4'd4;
            {4'd1, 4'd1}: mpi_id_to_measure = 4'd5;
            {4'd3, 4'd3}: mpi_id_to_measure = 4'd6;
            {4'd8, 4'd0}: mpi_id_to_measure = 4'd7;
            {4'd7, 4'd5}: mpi_id_to_measure = 4'd8;
            {4'd5, 4'd8}: mpi_id_to_measure = 4'd9;
            default:      mpi_id_to_measure = 4'd0;
        endcase
    end

    // =========================================================================
    // ADAPTIVE SPEED AND PD CLAMP
    // =========================================================================
    // Speed is raised to HIGH_SPEED when moving straight and the front sensor
    // reports more than 300 cm of clearance (no obstacle approaching).
    // pd_clamp is tightened at lower speeds to keep corrections smooth.
    always @(*) begin
        if ((state == S_MOVE_NORMAL || state == S_EXIT_MOVE_NORMAL) && distance_f > 16'd300) begin
            adaptive_speed = HIGH_SPEED;
            pd_clamp       = 7'sd20;
        end else begin
            adaptive_speed = MED_SPEED;
            pd_clamp       = 7'sd15;
        end
    end

    // =========================================================================
    // MOTOR MIXER
    // =========================================================================
    // Converts cmd + adaptive_speed + PD corrections into per-wheel duty cycles.
    // duty_l_tmp / duty_r_tmp are signed intermediates; the results are clamped
    // before being passed to the drive module.
    // Note: duty_l and duty_r are intentionally SWAPPED at the drive instantiation
    // because the physical motor wiring is mirrored on the PCB.
    always @(*) begin
        final_duty_l = 0; final_duty_r = 0;
        dir_l = 1;        dir_r = 1;
        duty_l_tmp = 0;   duty_r_tmp = 0;

        case (cmd)
            CMD_FWD: begin
                // PD correction: add to one wheel, subtract from the other
                duty_l_tmp = $signed({1'b0, adaptive_speed}) + pid_l - pid_r;
                duty_r_tmp = $signed({1'b0, adaptive_speed}) - pid_l + pid_r;
                if      (duty_l_tmp < 20) final_duty_l = 20;
                else if (duty_l_tmp > 90) final_duty_l = 90;
                else                      final_duty_l = duty_l_tmp[6:0];
                if      (duty_r_tmp < 20) final_duty_r = 20;
                else if (duty_r_tmp > 90) final_duty_r = 90;
                else                      final_duty_r = duty_r_tmp[6:0];
            end

            CMD_CRAWL_FWD: begin
                // Centering correction during dead-end approach (keep robot equidistant from both walls)
                duty_l_tmp = $signed({1'b0, CRAWL_SPEED}) - deadend_correction;
                duty_r_tmp = $signed({1'b0, CRAWL_SPEED}) + deadend_correction;
                if      (duty_l_tmp < 0)  final_duty_l = 0;
                else if (duty_l_tmp > 40) final_duty_l = 40;
                else                      final_duty_l = duty_l_tmp[6:0];
                if      (duty_r_tmp < 0)  final_duty_r = 0;
                else if (duty_r_tmp > 40) final_duty_r = 40;
                else                      final_duty_r = duty_r_tmp[6:0];
            end

            CMD_CRAWL_REV: begin
                // Centering correction is inverted on reverse (sign flip compensates direction)
                duty_l_tmp = $signed({1'b0, CRAWL_SPEED}) + deadend_correction;
                duty_r_tmp = $signed({1'b0, CRAWL_SPEED}) - deadend_correction;
                if      (duty_l_tmp < 0)  final_duty_l = 0;
                else if (duty_l_tmp > 40) final_duty_l = 40;
                else                      final_duty_l = duty_l_tmp[6:0];
                if      (duty_r_tmp < 0)  final_duty_r = 0;
                else if (duty_r_tmp > 40) final_duty_r = 40;
                else                      final_duty_r = duty_r_tmp[6:0];
                dir_l = 0; dir_r = 0;  // reverse both motors
            end

            CMD_LEFT: begin
                // Right wheel drives forward, left wheel stops → spins left on the spot
                final_duty_l = TURN_SPEED_L; dir_l = 1;
                final_duty_r = TURN_SPEED_H; dir_r = 0;
            end

            CMD_RIGHT: begin
                // Left wheel drives forward, right wheel stops → spins right on the spot
                final_duty_l = TURN_SPEED_H; dir_l = 0;
                final_duty_r = TURN_SPEED_L; dir_r = 1;
            end

            CMD_UTURN: begin
                // Left wheel forward, right wheel backward → 180° spin
                // +5 bias on left wheel compensates for slight mechanical asymmetry
                final_duty_l = UTURN_SPEED + 7'd5; dir_l = 1;
                final_duty_r = UTURN_SPEED;         dir_r = 0;
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
    // MAIN FSM
    // =========================================================================
    integer i;

    always @(posedge clk_50M or negedge reset_n) begin
        // Mirror key internals to debug outputs every cycle
        speed_l     <= final_duty_l;
        speed_r     <= final_duty_r;
        state_check <= state;
        pd_check    <= corrected_val;
        debug_us    <= distance_f;

        if (!reset_n) begin
            // ------------------------------------------------------------------
            // RESET — initialise all registers to safe defaults
            // ------------------------------------------------------------------
            state             <= S_IDLE;
            cmd               <= CMD_STOP;
            heading           <= DIR_NORTH;
            post_turn_flag    <= 1'b0;
            post_uturn_flag   <= 1'b0;
            robot_x           <= 4'd4;   // robot starts at cell (4,0), centre of south edge
            robot_y           <= 4'd0;
            uturn_count       <= 4'd0;
            prev_btn          <= 1'b0;

            visited_cells <= 81'b0;
            wall_north    <= 81'b0;
            wall_east     <= 81'b0;
            stack_ptr     <= 6'd0;
            for (i = 0; i < 64; i = i + 1) stack_memory[i] <= 7'd0;

            cell_start_ticks  <= 17'sd0;
            saved_turn_ref    <= 17'sd0;
            turn_ref_captured <= 1'b0;
            turn_timer        <= 27'd0;

            wait_counter      <= 27'd0;
            wait_return_state <= S_IDLE;

            odom_clear       <= 1'b1;  // hold odometry in reset
            odom_clear_pulse <= 1'b0;

            mpi_wait_counter  <= 27'd0;
            crawl_rev_counter <= 27'd0;
            mpi_flag          <= 1'b0;
            boxes_measured    <= 4'd0;
            mpi_id_to_measure <= 4'd0;
            mpi_target_count  <= 4'd0;
            send_end          <= 1'b0;
            send_end_done     <= 1'b0;
            parent_id         <= 7'd0;

            exit_start_pulse <= 1'b0;
            step_done_pulse  <= 1'b0;
        end
        else begin
            // ------------------------------------------------------------------
            // DEFAULT PULSE RESETS
            // One-cycle pulses must be cleared at the top of every non-reset cycle
            // so they never remain high for more than one clock edge.
            // ------------------------------------------------------------------
            send_end         <= 1'b0;
            exit_start_pulse <= 1'b0;
            step_done_pulse  <= 1'b0;

            prev_btn <= ir_top;  // sample button for rising-edge detection in S_STOP

            // ------------------------------------------------------------------
            // ODOMETRY CLEAR PIPELINE
            // When cell_crossed fires, cell_start_ticks is snapshotted and a
            // one-cycle clear pulse is generated.  odom_clear follows one cycle
            // later so the odometry module sees a clean level signal (not a glitch).
            // ------------------------------------------------------------------
            odom_clear_pulse <= 1'b0;
            if (cell_crossed) begin
                cell_start_ticks <= avg_ticks;
                odom_clear_pulse <= 1'b1;
            end
            odom_clear <= odom_clear_pulse;

            case (state)

                // ==============================================================
                // S_IDLE
                // The robot waits for a START-*-# Bluetooth command.  A 2-second
                // guard (idle_counter) ensures all submodules have stabilised
                // before movement begins.
                // ==============================================================
                S_IDLE: begin
                    cmd             <= CMD_STOP;
                    post_turn_flag  <= 1'b0;
                    post_uturn_flag <= 1'b0;
                    odom_clear      <= 1'b1;

                    if (start_flag) begin
                        mpi_target_count  <= mpi_target;  // latch requested measurement count
                        boxes_measured    <= 4'd0;
                        send_end_done     <= 1'b0;
                        cell_start_ticks  <= avg_ticks;
                        odom_clear        <= 1'b0;
                        state             <= S_DFS_UPDATE;
                    end
                end

                // ==============================================================
                // S_DFS_UPDATE
                // On every cell arrival, record which walls surround the current
                // cell in the absolute map arrays.  Relative sensor readings are
                // translated to compass directions using the abs_wall_* wires.
                // South/west walls are stored as the north/east wall of the
                // neighbouring cell to keep a single canonical representation.
                // ==============================================================
                S_DFS_UPDATE: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b0;

                    visited_cells[id_current] <= 1'b1;
                    if (abs_wall_n) wall_north[id_current]     <= 1'b1;
                    if (abs_wall_e) wall_east[id_current]      <= 1'b1;
                    if (abs_wall_s && robot_y > 0) wall_north[id_current - 9] <= 1'b1;
                    if (abs_wall_w && robot_x > 0) wall_east[id_current  - 1] <= 1'b1;

                    state <= S_DFS_EVALUATE;
                end

                // ==============================================================
                // S_DFS_EVALUATE
                // Core DFS decision logic.  Priority order:
                //   1. Consume a pending post-turn/post-uturn flag (forward burst)
                //   2. Unvisited front cell   → push stack, move forward
                //   3. Unvisited left  cell   → push stack, wait, turn left
                //   4. Unvisited right cell   → push stack, wait, turn right
                //   5. Dead-end with mi_box   → crawl back then forward for MPI
                //   6. All visited / blocked  → pop stack, backtrack
                //   7. Stack empty            → exploration complete, halt
                // The exit cell (4,8) is blocked by trap_* while measurements remain.
                // ==============================================================
                S_DFS_EVALUATE: begin
                    if (post_uturn_flag) begin
                        cell_start_ticks <= avg_ticks;
                        post_uturn_flag  <= 1'b0;
                        state <= S_MOVE_POST_UTURN;
                    end
                    else if (post_turn_flag) begin
                        cell_start_ticks <= avg_ticks;
                        post_turn_flag   <= 1'b0;
                        state <= S_MOVE_POST_TURN;
                    end
                    else begin
                        if (!wall[2] && valid_front && !visited_cells[id_front] && !trap_front) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr               <= stack_ptr + 1;
                            cell_start_ticks        <= avg_ticks;
                            state <= S_MOVE_NORMAL;
                        end
                        else if (!wall[1] && valid_left && !visited_cells[id_left] && !trap_left) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr               <= stack_ptr + 1;
                            wait_return_state <= S_TURN_L;
                            state             <= S_WAIT;
                            wait_counter      <= 27'd0;
                        end
                        else if (!wall[0] && valid_right && !visited_cells[id_right] && !trap_right) begin
                            stack_memory[stack_ptr] <= id_current;
                            stack_ptr               <= stack_ptr + 1;
                            wait_return_state <= S_TURN_R;
                            state             <= S_WAIT;
                            wait_counter      <= 27'd0;
                        end
                        else begin
                            if (wall[0] && wall[1] && wall[2]) begin
                                // True dead-end (three walls): attempt MPI if eligible,
                                // otherwise backtrack normally.
                                if (deadend && boxes_measured < mpi_target_count) begin
                                    parent_id         <= stack_memory[stack_ptr - 1];
                                    crawl_rev_counter <= 27'd0;
                                    state             <= S_CRAWL_REV;
                                end
                                else begin
                                    if (stack_ptr > 0) begin
                                        parent_id         <= stack_memory[stack_ptr - 1];
                                        wait_return_state <= S_DFS_POP_TURN;
                                        wait_counter      <= 27'd0;
                                        state             <= S_WAIT;
                                    end else state <= S_STOP;
                                end
                            end
                            else begin
                                // All reachable neighbours visited: backtrack
                                if (stack_ptr > 0) begin
                                    parent_id         <= stack_memory[stack_ptr - 1];
                                    wait_return_state <= S_DFS_POP_TURN;
                                    wait_counter      <= 27'd0;
                                    state             <= S_WAIT;
                                end else state <= S_STOP;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_DFS_POP_TURN
                // Decrement the stack and compute which turn is needed to face
                // the parent cell.  Heading arithmetic is mod-4:
                //   +1 = right turn,  +3 = left turn (= -1 mod 4),  +2 = U-turn.
                // ==============================================================
                S_DFS_POP_TURN: begin
                    stack_ptr <= stack_ptr - 1;

                    if      (target_heading_from_parent == heading)        begin cell_start_ticks <= avg_ticks; state <= S_MOVE_NORMAL; end
                    else if (target_heading_from_parent == (heading + 2'd1)) state <= S_TURN_R;
                    else if (target_heading_from_parent == (heading + 2'd3)) state <= S_TURN_L;
                    else                                                      state <= S_TURN_U;
                end

                // ==============================================================
                // S_MOVE_NORMAL
                // Drive forward until either:
                //   a) cell_crossed_normal fires (encoder count >= 1200 ticks), or
                //   b) the front ultrasonic sensor detects a wall sooner.
                // In both cases the coordinate is updated and the FSM moves to
                // S_DFS_UPDATE to record walls at the new position.
                // ==============================================================
                S_MOVE_NORMAL: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_DFS_UPDATE;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
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

                // ==============================================================
                // S_MOVE_POST_TURN
                // Short forward burst (750 ticks) after a 90° turn.  Entered via
                // post_turn_flag so the robot repositions itself in the new cell
                // before the next S_DFS_UPDATE wall scan.
                // ==============================================================
                S_MOVE_POST_TURN: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_DFS_UPDATE;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
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

                // ==============================================================
                // S_MOVE_POST_UTURN
                // Shortest forward burst (500 ticks) after a 180° U-turn.
                // Identical structure to S_MOVE_POST_TURN with a smaller threshold.
                // ==============================================================
                S_MOVE_POST_UTURN: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_DFS_UPDATE;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
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

                // ==============================================================
                // S_TURN_L  (DFS phase)
                // The turn is measured by the differential encoder count:
                //   delta = (left_count - right_count) - saved_turn_ref
                // A minimum timer (TURN_MIN_TIME) prevents premature exit due to
                // encoder noise at the start of the turn.  A maximum timer
                // (TURN_MAX_TIME) forces completion if the threshold is never met.
                // ==============================================================
                S_TURN_L: begin
                    odom_clear <= 1'b0;
                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_LEFT;
                        turn_timer        <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_LEFT;
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_L_90)
                                || turn_timer >= TURN_MAX_TIME) begin
                                cmd               <= CMD_STOP;
                                post_turn_flag    <= 1'b1;
                                heading           <= heading + 2'd3;  // heading - 1 (mod 4) = turn left
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_TURN_R  (DFS phase)  — mirror of S_TURN_L using right differential
                // ==============================================================
                S_TURN_R: begin
                    odom_clear <= 1'b0;
                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= right_count_wire - left_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_RIGHT;
                        turn_timer        <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_RIGHT;
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(right_count_wire - left_count_wire) - saved_turn_ref) >= $signed(TICKS_R_90)
                                || turn_timer >= TURN_MAX_TIME) begin
                                cmd               <= CMD_STOP;
                                post_turn_flag    <= 1'b1;
                                heading           <= heading + 2'd1;  // heading + 1 (mod 4) = turn right
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_TURN_U  (DFS phase)
                // Same differential measurement as S_TURN_L but the threshold is
                // TICKS_U_180 (≈ double the 90° value).
                // ==============================================================
                S_TURN_U: begin
                    odom_clear <= 1'b0;
                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_UTURN;
                        turn_timer        <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_UTURN;
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_U_180)
                                || turn_timer >= TURN_MAX_TIME) begin
                                cmd               <= CMD_STOP;
                                post_uturn_flag   <= 1'b1;
                                if (uturn_count < 4'd15) uturn_count <= uturn_count + 4'd1;
                                heading           <= heading + 2'd2;  // heading + 2 (mod 4) = reverse
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_DFS_EVALUATE;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_CRAWL_REV
                // Backs away from the dead-end wall for CRAWL_REV_DELAY cycles
                // to create clearance before the forward measurement approach.
                // ==============================================================
                S_CRAWL_REV: begin
                    cmd        <= CMD_CRAWL_REV;
                    odom_clear <= 1'b0;
                    if (crawl_rev_counter >= CRAWL_REV_DELAY) begin
                        cmd               <= CMD_STOP;
                        crawl_rev_counter <= 27'd0;
                        state             <= S_CRAWL_FWD;
                    end else begin
                        crawl_rev_counter <= crawl_rev_counter + 27'd1;
                    end
                end

                // ==============================================================
                // S_CRAWL_FWD
                // Creeps forward at low speed until the IR middle sensor (mi_box)
                // detects the measurement box.
                // ==============================================================
                S_CRAWL_FWD: begin
                    cmd        <= CMD_CRAWL_FWD;
                    odom_clear <= 1'b0;
                    if (mi_box) begin
                        cmd              <= CMD_STOP;
                        mpi_wait_counter <= 27'd0;
                        state            <= S_MEASURE_WAIT;
                    end
                end

                // ==============================================================
                // S_MEASURE_WAIT
                // Waits MPI_WAIT_DELAY cycles for vibrations to damp before
                // arming the sensor to ensure clean readings.
                // ==============================================================
                S_MEASURE_WAIT: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b0;
                    if (mpi_wait_counter >= MPI_WAIT_DELAY) begin
                        mpi_flag         <= 1'b1;
                        mpi_wait_counter <= 27'd0;
                        state            <= S_MEASURE_ACTIVE;
                    end else begin
                        mpi_wait_counter <= mpi_wait_counter + 27'd1;
                    end
                end

                // ==============================================================
                // S_MEASURE_ACTIVE
                // Holds mpi_flag high until mpi_top signals mpi_done.
                // On completion, if all measurements are done the FSM hands off
                // to exit_nav.  Otherwise it continues DFS backtracking.
                // ==============================================================
                S_MEASURE_ACTIVE: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b0;
                    if (mpi_done) begin
                        mpi_flag          <= 1'b0;
                        boxes_measured    <= boxes_measured + 4'd1;

                        if (boxes_measured + 4'd1 >= mpi_target_count) begin
                            // All measurements complete — trigger A* path computation
                            exit_start_pulse <= 1'b1;
                            state            <= S_EXIT_INIT;
                        end
                        else begin
                            // More to go — continue DFS from the current stack position
                            if (stack_ptr > 0) begin
                                parent_id         <= stack_memory[stack_ptr - 1];
                                wait_return_state <= S_DFS_POP_TURN;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end else state <= S_STOP;
                        end
                    end
                end

                // ==============================================================
                // S_WAIT
                // Generic 0.2-second pause inserted before and after every turn,
                // and after front_wall stops.  Ensures motors have fully stopped
                // and sensor readings are stable before the next state is entered.
                // ==============================================================
                S_WAIT: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b0;
                    if (wait_counter >= WAIT_DELAY) begin
                        wait_counter <= 27'd0;
                        state        <= wait_return_state;
                    end else begin
                        wait_counter <= wait_counter + 27'd1;
                    end
                end

                // ==============================================================
                // S_STOP
                // Final halt state.  send_end fires once (guarded by send_end_done)
                // to transmit the end-of-run message through mpi_top.
                // The ir_top button (rising edge) restarts the robot from S_IDLE.
                // ==============================================================
                S_STOP: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b1;
                    if (ir_top && !prev_btn) state <= S_IDLE;
                end

                // ==============================================================
                // S_EXIT_INIT
                // Waits in a stopped state while exit_nav runs A* internally.
                // path_ready goes high once the path_fwd[] array is populated.
                // ==============================================================
                S_EXIT_INIT: begin
                    cmd        <= CMD_STOP;
                    odom_clear <= 1'b0;
                    if (path_ready) begin
                        cell_start_ticks <= avg_ticks;
                        state            <= S_EXIT_EVAL;
                    end
                end

                // ==============================================================
                // S_EXIT_EVAL
                // Mirrors S_DFS_EVALUATE for the exit phase.  Reads required_heading
                // from exit_nav and decides the next motion primitive.
                // Priority: exhausted → overshoot, post flags → burst forward,
                // straight → move normal, 90°/180° turns as needed.
                // ==============================================================
                S_EXIT_EVAL: begin
                    cmd <= CMD_STOP;

                    if (path_exhausted) begin
                        // Robot has reached cell (4,8) — drive one more cell to clear maze
                        cell_start_ticks <= avg_ticks;
                        state            <= S_EXIT_OVERSHOOT;
                    end
                    else if (post_uturn_flag) begin
                        post_uturn_flag  <= 1'b0;
                        cell_start_ticks <= avg_ticks;
                        state            <= S_EXIT_MOVE_POST_U;
                    end
                    else if (post_turn_flag) begin
                        post_turn_flag   <= 1'b0;
                        cell_start_ticks <= avg_ticks;
                        state            <= S_EXIT_MOVE_POST;
                    end
                    else if (required_heading == heading) begin
                        cell_start_ticks <= avg_ticks;
                        state            <= S_EXIT_MOVE_NORMAL;
                    end
                    else if (required_heading == (heading + 2'd1)) begin
                        wait_return_state <= S_EXIT_TURN_R;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
                    end
                    else if (required_heading == (heading + 2'd3)) begin
                        wait_return_state <= S_EXIT_TURN_L;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
                    end
                    else begin
                        // required_heading == heading + 2: 180° turn needed
                        wait_return_state <= S_EXIT_TURN_U;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
                    end
                end

                // ==============================================================
                // S_EXIT_MOVE_NORMAL
                // Forward movement during exit phase; identical tick threshold to
                // S_MOVE_NORMAL.  step_done_pulse notifies exit_nav to advance
                // path_idx on every successful cell crossing.
                // ==============================================================
                S_EXIT_MOVE_NORMAL: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        step_done_pulse   <= 1'b1;
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_EXIT_EVAL;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
                    end
                    else if (cell_crossed_normal) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        step_done_pulse <= 1'b1;
                        state           <= S_EXIT_EVAL;
                    end
                end

                // ==============================================================
                // S_EXIT_MOVE_POST
                // Post-turn burst for the exit phase (750 ticks).
                // ==============================================================
                S_EXIT_MOVE_POST: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        step_done_pulse   <= 1'b1;
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_EXIT_EVAL;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
                    end
                    else if (cell_crossed_post_turn) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        step_done_pulse <= 1'b1;
                        state           <= S_EXIT_EVAL;
                    end
                end

                // ==============================================================
                // S_EXIT_MOVE_POST_U
                // Post-uturn burst for the exit phase (500 ticks).
                // ==============================================================
                S_EXIT_MOVE_POST_U: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;

                    if (front_wall) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        step_done_pulse   <= 1'b1;
                        cmd               <= CMD_STOP;
                        wait_return_state <= S_EXIT_EVAL;
                        wait_counter      <= 27'd0;
                        state             <= S_WAIT;
                    end
                    else if (cell_crossed_post_uturn) begin
                        cell_start_ticks <= avg_ticks;
                        case (heading)
                            DIR_NORTH: if (robot_y < 4'd8) robot_y <= robot_y + 4'd1;
                            DIR_EAST:  if (robot_x < 4'd8) robot_x <= robot_x + 4'd1;
                            DIR_SOUTH: if (robot_y > 4'd0) robot_y <= robot_y - 4'd1;
                            DIR_WEST:  if (robot_x > 4'd0) robot_x <= robot_x - 4'd1;
                        endcase
                        step_done_pulse <= 1'b1;
                        state           <= S_EXIT_EVAL;
                    end
                end

                // ==============================================================
                // S_EXIT_TURN_L  — exit phase 90° left, identical mechanics to S_TURN_L
                // ==============================================================
                S_EXIT_TURN_L: begin
                    odom_clear <= 1'b0;
                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_LEFT;
                        turn_timer        <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_LEFT;
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_L_90)
                                || turn_timer >= TURN_MAX_TIME) begin
                                cmd               <= CMD_STOP;
                                post_turn_flag    <= 1'b1;
                                heading           <= heading + 2'd3;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_EXIT_EVAL;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_EXIT_TURN_R  — exit phase 90° right, identical mechanics to S_TURN_R
                // ==============================================================
                S_EXIT_TURN_R: begin
                    odom_clear <= 1'b0;
                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= right_count_wire - left_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_RIGHT;
                        turn_timer        <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_RIGHT;
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(right_count_wire - left_count_wire) - saved_turn_ref) >= $signed(TICKS_R_90)
                                || turn_timer >= TURN_MAX_TIME) begin
                                cmd               <= CMD_STOP;
                                post_turn_flag    <= 1'b1;
                                heading           <= heading + 2'd1;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_EXIT_EVAL;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_EXIT_TURN_U  — exit phase 180° U-turn, identical mechanics to S_TURN_U
                // ==============================================================
                S_EXIT_TURN_U: begin
                    odom_clear <= 1'b0;
                    if (!turn_ref_captured) begin
                        saved_turn_ref    <= left_count_wire - right_count_wire;
                        turn_ref_captured <= 1'b1;
                        cmd               <= CMD_UTURN;
                        turn_timer        <= 27'd0;
                    end else begin
                        turn_timer <= turn_timer + 27'd1;
                        cmd        <= CMD_UTURN;
                        if (turn_timer >= TURN_MIN_TIME) begin
                            if (($signed(left_count_wire - right_count_wire) - saved_turn_ref) >= $signed(TICKS_U_180)
                                || turn_timer >= TURN_MAX_TIME) begin
                                cmd               <= CMD_STOP;
                                post_uturn_flag   <= 1'b1;
                                heading           <= heading + 2'd2;
                                turn_ref_captured <= 1'b0;
                                wait_return_state <= S_EXIT_EVAL;
                                wait_counter      <= 27'd0;
                                state             <= S_WAIT;
                            end
                        end
                    end
                end

                // ==============================================================
                // S_EXIT_OVERSHOOT
                // Drives one full cell (1200 ticks) past cell (4,8) to physically
                // clear the maze exit structure.  No coordinate update is performed
                // as the robot is now outside the mapped grid.
                // On completion the FSM enters S_STOP.
                // ==============================================================
                S_EXIT_OVERSHOOT: begin
                    cmd        <= CMD_FWD;
                    odom_clear <= 1'b0;
                    if (cell_crossed_normal) begin
                        cmd   <= CMD_STOP;
                        state <= S_STOP;
                    end
                end

                default: state <= S_IDLE;

            endcase

            // ==================================================================
            // RUN-END MESSAGE
            // send_end is pulsed once the first time S_STOP is entered.
            // send_end_done prevents it from firing again on subsequent cycles
            // or after a restart.
            // ==================================================================
            if (state == S_STOP && !send_end_done) begin
                send_end      <= 1'b1;
                send_end_done <= 1'b1;
            end

        end
    end

    // =========================================================================
    // WALL STATUS DEBUG REGISTER
    // =========================================================================
    always @(posedge clk_50M) begin
        wall_status <= wall;
    end

    // =========================================================================
    // MODULE INSTANTIATIONS
    // =========================================================================

    // BT receiver: parses "START-*-#" and outputs start_flag pulse + mpi_count
    bt_receiver u_bt_rx (
        .clk_50      (clk_50M),
        .reset       (~reset_n),
        .rx          (bt_rx_pin),
        .start_signal(start_flag),
        .mpi_count   (mpi_target)
    );

    // MPI top: drives servo, DHT, ADC; transmits measurement and end messages over BT
    mpi_top u_mpi_top (
        .clk          (clk_50M),
        .reset_n      (reset_n),
        .mpi_flag_pin (mpi_flag),
        .mpi_id       (mpi_id_to_measure),  // Now using coordinate-based MPI ID
        .dht_data_pin (dht_data_pin),
        .servo_pwm_pin(servo_pwm_pin),
        .adc_sdat     (adc_sdat),
        .adc_cs_n     (adc_cs_n),
        .adc_sclk     (adc_sclk),
        .adc_saddr    (adc_saddr),
        .bt_tx_pin    (bt_tx_mpi),
        .send_end     (send_end),
        .mpi_done     (mpi_done)
    );

    // PD controller: wall-following lateral correction
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

    // Motor driver: converts duty/direction to IN1-IN4 + ENA/ENB PWM
    // duty_l and duty_r are swapped here to match the physical PCB wiring
    drive u_drive (
        .clk_50M(clk_50M),
        .reset_n(reset_n),
        .duty_l (final_duty_r),
        .duty_r (final_duty_l),
        .dir_l  (dir_l),
        .dir_r  (dir_r),
        .IN1(IN1), .IN2(IN2), .IN3(IN3), .IN4(IN4),
        .ENA(ENA), .ENB(ENB)
    );

    // Odometry: integrates encoder pulses into signed cumulative tick counts
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

    // Sensor interface: processes US echo signals and IR inputs into wall flags and distances
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

    // Exit navigation: runs A* on the DFS-explored wall map and streams
    // required_heading to the master FSM one waypoint at a time
    exit_nav u_exit_nav (
        .clk_50M         (clk_50M),
        .reset_n         (reset_n),
        .exit_start      (exit_start_pulse),
        .start_x         (robot_x),
        .start_y         (robot_y),
        .wall_north      (wall_north),
        .wall_east       (wall_east),
        .step_done       (step_done_pulse),
        .path_ready      (path_ready),
        .path_exhausted  (path_exhausted),
        .required_heading(required_heading)
    );

endmodule