const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "scratchcc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scratchcc.zig"),
            .target = b.graph.host,
        }),
    });

    const mecha = b.dependency("mecha", .{});
    exe.root_module.addImport("mecha", mecha.module("mecha"));

    b.installArtifact(exe);
}
