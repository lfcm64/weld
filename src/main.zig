const std = @import("std");

const Module = @import("Module.zig");
const Instance = @import("runtime/Instance.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const source = @embedFile("tests/add.wasm");

    const module = try Module.init(allocator, source);
    defer module.deinit();

    var instance = try Instance.init(allocator, module);
    defer instance.deinit();

    const add = try instance.getFunction(
        "add",
        *const fn (*anyopaque, i32, i32) callconv(.c) i32,
    );

    const result = add(@ptrCast(&instance.vm), 10, 2);
    std.debug.print("{}\n", .{result});
}
