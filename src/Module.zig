const Module = @This();

const std = @import("std");
const llvm = @import("llvm");

const types = llvm.types;
const orc = llvm.orc;

const parser = @import("parser/parser.zig");
const Ast = @import("parser/Ast.zig");

const Validator = @import("validator/Validator.zig");
const Compiler = @import("compiler/Compiler.zig");

const Allocator = std.mem.Allocator;

parsed: Ast,
code: Compiler.Code,

pub fn init(allocator: Allocator, source: []const u8) !Module {
    const parsed = try parser.parseAll(source);

    const validator = Validator{};
    try validator.validate(allocator, parsed);

    const compiler = Compiler{};
    const code = try compiler.compile(allocator, parsed);

    return .{
        .parsed = parsed,
        .code = code,
    };
}

pub fn deinit(_: Module) void {}
