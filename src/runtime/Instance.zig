const Instance = @This();

const std = @import("std");
const llvm = @import("llvm");
const wasm = @import("wasm");

const Vm = @import("vm.zig");

const Module = @import("../Module.zig");
const Ast = @import("../parser/Ast.zig");

const orc = llvm.orc;
const jit = llvm.jit;
const errors = llvm.errors;

const Allocator = std.mem.Allocator;

allocator: Allocator,
module: Module,
vm: Vm.VmContext,

pub fn init(allocator: Allocator, module: Module) !Instance {
    const es = jit.LLVMOrcLLJITGetExecutionSession(module.code.lljit);

    const flags = orc.LLVMJITSymbolFlags{
        .GenericFlags = @intFromEnum(orc.LLVMJITSymbolGenericFlags.LLVMJITSymbolGenericFlagsExported) |
            @intFromEnum(orc.LLVMJITSymbolGenericFlags.LLVMJITSymbolGenericFlagsCallable),
        .TargetFlags = 0,
    };

    var pairs = [_]orc.LLVMOrcCSymbolMapPair{
        .{ .Name = orc.LLVMOrcExecutionSessionIntern(es, "get_i8"), .Sym = .{ .Address = @intFromPtr(&Vm.get_i8), .Flags = flags } },
        .{ .Name = orc.LLVMOrcExecutionSessionIntern(es, "set_i8"), .Sym = .{ .Address = @intFromPtr(&Vm.set_i8), .Flags = flags } },
        .{ .Name = orc.LLVMOrcExecutionSessionIntern(es, "get_i16"), .Sym = .{ .Address = @intFromPtr(&Vm.get_i16), .Flags = flags } },
        .{ .Name = orc.LLVMOrcExecutionSessionIntern(es, "set_i16"), .Sym = .{ .Address = @intFromPtr(&Vm.set_i16), .Flags = flags } },
    };

    const mu = orc.LLVMOrcAbsoluteSymbols(&pairs, pairs.len);
    const err = orc.LLVMOrcJITDylibDefine(module.code.dylib, mu);
    if (err != null) {
        errors.LLVMConsumeError(err);
        return error.LlvmError;
    }

    return .{
        .allocator = allocator,
        .module = module,
        .vm = try Vm.VmContext.init(allocator, module.parsed),
    };
}

pub fn deinit(self: *Instance) void {
    self.vm.deinit();
}

pub fn getFunction(self: *Instance, comptime name: [:0]const u8, comptime Fn: type) !Fn {
    var addr: orc.LLVMOrcExecutorAddress = 0;
    const err = jit.LLVMOrcLLJITLookup(self.module.code.lljit, &addr, name.ptr);
    if (err != null) {
        errors.LLVMConsumeError(err);
        return error.LlvmError;
    }

    return @ptrFromInt(addr);
}
