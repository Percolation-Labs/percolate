//this build process simply 0
// const std = @import("std");

// pub fn main() !void {
//     const stdout = std.io.getStdOut().writer();
//     try stdout.print("Hello, Zig!\n", .{});
// }

//check imports 1
// const std = @import("std");
// const c = @cImport({
//     @cInclude("postgres.h");
//     @cInclude("fmgr.h");
// });

// pub fn main() void {
//     std.debug.print("PostgreSQL headers imported successfully!\n", .{});
// }

////////////////////////
/// 
const std = @import("std");
const c = @cImport({
    @cInclude("postgres.h");
    @cInclude("fmgr.h");
    @cInclude("utils/builtins.h");
});

////////
// Define the PostgreSQL magic struct
pub const Pg_magic_struct = extern struct {
    len: u32,
    version: u32,
    funcmaxargs: u32,
    indexmaxkeys: u32,
    namedatalen: u32,
    float4byval: u32,
    float8byval: u32,
};

// Export the magic block (PostgreSQL requires this)
export var PG_MODULE_MAGIC_DATA: Pg_magic_struct = Pg_magic_struct{
    .len = @sizeOf(Pg_magic_struct),
    .version = 130002, // Adjust this based on your PostgreSQL version
    .funcmaxargs = 100,
    .indexmaxkeys = 32,
    .namedatalen = 64,
    .float4byval = 1,
    .float8byval = 1,
};

// PostgreSQL expects this function symbol
export fn PG_MAGIC_FUNCTION_NAME() *Pg_magic_struct {
    return &PG_MODULE_MAGIC_DATA;
}


export fn _PG_init() void {
    
}

// Simple function returning a text string
export fn hello_world(fcinfo: *c.FunctionCallInfoBaseData) c.Datum {
    _ = fcinfo; // Unused
    return c.Int32GetDatum(42);
    // mv libp8.dylib /usr/local/opt/postgresql@16/lib/ & chmod 755 /usr/local/opt/postgresql@16/lib/libp8.dylib
}
// const std = @import("std");
// const c = @cImport({
//     @cInclude("postgres.h");

//     @cInclude("utils/builtins.h");
// });

// export fn _PG_init() void {}

// export fn hello_world(fcinfo: *c.FunctionCallInfoBaseData) c.Datum {
//     const name_datum = c.PG_GETARG_DATUM(fcinfo, 0);
//     const name_cstr = c.TextDatumGetCString(name_datum);
//     const name = std.mem.span(name_cstr); // Corrected usage

//     // Use PostgreSQL's memory allocation
//     const buffer = c.palloc(64) orelse return c.CStringGetTextDatum("Memory allocation failed");
//     _ = std.fmt.bufPrint(buffer[0..64], "Hello, {}!", .{name}) catch return c.CStringGetTextDatum("Formatting error");

//     return c.CStringGetTextDatum(buffer);
// }
