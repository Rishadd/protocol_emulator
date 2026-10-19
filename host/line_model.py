#!/usr/bin/env python3
"""Cycle-exact model of the line coder (src/line_coder.v), the golden reference of host/isa_model.py for the LINE opcode and RGET source 6.

    lc = LineCoder()
    lc.step(go, op, data, rd_pop, dp_in, dm_in)    # one clock edge; the state afterwards is what the pins and status show next clock
    lc.status(dp_in, dm_in)  lc.full()  lc.busy()  lc.outputs() -> (oe, dp, dm)   (combinational from the state before the next edge)

The behaviour is written to the specification in the header of src/line_coder.v; the structure follows the RTL so that every register can
be compared (host/isa_diff_test.py compares the observable behaviour of the whole engine). The bit-level correctness of the waveform is
checked separately against USB 2.0 by host/line_coder_test.py.
"""
import collections
import copy

OP_CFG, OP_PERIOD, OP_TXB, OP_TXE, OP_RXCTL, OP_RESET = range(6)
T_IDLE, T_RUN, T_E0, T_E1, T_EJ = range(5)
R_IDLE, R_SYNC, R_DATA, R_WAIT = range(4)


class LineCoder:
    def __init__(self):
        self.ev = collections.Counter()              # events seen (for coverage reports); shared by the state copies, not architectural
        self.reset()

    def reset(self):
        self.c_v, self.c_op, self.c_d = 0, 0, 0
        self.dp_pin, self.dm_pin, self.nrzi, self.stuff, self.slen, self.fs = 0, 1, 1, 1, 6, 0
        self.period, self.rx_en = 0x2155, 0
        self.q = []                                  # [(eop, byte)], at most 2
        self.tstate, self.oe_r, self.dp_r, self.dm_r, self.lvl = T_IDLE, 0, 0, 0, 1
        self.cur, self.bits_left, self.ones, self.tmr, self.tacc, self.underrun = 0, 0, 0, 0, 0, 0
        self.rstate, self.r_prev, self.rph, self.racc, self.psym = R_IDLE, 0, 0, 0, 1
        self.zc, self.rones, self.rbits, self.sh, self.rx_byte = 0, 0, 0, 0, 0
        self.rx_valid = self.f_eop = self.f_serr = self.f_ovr = self.f_sync = 0
        self.partial = 0

    # ---- combinational outputs of the present state
    def _enq(self):
        return self.c_v and self.c_op in (OP_TXB, OP_TXE)

    def full(self):
        return int(len(self.q) == 2 or (len(self.q) == 1 and self._enq()))

    def busy(self):
        return self.c_v

    def outputs(self):
        return self.oe_r, self.dp_r, self.dm_r

    def status(self, dp_in, dm_in):
        tx_busy = self.tstate != T_IDLE or len(self.q) != 0 or self._enq()
        return (self.rx_en << 22 | int(self.rstate == R_DATA) << 21 | self.underrun << 20 | self.partial << 17 |
                dp_in << 16 | dm_in << 15 | self.full() << 14 | int(bool(tx_busy)) << 13 | self.f_ovr << 12 | self.f_serr << 11 |
                self.f_sync << 10 | self.f_eop << 9 | self.rx_valid << 8 | self.rx_byte)

    # ---- one clock edge
    def step(self, go, op, data, rd_pop, dp_in, dm_in):
        s, n = self, copy.copy(self)
        n.q = list(self.q)
        jdp = s.fs
        c_rst = s.c_v and s.c_op == OP_RESET
        c_enq = s._enq()

        # command register
        n.c_v = int(bool(go))
        if go:
            n.c_op, n.c_d = op & 7, data & 0xFFFF

        # configuration
        if s.c_v:
            if s.c_op == OP_CFG:
                n.dp_pin, n.dm_pin, n.nrzi, n.stuff = s.c_d & 7, s.c_d >> 3 & 7, s.c_d >> 6 & 1, s.c_d >> 7 & 1
                n.slen, n.fs = s.c_d >> 8 & 7, s.c_d >> 11 & 1
            elif s.c_op == OP_PERIOD:
                n.period = s.c_d
            elif s.c_op == OP_RXCTL:
                n.rx_en = s.c_d & 1
            elif s.c_op == OP_RESET:
                n.rx_en = 0

        # transmitter: combinational view
        tsum = s.tacc + (s.period & 0xFF)
        tlen = ((s.period >> 8) + (tsum >> 8)) & 0xFF
        tick = s.tmr == 0
        stuff_now = bool(s.stuff) and s.ones == s.slen
        have_cur = s.bits_left != 0
        q_data = len(s.q) != 0 and not s.q[0][0]
        q_eop = len(s.q) != 0 and s.q[0][0]
        srcb = s.cur if have_cur else (s.q[0][1] if s.q else 0)
        ebit = 0 if stuff_now else srcb & 1
        nlvl = (s.lvl if ebit else 1 - s.lvl) if s.nrzi else ebit
        tx_pop = False
        if not c_rst:
            if s.tstate == T_IDLE:
                tx_pop = bool(q_eop)
            elif s.tstate == T_RUN and tick and not stuff_now:
                tx_pop = (not have_cur) and bool(q_data or q_eop)
        push = bool(c_enq) and (len(s.q) != 2 or tx_pop)
        item = (int(s.c_op == OP_TXE), s.c_d & 0xFF)

        # queue
        if c_rst:
            n.q = []
        else:
            if push and not tx_pop:
                n.q.append(item)
            elif tx_pop and not push:
                n.q.pop(0)
            elif push and tx_pop:
                if len(s.q) == 1:
                    n.q = [item]
                else:
                    n.q = [s.q[1], item]

        def emit_level(l):
            n.lvl = l
            n.dp_r = jdp if l else 1 - jdp
            n.dm_r = 1 - jdp if l else jdp

        def reload():
            n.tacc = tsum & 0xFF
            n.tmr = (tlen - 1) & 0xFF

        if c_rst:
            n.tstate, n.oe_r, n.lvl, n.bits_left, n.ones, n.tmr, n.underrun = T_IDLE, 0, 1, 0, 0, 0, 0
        else:
            if s.c_v and s.c_op == OP_RXCTL and s.c_d >> 1 & 1:
                n.underrun = 0
            if s.tmr != 0:
                n.tmr = s.tmr - 1
            if s.tstate == T_IDLE:
                n.lvl, n.ones, n.bits_left = 1, 0, 0
                if s.q:
                    if s.q[0][0]:
                        n.oe_r, n.dp_r, n.dm_r, n.tstate = 1, 0, 0, T_E0
                        reload()
                        self.ev["tx_eop"] += 1
                    else:
                        n.tstate, n.tmr = T_RUN, 0
            elif s.tstate == T_RUN:
                if tick:
                    if stuff_now or have_cur or q_data:
                        n.oe_r = 1
                        emit_level(nlvl)
                        reload()
                        if stuff_now:
                            n.ones = 0
                            self.ev["tx_stuff"] += 1
                        else:
                            self.ev["tx_bit"] += 1
                            n.cur = srcb >> 1
                            n.bits_left = ((s.bits_left if have_cur else 8) - 1) & 15
                            n.ones = (s.ones if s.ones == 7 else s.ones + 1) if srcb & 1 else 0
                    elif q_eop:
                        n.dp_r, n.dm_r, n.tstate = 0, 0, T_E0
                        reload()
                        self.ev["tx_eop"] += 1
                    else:
                        n.underrun = 1
                        self.ev["underrun"] += 1
            elif s.tstate == T_E0:
                if tick:
                    n.dp_r, n.dm_r, n.tstate = 0, 0, T_E1
                    reload()
            elif s.tstate == T_E1:
                if tick:
                    emit_level(1)
                    n.tstate = T_EJ
                    reload()
            elif s.tstate == T_EJ:
                if tick:
                    n.oe_r, n.dp_r, n.dm_r, n.tstate = 0, 0, 0, T_IDLE
            else:
                n.tstate = T_IDLE

        # receiver
        se0 = not dp_in and not dm_in
        se1 = dp_in and dm_in
        j_s = dp_in == jdp and dm_in == 1 - jdp
        k_s = dp_in == 1 - jdp and dm_in == jdp
        redge = (dp_in << 1 | dm_in) != s.r_prev
        rsum = s.racc + (s.period & 0xFF)
        rlen = ((s.period >> 8) + (rsum >> 8)) & 0xFF
        half = (s.period >> 9) & 0x7F
        rtrack = s.rstate in (R_SYNC, R_DATA)
        sample = rtrack and not redge and s.rph == half
        rbit = int(j_s == bool(s.psym)) if s.nrzi else int(j_s)
        r_stuffed = bool(s.stuff) and s.rones == s.slen

        n.r_prev = dp_in << 1 | dm_in
        if rd_pop:
            n.rx_valid = 0
        if s.c_v and s.c_op == OP_RXCTL and s.c_d >> 1 & 1:
            n.f_eop = n.f_serr = n.f_ovr = n.f_sync = 0
        if c_rst or not s.rx_en or s.oe_r:
            n.rstate = R_IDLE
            if c_rst:
                n.rx_valid = 0
        elif s.rstate == R_IDLE:
            if k_s:
                n.rstate, n.rph, n.racc, n.psym, n.zc = R_SYNC, 0, 0, 1, 0
        elif rtrack:
            if redge:
                n.rph = 0
            elif s.rph >= ((rlen - 1) & 0xFF):
                n.rph, n.racc = 0, rsum & 0xFF
            else:
                n.rph = (s.rph + 1) & 0xFF
            if sample:
                if se0:
                    if s.rstate == R_DATA:
                        n.f_eop, n.partial = 1, s.rbits
                        self.ev["rx_eop"] += 1
                        if s.rbits:
                            self.ev["rx_partial"] += 1
                    n.rstate = R_WAIT
                elif se1:
                    n.f_serr, n.rstate = 1, R_WAIT
                    self.ev["rx_serr"] += 1
                else:
                    n.psym = int(j_s)
                    if s.rstate == R_SYNC:
                        if not rbit:
                            n.zc = s.zc if s.zc == 7 else s.zc + 1
                        elif s.zc >= 3:
                            n.rstate, n.f_sync, n.rones, n.rbits = R_DATA, 1, 1, 0
                            self.ev["rx_sync"] += 1
                        else:
                            n.rstate = R_WAIT
                    else:
                        if r_stuffed:
                            n.rones = 0
                            if rbit:
                                n.f_serr, n.rstate = 1, R_WAIT
                                self.ev["rx_serr"] += 1
                            else:
                                self.ev["rx_destuff"] += 1
                        else:
                            n.rones = (s.rones if s.rones == 7 else s.rones + 1) if rbit else 0
                            n.sh = (rbit << 7 | s.sh >> 1) & 0xFF
                            n.rbits = (s.rbits + 1) & 7
                            if s.rbits == 7:
                                n.rx_byte = (rbit << 7 | s.sh >> 1) & 0xFF
                                self.ev["rx_byte"] += 1
                                if s.rx_valid and not rd_pop:
                                    n.f_ovr = 1
                                    self.ev["rx_ovr"] += 1
                                n.rx_valid = 1
        elif s.rstate == R_WAIT:
            if j_s:
                n.rstate = R_IDLE
        self.__dict__.update(n.__dict__)
