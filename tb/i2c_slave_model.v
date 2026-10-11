`timescale 1ns/1ps
// I2C slave (target) model for the testbenches, written from the I2C specification, not from the
// firmware. 7-bit address ADDR; EEPROM-style register pointer: in a write, the first data byte sets
// ptr and later bytes store mem[ptr++]; a read returns mem[ptr++] while the master ACKs.
// Knobs (set hierarchically from the testbench): en, tvd (ns, SDA valid after SCL falls),
// stretch_ns + stretch_mode (0 none, 1 after every ACK slot, 2 after every SCL fall),
// nack_at (NACK the write data byte with this index, 0 = pointer byte; -1 never).
// Outputs are open-drain pulls: sda_low / scl_low = 1 pulls the line low.
module i2c_slave_model #(parameter [6:0] ADDR = 7'h50) (
    input  wire sda,
    input  wire scl,
    output reg  sda_low = 1'b0,
    output reg  scl_low = 1'b0
);
    integer en = 1, tvd = 100, stretch_ns = 0, stretch_mode = 0, nack_at = -1;
    reg [7:0] mem [0:255];
    reg [7:0] ptr = 0, sh = 0, tx = 0;
    reg       busy = 0, addr_phase = 0, active = 0, rw = 0, m_ack = 0;
    integer   bitn = 0, nbyte = 0, k;
    initial for (k = 0; k < 256; k = k + 1) mem[k] = k[7:0] ^ 8'hA5;

    task drive(input low); sda_low <= #(tvd) low; endtask

    always @(negedge sda) if (scl === 1'b1) begin          // START / repeated START
        busy = 1; addr_phase = 1; active = 0; bitn = -1; sda_low <= 1'b0;   // the SCL fall after START is not a bit
    end
    always @(posedge sda) if (scl === 1'b1) begin          // STOP
        busy = 0; active = 0; sda_low <= 1'b0;
    end

    always @(posedge scl) if (busy) begin
        if (bitn < 8) sh = {sh[6:0], sda};
        else          m_ack = !sda;                         // 9th bit: ACK as seen on the bus
    end

    always @(negedge scl) if (busy) begin
        if (stretch_mode == 2 || (stretch_mode == 1 && bitn == 8)) scl_low = 1'b1;
        if (bitn < 7) begin
            bitn = bitn + 1;
            if (active && rw && !addr_phase) drive(!tx[7 - bitn]);
        end else if (bitn == 7) begin                      // 8 bits done: ACK slot
            bitn = 8;
            if (addr_phase) begin
                active = en && (sh[7:1] == ADDR);
                rw = sh[0];
                drive(active);
            end else if (active && !rw) begin
                if (nbyte == nack_at) drive(1'b0);           // NACK, byte not stored
                else begin
                    if (nbyte == 0) ptr = sh; else begin mem[ptr] = sh; ptr = ptr + 1; end
                    drive(1'b1);
                end
                nbyte = nbyte + 1;
            end else drive(1'b0);                          // reading: the master ACKs
        end else begin                                     // ACK slot done
            bitn = 0;
            if (addr_phase) begin addr_phase = 0; nbyte = 0; m_ack = 1; end
            if (active && rw && m_ack) begin tx = mem[ptr]; ptr = ptr + 1; drive(!tx[7]); end
            else begin drive(1'b0); if (active && rw) active = 0; end   // master NACK: stop sending
        end
        if (scl_low) begin #(stretch_ns); scl_low = 1'b0; end
    end
endmodule
