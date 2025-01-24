const std = @import("std");
const c = @import("std").c;

const pg = @cImport({
    @cInclude("postgres.h");
    @cInclude("fmgr.h");
    @cInclude("utils/builtins.h");
});

const PG_FUNCTION_ARGS = c.pointer;

const Datum = c.pointer;
const PG_RETURN_TEXT_P = pg.PG_RETURN_TEXT_P;

pub fn hello_world(ctx: PG_FUNCTION_ARGS) Datum {
    _ = ctx;
    const text = "Hello, World from Zig PostgreSQL Extension!";
    return PG_RETURN_TEXT_P(pg.cstring_to_text(text));
}

pub fn _PG_init() void {
    // Register the function with PostgreSQL
    pg.PG_FUNCTION_INFO_V1(hello_world);
}
