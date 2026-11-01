// LC040-only words in unused ROM slots. Keep generated donor tables intact.
if (!HAS_FPU) begin
    lc_word = '0;
    lc_word.op = OP_FPU; lc_word.sz = 3; lc_word.msz = 3;
    // CHK must not redirect before the EA/trap micro-op.
    lc_word.a = S_EXT1; lc_word.b = S_OPW;
    urom[LC_ENTRY] = lc_word;
    lc_word.a = S_ZERO; lc_word.b = S_FPDL; lc_word.cond = 15;
    lc_word.ag = AGM_LEA0; lc_word.last = 1;
    urom[LC_EA] = lc_word;

    lc_word = uword_t'(urom[UA_EXC_FMT2]);
    lc_word.a = 6'd48; // T5: faulting instruction PC
    urom[LC_FMT4] = lc_word;
    lc_word = uword_t'(urom[UA_EXC_FMT2]); lc_word.cval = 16'hFFF8;
    urom[LC_FMT4 + 1] = lc_word;
    lc_word = uword_t'(urom[UA_EXC_FMT2 + 1]); lc_word.cval = 16'hFFF6;
    urom[LC_FMT4 + 2] = lc_word;
    lc_word = uword_t'(urom[UA_EXC_FMT2 + 2]); lc_word.cval = 16'hFFF2;
    urom[LC_FMT4 + 3] = lc_word;
    lc_word = uword_t'(urom[UA_EXC_FMT2 + 3]); lc_word.cval = 16'hFFF0;
    urom[LC_FMT4 + 4] = lc_word;
    urom[LC_FMT4 + 5] = urom[UA_EXC_FMT2 + 4];
end
