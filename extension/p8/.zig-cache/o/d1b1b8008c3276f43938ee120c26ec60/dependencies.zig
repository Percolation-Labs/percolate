pub const packages = struct {
    pub const @"1220162cad408b6f7eeb6b49733e75ebdb684da77d15bc24d04114b8aaaaa4d7ded6" = struct {
        pub const build_root = "/Users/sirsh/.cache/zig/p/1220162cad408b6f7eeb6b49733e75ebdb684da77d15bc24d04114b8aaaaa4d7ded6";
        pub const build_zig = @import("1220162cad408b6f7eeb6b49733e75ebdb684da77d15bc24d04114b8aaaaa4d7ded6");
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "openssl", "1220162cad408b6f7eeb6b49733e75ebdb684da77d15bc24d04114b8aaaaa4d7ded6" },
};
