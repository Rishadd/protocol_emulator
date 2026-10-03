/*
# Team ID: 4093
# Theme: MazeSolver Bot
# Author List: Aayush Srinivasan, Sirigiri Tarun, Tejhuram Ravichandran, R Rishadd
# Filename: exit_nav.v
# File Description: A* path planner for maze exit navigation using wall data.
# Global variables: None
*/

// =============================================================================
//
// On receiving the exit_start pulse, this module:
//   1. Latches the robot's current grid position (start_x, start_y) and a
//      snapshot of the fully-explored wall map (wall_north, wall_east).
//   2. Runs A* from the start cell to the fixed exit cell (4,8), computing
//      the optimal path through the explored maze.
//   3. Stores the path as an ordered cell-ID array (path_fwd[]) and asserts
//      path_ready.
//
// During navigation the master FSM (robot_top_final) pulses step_done each
// time the robot crosses a cell.  exit_nav advances path_idx in response and
// recomputes required_heading to point at the next waypoint.  When path_idx
// reaches path_len, path_exhausted is asserted and the robot has arrived at (4,8).
//
// This module is entirely heading-agnostic: it only outputs required_heading
// (derived from consecutive cell positions in path_fwd[]).  The master FSM
// compares this against its own heading register to decide left/right/U-turn.
//
// Grid convention: cell id = (y * 9) + x.  Origin (0,0) is bottom-left.
//   wall_north[id] = wall on the NORTH face of cell id
//   wall_east[id]  = wall on the EAST  face of cell id
//
// =============================================================================

module exit_nav (
    input             clk_50M,
    input             reset_n,

    // Handshake from master FSM
    input             exit_start,       // single-cycle pulse: begin A*
    input  [3:0]      start_x,
    input  [3:0]      start_y,

    // Wall data snapshot from DFS (read at exit_start, stable thereafter)
    input  [80:0]     wall_north,       // wall_north[id]: wall on north face of cell id
    input  [80:0]     wall_east,        // wall_east[id]:  wall on east  face of cell id

    // Step acknowledgement from master FSM
    input             step_done,        // single-cycle pulse: one cell crossed

    // Outputs to master FSM
    output reg        path_ready,       // high once A* path is computed
    output reg        path_exhausted,   // high when path_idx >= path_len
    output reg [1:0]  required_heading  // heading needed to reach next waypoint
);

    // =========================================================================
    // PARAMETERS
    // =========================================================================
    localparam DIR_NORTH = 2'b00;
    localparam DIR_EAST  = 2'b01;
    localparam DIR_SOUTH = 2'b10;
    localparam DIR_WEST  = 2'b11;

    // Fixed exit target
    localparam [3:0] EXIT_X  = 4'd4;
    localparam [3:0] EXIT_Y  = 4'd8;
    localparam [6:0] EXIT_ID = 7'd76;   // 8*9 + 4

    // A* internal states
    localparam AS_IDLE      = 3'd0;
    localparam AS_INIT      = 3'd1;
    localparam AS_FIND_MIN  = 3'd2;
    localparam AS_EXPAND    = 3'd3;
    localparam AS_RETRACE   = 3'd4;
    localparam AS_REVERSE   = 3'd5;
    localparam AS_READY     = 3'd6;

    // =========================================================================
    // INTERNAL SIGNALS
    // =========================================================================
    reg [2:0]  astar_state;

    // Start cell (latched at exit_start)
    reg [6:0]  start_id;

    // A* data structures
    reg [7:0]  g_score   [0:80];
    reg [6:0]  came_from [0:80];
    reg [80:0] open_set;
    reg [80:0] closed_set;

    reg [6:0]  astar_current;
    reg [6:0]  astar_scan_idx;
    reg [6:0]  astar_min_id;
    reg [8:0]  astar_min_f;     // 9 bits: g(max 80) + h(max 16) fits in 8 but use 9 for safety

    // Path storage (max 81 cells for 9x9 grid)
    reg [6:0]  path_cells [0:80];   // retrace buffer (EXIT→START order)
    reg [6:0]  path_fwd   [0:80];   // forward path   (START→EXIT order)
    reg [6:0]  path_len;
    reg [6:0]  path_idx;            // next waypoint index (0 = start cell, movement begins at 1)
    reg [6:0]  retrace_idx;

    // Neighbour scratch
    reg [6:0]  nb_id    [0:3];
    reg        nb_valid [0:3];
    reg [8:0]  nb_g     [0:3];
    integer    ni;

    // Wall snapshot registers (latched at exit_start)
    reg [80:0] wn_snap;
    reg [80:0] we_snap;

    integer i;

    // =========================================================================
    // WALL QUERY FUNCTIONS (use latched snapshot)
    // =========================================================================
    function can_go_north;
        input [6:0] id;
        begin
            can_go_north = (id / 7'd9 < 7'd8) && !wn_snap[id];
        end
    endfunction

    function can_go_south;
        input [6:0] id;
        begin
            can_go_south = (id / 7'd9 > 7'd0) && !wn_snap[id - 7'd9];
        end
    endfunction

    function can_go_east;
        input [6:0] id;
        begin
            can_go_east = (id % 7'd9 < 7'd8) && !we_snap[id];
        end
    endfunction

    function can_go_west;
        input [6:0] id;
        begin
            can_go_west = (id % 7'd9 > 7'd0) && !we_snap[id - 7'd1];
        end
    endfunction

    // Manhattan distance heuristic to EXIT
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
    // REQUIRED HEADING COMPUTATION (combinational, from path_fwd)
    // =========================================================================
    // Runs continuously; master FSM reads this in S_EXIT_EVAL
    always @(*) begin
        if (!path_ready || path_idx >= path_len) begin
            required_heading = DIR_NORTH; // default, irrelevant when path_exhausted
        end else begin
            // Current cell: path_fwd[path_idx - 1] (already visited)
            // Next    cell: path_fwd[path_idx]      (need to go here)
            // heading is determined purely from coordinate delta
            if      (path_fwd[path_idx] / 7'd9 > path_fwd[path_idx - 7'd1] / 7'd9)
                required_heading = DIR_NORTH;
            else if (path_fwd[path_idx] % 7'd9 > path_fwd[path_idx - 7'd1] % 7'd9)
                required_heading = DIR_EAST;
            else if (path_fwd[path_idx] / 7'd9 < path_fwd[path_idx - 7'd1] / 7'd9)
                required_heading = DIR_SOUTH;
            else
                required_heading = DIR_WEST;
        end
    end

    // =========================================================================
    // PATH EXHAUSTED FLAG
    // =========================================================================
    always @(*) begin
        path_exhausted = path_ready && (path_idx >= path_len);
    end

    // =========================================================================
    // MAIN A* FSM
    // =========================================================================
    /*
    Purpose:
    ---
    Implements A* algorithm to find shortest path from start to exit.
    Uses Manhattan heuristic and wall data. After computation, stores forward
    path and updates required_heading as master FSM advances.
    */
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) begin
            astar_state    <= AS_IDLE;
            path_ready     <= 1'b0;
            path_len       <= 7'd0;
            path_idx       <= 7'd0;
            retrace_idx    <= 7'd0;
            astar_current  <= 7'd0;
            astar_scan_idx <= 7'd0;
            astar_min_id   <= 7'd0;
            astar_min_f    <= 9'h1FF;
            open_set       <= 81'b0;
            closed_set     <= 81'b0;
            start_id       <= 7'd0;
            wn_snap        <= 81'b0;
            we_snap        <= 81'b0;

            for (i = 0; i < 81; i = i + 1) begin
                g_score[i]    <= 8'hFF;
                came_from[i]  <= 7'h7F;
                path_cells[i] <= 7'd0;
                path_fwd[i]   <= 7'd0;
            end
        end
        else begin

            // ------------------------------------------------------------------
            // step_done: advance path index when master FSM crosses a cell
            // ------------------------------------------------------------------
            if (step_done && path_ready && path_idx < path_len) begin
                path_idx <= path_idx + 7'd1;
            end

            // ------------------------------------------------------------------
            // A* STATE MACHINE
            // ------------------------------------------------------------------
            case (astar_state)

                // --------------------------------------------------------------
                AS_IDLE: begin
                    if (exit_start) begin
                        // Latch start position and wall snapshot
                        start_id <= (start_y * 4'd9) + start_x;
                        wn_snap  <= wall_north;
                        we_snap  <= wall_east;
                        astar_state <= AS_INIT;
                    end
                end

                // --------------------------------------------------------------
                AS_INIT: begin
                    // Reset all A* structures
                    for (i = 0; i < 81; i = i + 1) begin
                        g_score[i]   <= 8'hFF;
                        came_from[i] <= 7'h7F;
                    end
                    g_score[start_id]  <= 8'd0;
                    open_set           <= 81'b0;
                    open_set[start_id] <= 1'b1;
                    closed_set         <= 81'b0;
                    astar_scan_idx     <= 7'd0;
                    astar_min_f        <= 9'h1FF;
                    astar_min_id       <= start_id;
                    path_ready         <= 1'b0;
                    path_len           <= 7'd0;
                    path_idx           <= 7'd0;
                    retrace_idx        <= 7'd0;
                    astar_state        <= AS_FIND_MIN;
                end

                // --------------------------------------------------------------
                // Scan open_set for node with lowest f = g + h
                // One node per cycle scan
                // --------------------------------------------------------------
                AS_FIND_MIN: begin
                    if (open_set == 81'b0) begin
                        // No path found — stop (shouldn't happen with complete DFS map)
                        astar_state <= AS_IDLE;
                    end
                    else if (astar_scan_idx < 7'd81) begin
                        if (open_set[astar_scan_idx]) begin
                            if (({1'b0, g_score[astar_scan_idx]} + {2'b0, heuristic(astar_scan_idx)}) < astar_min_f) begin
                                astar_min_f  <= {1'b0, g_score[astar_scan_idx]} + {2'b0, heuristic(astar_scan_idx)};
                                astar_min_id <= astar_scan_idx;
                            end
                        end
                        astar_scan_idx <= astar_scan_idx + 7'd1;
                    end
                    else begin
                        // Scan complete
                        astar_current  <= astar_min_id;
                        astar_scan_idx <= 7'd0;
                        astar_min_f    <= 9'h1FF;
                        astar_min_id   <= 7'd0;

                        if (astar_min_id == EXIT_ID) begin
                            // Found exit — start retrace
                            retrace_idx <= 7'd0;
                            astar_state <= AS_RETRACE;
                        end
                        else begin
                            astar_state <= AS_EXPAND;
                        end
                    end
                end

                // --------------------------------------------------------------
                // Expand current node — compute 4 neighbours
                // Update g_score and came_from if better path found
                // --------------------------------------------------------------
                AS_EXPAND: begin
                    open_set[astar_current]   <= 1'b0;
                    closed_set[astar_current] <= 1'b1;

                    // North
                    if (can_go_north(astar_current)) begin
                        nb_id[0]    = astar_current + 7'd9;
                        nb_valid[0] = !closed_set[astar_current + 7'd9];
                        nb_g[0]     = {1'b0, g_score[astar_current]} + 9'd1;
                    end else begin
                        nb_valid[0] = 1'b0;
                        nb_id[0]    = 7'd0;
                        nb_g[0]     = 9'h1FF;
                    end

                    // South
                    if (can_go_south(astar_current)) begin
                        nb_id[1]    = astar_current - 7'd9;
                        nb_valid[1] = !closed_set[astar_current - 7'd9];
                        nb_g[1]     = {1'b0, g_score[astar_current]} + 9'd1;
                    end else begin
                        nb_valid[1] = 1'b0;
                        nb_id[1]    = 7'd0;
                        nb_g[1]     = 9'h1FF;
                    end

                    // East
                    if (can_go_east(astar_current)) begin
                        nb_id[2]    = astar_current + 7'd1;
                        nb_valid[2] = !closed_set[astar_current + 7'd1];
                        nb_g[2]     = {1'b0, g_score[astar_current]} + 9'd1;
                    end else begin
                        nb_valid[2] = 1'b0;
                        nb_id[2]    = 7'd0;
                        nb_g[2]     = 9'h1FF;
                    end

                    // West
                    if (can_go_west(astar_current)) begin
                        nb_id[3]    = astar_current - 7'd1;
                        nb_valid[3] = !closed_set[astar_current - 7'd1];
                        nb_g[3]     = {1'b0, g_score[astar_current]} + 9'd1;
                    end else begin
                        nb_valid[3] = 1'b0;
                        nb_id[3]    = 7'd0;
                        nb_g[3]     = 9'h1FF;
                    end

                    // Update neighbours
                    for (ni = 0; ni < 4; ni = ni + 1) begin
                        if (nb_valid[ni] && (nb_g[ni][7:0] < g_score[nb_id[ni]])) begin
                            g_score[nb_id[ni]]   <= nb_g[ni][7:0];
                            came_from[nb_id[ni]] <= astar_current;
                            open_set[nb_id[ni]]  <= 1'b1;
                        end
                    end

                    // Back to find min
                    astar_min_f    <= 9'h1FF;
                    astar_min_id   <= 7'd0;
                    astar_scan_idx <= 7'd0;
                    astar_state    <= AS_FIND_MIN;
                end

                // --------------------------------------------------------------
                // Walk came_from[] from EXIT back to START
                // path_cells[0] = EXIT, path_cells[retrace_idx] = START
                // --------------------------------------------------------------
                AS_RETRACE: begin
                    if (astar_current == start_id || came_from[astar_current] == 7'h7F) begin
                        // Reached start — store it and move to reverse
                        path_cells[retrace_idx] <= start_id;
                        path_len                <= retrace_idx + 7'd1;
                        retrace_idx             <= 7'd0;
                        astar_state             <= AS_REVERSE;
                    end
                    else begin
                        path_cells[retrace_idx] <= astar_current;
                        retrace_idx             <= retrace_idx + 7'd1;
                        astar_current           <= came_from[astar_current];
                    end
                end

                // --------------------------------------------------------------
                // Reverse path_cells into path_fwd
                // path_fwd[0] = START, path_fwd[path_len-1] = EXIT
                // path_idx starts at 1 (skip start cell, already there)
                // --------------------------------------------------------------
                AS_REVERSE: begin
                    if (retrace_idx < path_len) begin
                        path_fwd[retrace_idx] <= path_cells[(path_len - 7'd1) - retrace_idx];
                        retrace_idx           <= retrace_idx + 7'd1;
                    end
                    else begin
                        // Path ready — begin navigation from index 1
                        path_idx    <= 7'd1;
                        path_ready  <= 1'b1;
                        astar_state <= AS_READY;
                    end
                end

                // --------------------------------------------------------------
                // AS_READY — idle, just track step_done (handled above)
                // --------------------------------------------------------------
                AS_READY: begin
                    // Nothing to do — step_done handling at top of always block
                    // advances path_idx
                end

                default: astar_state <= AS_IDLE;

            endcase
        end
    end

endmodule
