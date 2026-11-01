// Single SuperDrive mechanics adapted from the pinned LC floppy.v.
module swim2_drive (
    input        clk,
    input        nreset,
    input        ce,
    input  [3:0] phase,
    input  [3:0] phase_oe,
    input  [7:0] mode,
    input        mounted,      // image ownership committed by the host path
    input        media_hd,
    input        write_protect,
    input        index_pulse,
    input        tach,
    input        eject_ready,  // persistence has drained against the old image
    output reg   eject_request,
    output reg   eject_done,
    output       loaded,
    output       selected,
    output       motor,
    output       sense,
    output reg [6:0] track,
    output reg   side,
    output       context_changed
);

reg direction;
reg motor_on;
reg mfm_mode;
reg switched;
reg ejected;
reg mounted_d, hd_d, selected_d, strobe_d;
wire [3:0] read_addr = {phase[2:0], mode[5]};
wire [3:0] command = {mode[5], phase[2:0]};
wire command_strobe = selected && (&phase_oe) && strobe_d && !phase[3];
wire step = command_strobe && command == 1;
wire step_moves = step && (direction ? track != 0 : track != 79);
wire side_select = selected && mode[3] && !phase[3] && (&phase_oe) &&
                   (read_addr == 8 || read_addr == 9);
wire side_moves = side_select && side != read_addr[0];
wire eject_accept = mounted && eject_request && eject_ready;
wire format_change = command_strobe &&
                     ((command == 9 && !mfm_mode) || (command == 13 && mfm_mode));
reg sense_value;

assign selected = mode[7] && mode[1];
assign loaded = mounted && !ejected;
assign motor = motor_on;
assign sense = selected ? sense_value : 1'b1;
assign context_changed = nreset && ce &&
                         (mounted != mounted_d || (loaded && media_hd != hd_d) ||
                          selected != selected_d || step_moves || side_moves ||
                          eject_accept || format_change);

always @* begin
    case (read_addr)
        0: sense_value = direction;
        1: sense_value = !loaded;
        2: sense_value = 1; // Step completes immediately in this staged model.
        3: sense_value = loaded && !write_protect;
        4: sense_value = !motor_on;
        5: sense_value = track != 0;
        6: sense_value = switched;
        7: sense_value = loaded && motor_on && tach;
        8, 9: sense_value = loaded && motor_on ? !index_pulse : 1'b1;
        10: sense_value = 1; // SuperDrive
        11: sense_value = mfm_mode;
        12: sense_value = 1; // Double-sided mechanism
        13, 14: sense_value = 0; // Ready, installed
        15: sense_value = loaded && !media_hd;
    endcase
end

always @(posedge clk) begin
    eject_done <= 0;
    if (!nreset) begin
        direction <= 0;
        motor_on <= 0;
        mfm_mode <= 1;
        switched <= 0;
        ejected <= 0;
        eject_request <= 0;
        mounted_d <= 0;
        hd_d <= 0;
        selected_d <= 0;
        strobe_d <= 0;
        track <= 0;
        side <= 0;
    end else if (ce) begin
        mounted_d <= mounted;
        hd_d <= media_hd;
        selected_d <= selected;
        strobe_d <= phase[3];

        if (!mounted) begin
            ejected <= 0;
            eject_request <= 0;
        end
        if (mounted_d && !mounted) switched <= 1;
        if (side_select) side <= read_addr[0];

        if (command_strobe) begin
            case (command)
                0: direction <= 0;
                4: direction <= 1;
                1: if (step_moves) track <= direction ? track - 7'd1 : track + 7'd1;
                2: motor_on <= 1;
                6: motor_on <= 0;
                7: if (loaded) eject_request <= 1;
                9: mfm_mode <= 1;
                12: if (!(mounted_d && !mounted)) switched <= 0;
                13: mfm_mode <= 0;
                default: ;
            endcase
        end
        if (eject_accept) begin
            ejected <= 1;
            switched <= 1;
            eject_request <= 0;
            eject_done <= 1;
        end
    end
end

endmodule
