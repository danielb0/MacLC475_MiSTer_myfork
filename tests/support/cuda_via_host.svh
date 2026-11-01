`ifndef CUDA_BOARD
`define CUDA_BOARD dut
`endif
`ifndef CUDA_HOST_ACCESS
task access(input [3:0] regnum, input bit write, input [7:0] data, output [7:0] result);
    begin
        do @(negedge clk); while (!falling);
        addr = regnum; wen = write; ren = !write; data_in = data;
        @(negedge clk); result = data_out; wen = 0; ren = 0;
    end
endtask
`endif
reg [7:0] unused;
task put(input [3:0] regnum, input [7:0] data);
    access(regnum,1,data,unused);
endtask
task sr_done;
    reg [7:0] flags;
    integer polls;
    begin
        polls = 0;
        do begin
            access(13,0,0,flags); polls++;
            if (polls > 80000) $fatal(1,"CUDA SR timeout PC=%04h PB=%02h DDR=%02h TIP=%b TACK=%b TREQ=%b CB1=%b",
                `CUDA_BOARD.mcu.cpu.regPC,`CUDA_BOARD.pb,`CUDA_BOARD.pb_ddr,tip,tack,treq,cb1);
        end while (!flags[2]);
    end
endtask

task wait_treq(input bit value);
    integer timeout;
    begin
        timeout = 0;
        while (treq != value) begin
            @(negedge clk); timeout++;
            if (timeout > 2500000) $fatal(1,"CUDA TREQ timeout PC=%04h X=%02h SP=%04h return=%02h%02h PLL=%02h PB=%02h/%02h TIP=%b TACK=%b",`CUDA_BOARD.mcu.cpu.regPC,`CUDA_BOARD.mcu.cpu.regX,`CUDA_BOARD.mcu.cpu.regSP,`CUDA_BOARD.mcu.ram[111],`CUDA_BOARD.mcu.ram[110],`CUDA_BOARD.mcu.pll_ctrl,`CUDA_BOARD.pb,`CUDA_BOARD.pb_ddr,tip,tack);
        end
    end
endtask

reg [7:0] portb = 'h30;
reg [7:0] packet [0:15];
reg [7:0] reply [0:15];
integer reply_len;
integer read_limit = 0;
task request(input integer count);
    integer index;
    reg [7:0] status;
    begin
        put(11,'h1C); put(10,packet[0]);
        portb[5] = 0; put(0,portb);
        for (index = 1; index < count; index++) begin
            sr_done;
            if (!treq) $fatal(1,"Unexpected CUDA send collision");
            put(10,packet[index]);
            portb[4] = !portb[4]; put(0,portb);
        end
        sr_done;
        put(11,'h0C); access(10,0,0,unused);
        portb = 'h30; put(0,portb);
        sr_done; access(10,0,0,unused);
        portb[5] = 0; put(0,portb);
        reply_len = 0;
        do begin
            sr_done;
            access(0,0,0,status);
            access(10,0,0,reply[reply_len]);
            reply_len++;
            if (reply_len == 16) $fatal(1,"CUDA reply overflow");
            if (!status[3] && (read_limit == 0 || reply_len < read_limit)) begin
                portb[4] = !portb[4]; put(0,portb);
            end
        end while (!status[3] && (read_limit == 0 || reply_len < read_limit));
        portb = 'h30; put(0,portb);
        sr_done; access(10,0,0,unused);
        $write("CUDA reply:");
        for (index = 0; index < reply_len; index++) $write(" %02h",reply[index]);
        $write("\n");
    end
endtask

task synchronize;
    begin
    portb = 'h30;
    put(2,'h30); put(11,'h0C); put(0,'h30);
    access(10,0,0,unused); put(13,4);
    // Synchronize TACK with TIP inactive, then consume both dummy shifts.
    portb = 'h20; put(0,portb);
    wait_treq(0); sr_done;
    access(10,0,0,unused); put(13,4);
    portb = 'h30; put(0,portb);
    wait_treq(1); sr_done;
    access(10,0,0,unused); put(13,4);
    end
endtask

task native_sync_wait(input bit shift_flag, input bit value, input integer limit, input bit required);
    reg [7:0] status;
    integer polls;
    begin
        polls = 0;
        do begin
            access(shift_flag ? 13 : 0, 0, 0, status);
            polls++;
        end while ((shift_flag ? status[2] : status[3]) != value && polls < limit);
        if (required && (shift_flag ? status[2] : status[3]) != value)
            $fatal(1, "Native CUDA sync timeout: IFR=%b value=%b status=%02h", shift_flag, value, status);
    end
endtask

task native_synchronize;
    reg [7:0] config_read;
    begin
        // FF7439EE $408A9F66: read SR after TREQ rises, before waiting for IFR.
        portb = 'h30;
        put(2, 'h30);
        access(2, 0, 0, config_read);
        if (config_read !== 'h30) $fatal(1, "CUDA VIA DDRB readback: %02h expected 30", config_read);
        put(11, 'h0C);
        access(11, 0, 0, config_read);
        if (config_read !== 'h0C) $fatal(1, "CUDA VIA ACR readback: %02h expected 0c", config_read);
        put(0, portb);
        repeat ('h0D06) access(0, 0, 0, unused);
        access(0, 0, 0, unused);
        if (!unused[3]) native_sync_wait(1, 1, 'h0D06, 0);
        access(10, 0, 0, unused);
        portb = 'h20; put(0, portb);
        native_sync_wait(0, 0, 'h23D0, 1);
        native_sync_wait(1, 1, 'h23D0, 0);
        portb = 'h30; put(0, portb);
        native_sync_wait(0, 1, 'h23D0, 1);
        access(10, 0, 0, unused);
        native_sync_wait(1, 1, 'h23D0, 1);
        put(0, portb); access(10, 0, 0, unused);
    end
endtask

