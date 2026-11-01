proc generate_video_startup_guard {root output_dir} {
    set input [open [file join $root sys sysmem.sv] r]
    set rtl [read $input]
    close $input

    set anchor {f2sdram_safe_terminator #(128, 8) f2sdram_safe_terminator_vbuf}
    set guard {
// Keep the scaler port closed until 32 clocks after initial reset release.
// Stay open on later resets so the stock terminator can finish bursts.
reg       vbuf_open = 1'b0;
reg [4:0] vbuf_open_cnt = 5'd0;
always @(posedge vbuf_clk) begin
    if (vbuf_reset_1) begin
        if (!vbuf_open) vbuf_open_cnt <= 5'd0;
    end
    else if (!vbuf_open) begin
        vbuf_open_cnt <= vbuf_open_cnt + 5'd1;
        if (&vbuf_open_cnt) vbuf_open <= 1'b1;
    end
end
wire vbuf_waitrequest_t;
assign vbuf_waitrequest = vbuf_waitrequest_t | ~vbuf_open;

}
    set replacements [list \
        $anchor "$guard$anchor" \
        {(vbuf_waitrequest),} {(vbuf_waitrequest_t),} \
        {(vbuf_read),} {(vbuf_read & vbuf_open),} \
        {(vbuf_write)} {(vbuf_write & vbuf_open)}]
    foreach {before after} $replacements {
        if {[string first $before $rtl] < 0 ||
            [string first $before $rtl] != [string last $before $rtl]} {
            error "Video startup guard: expected exactly one occurrence of $before"
        }
    }
    set rtl [string map $replacements $rtl]
    file mkdir $output_dir
    set path [file join $output_dir sysmem_video_startup.sv]
    set output [open $path w]
    fconfigure $output -translation lf
    puts -nonewline $output $rtl
    close $output
    return $path
}
