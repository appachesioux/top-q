/// UI modes. US1 only uses `.list` and `.help`; US2/US3/US4 will extend.
pub const Mode = enum {
    list,
    detail, // reserved for US2
    filter_input, // reserved for US3
    signal_confirm, // reserved for US4
    help,
};
