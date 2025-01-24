const std = @import("std");
 
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
 

    const openssl_dep = b.dependency("openssl", .{
        .target = target,
        .optimize = optimize,
    });
    const libcrypto = openssl_dep.artifact("crypto");
    const libssl = openssl_dep.artifact("ssl");



    const so = b.addSharedLibrary(.{       
        .name = "hello_world",
        .root_source_file = b.path("src/hello_world.zig"),
        .target = target,
        .optimize = optimize, 
        .version = .{ .major = 1, .minor = 2, .patch = 3 },  
    });

    for(libcrypto.root_module.include_dirs.items) |include_dir| {
        try so.root_module.include_dirs.append(b.allocator, include_dir);
    }


    //exe.setBuildMode(mode);

    so.linkLibrary(libssl);
    so.linkLibrary(libcrypto); 

    b.installArtifact(so);

    //const sql = b.addInstallFile("sql/hello_world.sql", "share/postgresql/extension/hello_world.sql");
    //b.installArtifact(sql);
}
