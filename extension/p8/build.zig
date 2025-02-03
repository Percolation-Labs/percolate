const std = @import("std");

pub fn build(b: *std.Build) void {
     const target = b.standardTargetOptions(.{});
     const mode = b.standardOptimizeOption(.{});

     const l = b.addSharedLibrary(.{
         .name = "p8",
        .root_source_file = b.path("src/p8.zig"),
        .target = target,
        .optimize = mode,
    });

    // Link against OpenSSL and crypto
    const openssl_dep = b.dependency("openssl", .{
        .target = target,
        .optimize = mode,
    });

    const libcrypto = openssl_dep.artifact("crypto");
    const libssl = openssl_dep.artifact("ssl");

    for (libcrypto.root_module.include_dirs.items) |include_dir| {
        l.root_module.include_dirs.append(b.allocator, include_dir) catch unreachable;
    }

    // postgres lives here /usr/local/opt/libpq/include/postgresql/server

    l.addIncludePath(.{ .cwd_relative = "/usr/local/opt/libpq/include/postgresql/server" });
    l.addIncludePath(.{ .cwd_relative = "/usr/local/opt/postgresql@16/include" });
    l.addLibraryPath(.{ .cwd_relative = "/usr/local/opt/postgresql@16/lib" });
    
    l.linkSystemLibrary("libpq");
    

    l.linkLibrary(libssl);
    l.linkLibrary(libcrypto);
 
    b.installArtifact(l);
    //#zig build -freference-trace
}
