`timescale 1ns/1ps
module tb_swim2_drive;
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0, ce = 1, sel = 0, write = 0;
reg [2:0] addr = 0;
reg [7:0] wdata = 0;
wire [7:0] rdata, setup, mode;
wire [3:0] phase, phase_oe;
reg mounted = 0, media_hd = 1, write_protect = 0;
reg index_pulse = 0, tach = 0, eject_ready = 0;
wire eject_request, eject_done, loaded, selected, motor, sense, side, context_changed;
wire [6:0] track;
reg rx_valid = 0, rx_mark = 0;
reg [7:0] rx_data = 0;
reg [4:0] rx_sector = 0;
reg encoded_tick = 0;
wire [7:0] encoded_data;
wire encoded_mark, encoded_crc;
wire [4:0] encoded_sector;
wire media_ready = encoded_tick && ce && selected && loaded && motor && !context_changed;
wire [4:0] write_sector;
wire write_sector_valid;
integer checks = 0, changes = 0, ejects = 0;
integer i;
integer previous_changes;

swim2 controller (
    .clk(clk), .nreset(nreset), .ce(ce), .sel(sel), .write(write), .addr(addr),
    .wdata(wdata), .rdata(rdata), .phase_in(4'd0), .zero_count(8'd0),
    .rddata(1'b0), .sense(sense), .context_changed(context_changed),
    .rx_valid(rx_valid || media_ready), .rx_data(media_ready ? encoded_data : rx_data),
    .rx_mark(media_ready ? encoded_mark : rx_mark), .rx_crc_zero(media_ready && encoded_crc),
    .rx_sector(media_ready ? encoded_sector : rx_sector), .rx_short(1'b0), .rx_long(1'b0),
    .tx_fault(1'b0), .tx_take(1'b0), .tx_data(), .tx_mark(), .tx_crc(), .tx_valid(),
    .phase_out(phase), .phase_oe(phase_oe), .setup(setup), .mode(mode),
    .write_late(), .write_early(), .write_sector(write_sector),
    .write_sector_valid(write_sector_valid)
);

mfm_track_encoder encoder (
    .clk(clk), .ready(media_ready), .rst(!nreset || context_changed),
    .side(side), .track(track), .hd(media_hd), .addr(), .idata(8'he5),
    .odata(encoded_data), .omark(encoded_mark), .ocrc0(encoded_crc),
    .oneeds(), .oindex(), .osector(encoded_sector)
);

swim2_drive drive (
    .clk(clk), .nreset(nreset), .ce(ce), .phase(phase), .phase_oe(phase_oe),
    .mode(mode), .mounted(mounted), .media_hd(media_hd), .write_protect(write_protect),
    .index_pulse(index_pulse), .tach(tach), .eject_ready(eject_ready),
    .eject_request(eject_request), .eject_done(eject_done), .loaded(loaded),
    .selected(selected), .motor(motor), .sense(sense), .track(track), .side(side),
    .context_changed(context_changed)
);

always @(posedge clk) if (context_changed) changes = changes + 1;
always @(negedge clk) if (eject_done) ejects = ejects + 1;

task check(input [31:0] actual, input [31:0] expected);
    begin
        checks = checks + 1;
        if (actual !== expected)
            $fatal(1, "check %0d: got %08h expected %08h", checks, actual, expected);
    end
endtask

task wr(input [2:0] a, input [7:0] d);
    begin
        @(negedge clk); addr = a; wdata = d; sel = 1; write = 1;
        @(negedge clk); sel = 0; write = 0;
        @(negedge clk); #1;
    end
endtask

task rd(input [2:0] a, input [7:0] expected);
    begin
        @(negedge clk); addr = a; sel = 1; write = 0;
        #1; check(rdata, expected);
        @(negedge clk); sel = 0;
    end
endtask

task bank(input high);
    begin
        if (high) wr(7, 8'h20);
        else wr(6, 8'h20);
    end
endtask

task command(input [3:0] cmd);
    begin
        bank(cmd[3]);
        wr(4, 8'hf8 | {5'd0, cmd[2:0]});
        wr(4, 8'hf0 | {5'd0, cmd[2:0]});
    end
endtask

task sense_reg(input [3:0] regnum, input expected);
    begin
        bank(regnum[0]); wr(4, 8'hf0 | {5'd0, regnum[3:1]});
        check(sense, expected); rd(7, expected ? 8'h08 : 8'h00);
    end
endtask

task receive(input [7:0] value, input [4:0] sector_number);
    begin
        @(negedge clk); rx_valid = 1; rx_mark = 1; rx_data = value; rx_sector = sector_number;
        @(negedge clk); rx_valid = 0; rx_mark = 0;
    end
endtask

task encoded_byte(input [7:0] expected, input mark);
    begin
        @(negedge clk); check(encoded_data, expected); check(encoded_mark, mark);
        encoded_tick = 1;
        @(negedge clk); encoded_tick = 0;
        rd(mark ? 1 : 0, expected);
    end
endtask

initial begin
    repeat (2) @(negedge clk);
    nreset = 1;
    check(track, 0); check(side, 0); check(motor, 0); check(loaded, 0);
    command(1); check(track, 0); // Deselected phase traffic cannot step.
    wr(7, 8'h84); check(selected, 0); check(sense, 1); // No external drive.
    wr(6, 4); wr(7, 2); check(selected, 1); check(motor, 0);
    sense_reg(0, 0); sense_reg(1, 1); sense_reg(2, 1); sense_reg(3, 0);
    sense_reg(4, 1); sense_reg(5, 0); sense_reg(6, 0); sense_reg(7, 0);
    sense_reg(8, 1); sense_reg(9, 1); sense_reg(10, 1); sense_reg(11, 1);
    sense_reg(12, 1); sense_reg(13, 0); sense_reg(14, 0); sense_reg(15, 0);

    @(negedge clk); mounted = 1;
    @(negedge clk); #1; check(loaded, 1);
    sense_reg(1, 0); sense_reg(3, 1); sense_reg(15, 0);
    write_protect = 1; sense_reg(3, 0); write_protect = 0;
    media_hd = 0; sense_reg(15, 1); media_hd = 1;

    // Only a fully driven falling LSTRB edge executes a donor command.
    bank(0); wr(4, 8'hf9); check(track, 0);
    wr(4, 8'hf9); check(track, 0); wr(4, 8'hf1); check(track, 1);
    wr(4, 8'hf1); check(track, 1);
    for (i = 0; i < 90; i = i + 1) command(1);
    check(track, 79); command(4); sense_reg(0, 1);
    for (i = 0; i < 90; i = i + 1) command(1);
    check(track, 0); sense_reg(5, 0);
    bank(0); wr(4, 8'h79); wr(4, 8'h71); check(track, 0);
    wr(4, 8'hf0); command(0);

    command(2); check(motor, 1); sense_reg(4, 0);
    index_pulse = 1; sense_reg(8, 0); sense_reg(9, 0);
    index_pulse = 0; sense_reg(8, 1);
    tach = 1; sense_reg(7, 1); tach = 0; sense_reg(7, 0);
    command(6); check(motor, 0); index_pulse = 1; sense_reg(8, 1);
    command(13); sense_reg(11, 0); command(9); sense_reg(11, 1);

    // Strobe bank changes while ACTION is clear do not change the data head.
    check(side, 0); sense_reg(9, 1); check(side, 0);
    wr(7, 8); @(negedge clk); #1; check(side, 1);
    bank(0); @(negedge clk); #1; check(side, 0); wr(6, 8);

    // Host removal asserts DiskChg; insertion preserves it until command C.
    @(negedge clk); mounted = 0;
    @(negedge clk); mounted = 1;
    sense_reg(6, 1); command(12); sense_reg(6, 0);

    // Acquire an anchor, queue another byte, then step to a new cylinder.
    bank(0); wr(4, 8'hf0); wr(7, 8);
    receive(8'ha1, 3); rd(1, 8'ha1); check(write_sector, 3); check(write_sector_valid, 1);
    receive(8'ha1, 4); wr(6, 8); command(1);
    check(track, 1); check(write_sector_valid, 0);
    rd(1, 8'ha1); check(write_sector_valid, 0); // Old FIFO data remains readable.

    // Drive-selected head/cylinder feed an actual MFM ID field into the FIFO.
    command(2); bank(0); wr(4, 8'hf4); wr(7, 8);
    while (!encoded_mark) begin
        @(negedge clk); encoded_tick = 1;
        @(negedge clk); encoded_tick = 0;
    end
    encoded_byte(8'ha1, 1); encoded_byte(8'ha1, 1); encoded_byte(8'ha1, 1);
    encoded_byte(8'hfe, 0); encoded_byte(1, 0); encoded_byte(0, 0);
    encoded_byte(1, 0); encoded_byte(2, 0);
    check(write_sector, 1); check(write_sector_valid, 1); wr(6, 8);

    // Eject waits for the old image's persistence, then stays logically absent.
    command(7); check(eject_request, 1); check(loaded, 1);
    repeat (4) @(negedge clk);
    check(eject_request, 1); check(ejects, 0); check(loaded, 1);
    @(negedge clk); eject_ready = 1;
    @(negedge clk); #1; check(eject_done, 1); check(loaded, 0);
    @(negedge clk); #1; check(eject_done, 0); check(ejects, 1);
    sense_reg(1, 1); sense_reg(6, 1); sense_reg(3, 0);
    command(7); check(eject_request, 0); check(loaded, 0);
    mounted = 0; @(negedge clk); @(negedge clk); mounted = 1;
    @(negedge clk); #1; check(loaded, 1); sense_reg(6, 1);

    // CE pauses commands and completion; reset works with CE stopped.
    command(7); ce = 0;
    repeat (3) @(negedge clk);
    check(eject_request, 1); check(loaded, 1); check(eject_done, 0);
    ce = 1; @(negedge clk); #1; check(loaded, 0); check(ejects, 2);
    previous_changes = changes;
    ce = 0; command(1); check(track, 1); check(changes, previous_changes);
    nreset = 0; @(negedge clk); #1;
    check(track, 0); check(motor, 0); check(eject_request, 0); check(write_sector_valid, 0);
    $display("PASS: SWIM II drive mechanics, %0d checks", checks);
    $finish;
end

initial begin
    #200000;
    $fatal(1, "timeout");
end
endmodule
