// Included by tb_cpu040_machine. Synthetic workloads, not Speedometer scores.
localparam PROFILE_CASES = 9;
string profile_name [0:PROFILE_CASES-1];
reg [31:0] profile_start [0:PROFILE_CASES-1], profile_end [0:PROFILE_CASES-1];
integer profile_cycles = 0;
integer profile_beats [0:4] = '{default:0};
integer profile_waits [0:4] = '{default:0};
bit profile_active = 0;
integer profile_engine [string];
integer profile_biu [string];
integer profile_dc2_hold = 0, profile_wb_hold = 0;

// Instruction, RAM read/write, VRAM read/write. Count machine-bus occupancy.
always @(posedge clk) begin : profile_count
    integer kind;
    if (nreset && $test$plusargs("PROFILE")) begin
        profile_cycles++;
        if (profile_active) begin
            profile_engine[dut.cpu.cpu.dmu.e_st.name()]++;
            profile_biu[dut.cpu.cpu.biu.st.name()]++;
            if (dut.cpu.cpu.dmu.m2.r.v && !dut.cpu.cpu.dmu.adv_dc2) profile_dc2_hold++;
            if (dut.cpu.cpu.dmu.m4.r.v && !dut.cpu.cpu.dmu.adv_wb) profile_wb_hold++;
        end
        if (dut.bus_req) begin
            kind = dut.bus_instr ? 0 :
                   dut.bus_addr[31:24] == 8'hF9 ? (dut.bus_write ? 4 : 3) :
                   (dut.bus_write ? 2 : 1);
            if (dut.bus_ack) profile_beats[kind]++;
            else profile_waits[kind]++;
        end
    end
end

// The hardware perf counters (rtl/perf_counters.sv) count from time zero and
// are never cleared here; check them against this file's own counts.
task automatic perf_check;
    integer m_req, m_wait;
    for (integer p = 0; p < 7; p++)
        $display("PROFILE: perf page %0d: %0d %0d %0d %0d %0d %0d", p,
                 dut.cpu.perf.cnt[p*6], dut.cpu.perf.cnt[p*6+1], dut.cpu.perf.cnt[p*6+2],
                 dut.cpu.perf.cnt[p*6+3], dut.cpu.perf.cnt[p*6+4], dut.cpu.perf.cnt[p*6+5]);
    m_req = 0; m_wait = 0;
    for (integer i = 0; i < 5; i++) begin
        m_req += profile_beats[i] + profile_waits[i];
        m_wait += profile_waits[i];
    end
    if (dut.cpu.perf.cnt[0] < profile_cycles || dut.cpu.perf.cnt[28] != m_req ||
        dut.cpu.perf.cnt[29] != m_wait || dut.cpu.perf.cnt[24] != profile_beats[3] ||
        dut.cpu.perf.cnt[26] != profile_beats[4])
        $fatal(1, "Perf counters disagree: cycles %0d/%0d, bus %0d/%0d, waits %0d/%0d, VRAM-R %0d/%0d, VRAM-W %0d/%0d",
               dut.cpu.perf.cnt[0], profile_cycles, dut.cpu.perf.cnt[28], m_req,
               dut.cpu.perf.cnt[29], m_wait, dut.cpu.perf.cnt[24], profile_beats[3],
               dut.cpu.perf.cnt[26], profile_beats[4]);
    $display("PASS: perf counters agree with the profile's bus counts");
`ifdef VRAM_DDR3
    // every VRAM read beat is a hit, a fill, or acked by a prefetch's fill
    // beat (counted only among the used prefetches, cnt[40]); a prefetch is
    // used at most once (pages 5 and 6)
    if (dut.cpu.perf.cnt[30] + dut.cpu.perf.cnt[31] >
            dut.cpu.perf.cnt[24] + dut.cpu.perf.cnt[24] / 50 ||
        dut.cpu.perf.cnt[30] + dut.cpu.perf.cnt[31] + dut.cpu.perf.cnt[40] +
            dut.cpu.perf.cnt[24] / 50 < dut.cpu.perf.cnt[24] ||
        dut.cpu.perf.cnt[40] > dut.cpu.perf.cnt[39])
        $fatal(1, "VRAM perf events disagree: hits %0d + fills %0d vs read beats %0d, prefetches used/issued %0d/%0d",
               dut.cpu.perf.cnt[30], dut.cpu.perf.cnt[31], dut.cpu.perf.cnt[24],
               dut.cpu.perf.cnt[40], dut.cpu.perf.cnt[39]);
    $display("PASS: VRAM hits %0d + fills %0d vs read beats %0d, prefetches used/issued %0d/%0d",
             dut.cpu.perf.cnt[30], dut.cpu.perf.cnt[31], dut.cpu.perf.cnt[24],
             dut.cpu.perf.cnt[40], dut.cpu.perf.cnt[39]);
`endif
endtask

// +TRACE_VRAM_RD: one line per clock through a few iterations of one case
// (+TRACE_CASE=n, default 7, the masked update; first run only)
integer trace_left = 0, trace_case = 7;
initial void'($value$plusargs("TRACE_CASE=%d", trace_case));
always @(posedge clk) begin
    if ($test$plusargs("TRACE_VRAM_RD") && profile_active && profile_name[trace_case] != "" &&
        dut.cpu_instruction_pc >= profile_start[trace_case] - 12 &&
        dut.cpu_instruction_pc <= profile_end[trace_case] &&
        trace_left < 120) begin
        trace_left++;
        $display("TRACE %0d pc=%h e=%s biu=%s ts=%b ta=%b breq=%b back=%b bw=%b ba=%h svc=%0d mreq=%b mack=%b vwp=%b",
                 profile_cycles, dut.cpu_instruction_pc, dut.cpu.cpu.dmu.e_st.name(),
                 dut.cpu.cpu.biu.st.name(), dut.cpu.c_ts_n, dut.cpu.c_ta_n,
                 dut.bus_req, dut.bus_ack, dut.bus_write, dut.bus_addr, dut.svc,
                 mem_req, mem_ack, mem_vram_wp);
        $display("TRACEP %0d v=%b%b%b%b mem2=%0d mem4=%0d adv=%b%b%b%b d2done=%b gnt=%b done=%b older=%b vrd=%b slow=%b post=%b hold1=%b kill=%b",
                 profile_cycles, dut.cpu.cpu.dmu.m1.v, dut.cpu.cpu.dmu.m2.r.v, dut.cpu.cpu.dmu.m3.r.v,
                 dut.cpu.cpu.dmu.m4.r.v, dut.cpu.cpu.dmu.m2.r.mem, dut.cpu.cpu.dmu.m4.r.mem,
                 dut.cpu.cpu.dmu.adv_dc1, dut.cpu.cpu.dmu.adv_dc2, dut.cpu.cpu.dmu.adv_ex,
                 dut.cpu.cpu.dmu.adv_wb, dut.cpu.cpu.dmu.e_dc2_done, dut.cpu.cpu.dmu.b_gnt,
                 dut.cpu.cpu.dmu.b_done, dut.cpu.cpu.dmu.dm_older, dut.cpu.cpu.dmu.dc2_vrd,
                 dut.cpu.cpu.dmu.dc2_slow, dut.cpu.cpu.dmu.wb_vram_post, dut.cpu.cpu.dmu.dm_hold1,
                 dut.cpu.cpu.dmu.kill_now);
    end
end

task automatic profile_loop(input integer which);
    integer loop_pc;
    emit16('h207C); emit32(which < 3 ? (which == 2 ? 'h4000 : 'h2000) :
                          (which == 8 ? 'hF9005000 : which == 7 ? 'hF9004000 :
                           which == 5 ? 'hF9002000 : which == 4 ? 'hF9001000 : 'hF9000000)); // MOVEA.L #a,A0
    if (which == 7) begin
        emit16('h243C); emit32('hFFFF0000); // MOVE.L #mask,D2
        emit16('h263C); emit32('h0000ABCD); // MOVE.L #pattern,D3
    end
    emit16('h227C); emit32('hF9003000); // MOVEA.L #a,A1
    emit16('h7000); // MOVEQ #0,D0
    emit16('h323C); emit16(255); // MOVE.W #255,D1
    loop_pc = pc;
    case (which)
        0: begin
            profile_name[which] = "cached integer (four ADDQ)";
            repeat (4) emit16('h5280); // ADDQ.L #1,D0
        end
        1,5: begin
            profile_name[which] = which == 1 ? "cached RAM read/modify/write" : "VRAM read/modify/write";
            emit16('h2010); // MOVE.L (A0),D0
            emit16('h5280); // ADDQ.L #1,D0
            emit16('h2080); // MOVE.L D0,(A0)
        end
        2,3: begin
            profile_name[which] = which == 2 ? "RAM sequential read" : "VRAM sequential read";
            emit16('h2018); // MOVE.L (A0)+,D0
        end
        4: begin
            profile_name[which] = "VRAM sequential write";
            emit16('h20C0); // MOVE.L D0,(A0)+
            emit16('h5280); // ADDQ.L #1,D0
        end
        6: begin
            profile_name[which] = "VRAM sequential copy";
            emit16('h22D8); // MOVE.L (A0)+,(A1)+
        end
        7: begin
            // QuickDraw-shaped: a masked pixel update along a row
            profile_name[which] = "VRAM masked read/modify/write";
            emit16('h2010); // MOVE.L (A0),D0
            emit16('hC082); // AND.L D2,D0
            emit16('h8083); // OR.L D3,D0
            emit16('h20C0); // MOVE.L D0,(A0)+
        end
        8: begin
            // one instruction that reads and writes its operand (QuickDraw's
            // invert, OR and XOR transfer loops)
            profile_name[which] = "VRAM read-modify-write instruction";
            emit16('h4698); // NOT.L (A0)+
        end
    endcase
    profile_start[which] = 'h40800000 + pc;
    emit16('h51C9); emit16(16'(loop_pc - pc)); // DBRA D1,loop
    profile_end[which] = 'h40800000 + pc;
    emit16('h4E71); // NOP: end marker
    emit16('h23C0); emit32('h100 + which*4); // result signature
    case (which)
        0: expected[which] = 1024;
        1,4,5: expected[which] = 256;
        2,3: expected[which] = 'h12345678;
        6,8: expected[which] = 0;
        7: expected[which] = 'h0000ABCD;
    endcase
endtask

task automatic run_profile;
    integer first_cycle, engine_total, biu_total;
    reg [30:0] mapped, rmw_mapped;
    integer backing_addr;
    integer first_beats [0:4], first_waits [0:4];
    integer first_vq_full, first_vd_rd, first_vd_wr;
    integer run_vram_w;
    pc = 0; emit32('h7000); emit32('h40800400);
    pc = 'h400;
    emit16('hF4D8); // CINVA BC
    store('h5000E07C, 'h10); // MEMCjr holding latch: bank mode bit
    store('h5000E004, 0); // bank 0 mode 1: four-megabyte soldered RAM mapping
    emit16('h203C); emit32('h80008000);
    emit16('h4E7B); emit16('h0002); // enable instruction/data caches
    for (integer k = 0; k < PROFILE_CASES; k++) profile_loop(k);
    done_pc = 'h40800000 + pc;
    emit16('h4E72); emit16('h2700);
    expected_count = PROFILE_CASES;

    for (integer run = 0; run < 2; run++) begin
        nreset = 0;
        repeat (8) @(negedge clk);
        for (integer i = 0; i < 4194304; i++) ram[i] = 0;
        for (integer i = 0; i < 65536; i++) vram[i] = 0;
        for (integer i = 0; i < 1024; i += 4) begin
            vram[i] = 'h12; vram[i+1] = 'h34; vram[i+2] = 'h56; vram[i+3] = 'h78;
        end
        signatures = 0; transfers = 0; posts = 0;
        retain = 1; delay_cycles = run*3;
        $display("PROFILE: %s, 25 MHz, retained RAM/ROM, modeled RAM/ROM reply delay=%0d; production VRAM port timing",
`ifdef VRAM_DDR3
                 $sformatf("DDR3 VRAM rd_lat=%0d line=%0d stride=%0d", ddr_rd_lat, line_clks, vid_stride_bytes),
`else
                 "BRAM VRAM",
`endif
                 delay_cycles);
        run_vram_w = profile_beats[4];
        nreset = 1;
        wait (dut.memc_bank_mode[0]);
        @(negedge clk);
        // The fixture array uses SDRAM backing addresses, not CPU addresses.
        rmw_mapped = dut.ram_map(30'('h2000 >> 2));
        if (!rmw_mapped[30]) $fatal(1, "Profile RAM update region is unpopulated");
        for (integer i = 0; i < 1024; i += 4) begin
            mapped = dut.ram_map(30'(('h4000+i) >> 2));
            backing_addr = {mapped[29:0], 2'b00};
            if (!mapped[30] || backing_addr < 0 || backing_addr > 4194300 ||
                mapped == rmw_mapped)
                $fatal(1, "Profile RAM read/update regions overlap or exceed backing");
            ram[backing_addr] = 'h12; ram[backing_addr+1] = 'h34;
            ram[backing_addr+2] = 'h56; ram[backing_addr+3] = 'h78;
        end
        if (read32(0, {rmw_mapped[29:0], 2'b00}) !== 32'd0)
            $fatal(1, "Profile RAM update region was not initialized to zero");
        for (integer k = 0; k < PROFILE_CASES; k++) begin
            // First DBRA retirement to the end marker: 255 warm iterations + NOP.
            do @(negedge clk); while (dut.cpu_instruction_pc != profile_start[k]);
            profile_engine.delete(); profile_biu.delete();
            profile_dc2_hold = 0; profile_wb_hold = 0;
            profile_active = 1;
            first_cycle = profile_cycles;
`ifdef VRAM_DDR3
            first_vq_full = vq_full; first_vd_rd = vd_busy_rd; first_vd_wr = vd_busy_wr;
`endif
            for (integer b = 0; b < 5; b++) begin
                first_beats[b] = profile_beats[b]; first_waits[b] = profile_waits[b];
            end
            do @(negedge clk); while (dut.cpu_instruction_pc != profile_end[k]);
            profile_active = 0;
            $display("PROFILE: %s: %0d cycles / (255 warm iterations + NOP), %0.3f interval cycles/iteration",
                     profile_name[k], profile_cycles-first_cycle, real'(profile_cycles-first_cycle)/255.0);
            $display("PROFILE:   beats I/RAM-R/RAM-W/VRAM-R/VRAM-W=%0d/%0d/%0d/%0d/%0d; waits=%0d/%0d/%0d/%0d/%0d",
                     profile_beats[0]-first_beats[0], profile_beats[1]-first_beats[1],
                     profile_beats[2]-first_beats[2], profile_beats[3]-first_beats[3], profile_beats[4]-first_beats[4],
                     profile_waits[0]-first_waits[0], profile_waits[1]-first_waits[1],
                     profile_waits[2]-first_waits[2], profile_waits[3]-first_waits[3], profile_waits[4]-first_waits[4]);
`ifdef VRAM_DDR3
            $display("PROFILE:   DDR3 VRAM: write queue full %0d clocks; DDR3 busy reading %0d, writing %0d",
                     vq_full-first_vq_full, vd_busy_rd-first_vd_rd, vd_busy_wr-first_vd_wr);
`endif
            engine_total = 0; biu_total = 0;
            $write("PROFILE:   DMU cycles:");
            foreach (profile_engine[state_name]) begin
                $write(" %s=%0d", state_name, profile_engine[state_name]);
                engine_total += profile_engine[state_name];
            end
            $display("");
            $write("PROFILE:   BIU cycles:");
            foreach (profile_biu[state_name]) begin
                $write(" %s=%0d", state_name, profile_biu[state_name]);
                biu_total += profile_biu[state_name];
            end
            $display("; overlapping pipeline holds DC2=%0d WB=%0d", profile_dc2_hold, profile_wb_hold);
            if (engine_total != profile_cycles-first_cycle || biu_total != engine_total)
                $fatal(1, "Profile state census does not cover the measured interval");
            if (k >= 3) begin
                // a posted store (AP040_VRAM_POST) from the untimed first
                // iteration can reach the bus inside the window: one extra
                // write beat; the run's exact total is checked at the end.
                // A VRAM read does not wait for older instructions: the read
                // behind the loop's last DBRA reaches the bus and is discarded
                if ((k == 4 ? profile_beats[3]-first_beats[3] != 0 :
                     (profile_beats[3]-first_beats[3] < 255 ||
                      profile_beats[3]-first_beats[3] > 256)) ||
                    (k == 3 ? profile_beats[4]-first_beats[4] != 0 :
                     (profile_beats[4]-first_beats[4] < 255 ||
                      profile_beats[4]-first_beats[4] > 256)))
                    $fatal(1, "Profile VRAM workload lost or duplicated a bus beat");
            end
        end
        wait (dut.cpu_instruction_pc == done_pc);
        repeat (40) @(negedge clk);
`ifdef VRAM_DDR3
        // the checks below read the DDR3 model: let the write FIFO drain
        // first (a normal drain waits behind a scanline fetch's bursts)
        wait (vram_inst.fifo_count == 0 && vram_inst.state == 0);
        @(negedge clk);
`endif
        // five VRAM-writing loops (cases 4-8), 256 stores each
        if (profile_beats[4] - run_vram_w != 1280)
            $fatal(1, "Profile VRAM write beats %0d, expected 1280", profile_beats[4] - run_vram_w);
        if (signatures != expected_count || overlay || dut.cpu.cpu.cacr != 'h80008000)
            $fatal(1, "Profile completion/cache checks failed");
        for (integer i = 0; i < 256; i++) begin
            if ({vram['h1000+i*4], vram['h1001+i*4], vram['h1002+i*4], vram['h1003+i*4]} !== 32'(i))
                $fatal(1, "VRAM write result %0d", i);
            if ({vram['h3000+i*4], vram['h3001+i*4], vram['h3002+i*4], vram['h3003+i*4]} !== 32'h12345678)
                $fatal(1, "VRAM copy result %0d", i);
            if ({vram['h4000+i*4], vram['h4001+i*4], vram['h4002+i*4], vram['h4003+i*4]} !== 32'h0000ABCD)
                $fatal(1, "VRAM masked update result %0d", i);
            if ({vram['h5000+i*4], vram['h5001+i*4], vram['h5002+i*4], vram['h5003+i*4]} !== 32'hFFFFFFFF)
                $fatal(1, "VRAM read-modify-write instruction result %0d", i);
        end
        if ({vram['h2000], vram['h2001], vram['h2002], vram['h2003]} !== 32'd256)
            $fatal(1, "VRAM read/modify/write result");
        $display("PASS: CPU040 cycle profile run %0d: nine workload signatures and VRAM contents", run);
        perf_check();
    end
endtask
