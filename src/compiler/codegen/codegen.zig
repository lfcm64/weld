const std = @import("std");
const wasm = @import("wasm");
const llvm = @import("llvm");

const conv = @import("conversions.zig");
const code = @import("code.zig");

const Context = @import("../Context.zig");
const Ast = @import("../../parser/Ast.zig");

const types = llvm.types;
const core = llvm.core;

const Allocator = std.mem.Allocator;

pub const CodegenBuilder = struct {
    ctx: *Context,

    pub fn visitor(self: *CodegenBuilder) Ast.Visitor {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .visitType = compileType,
                .visitFunc = compileFunc,
                .visitCode = compileCode,
                .visitExport = compileExport,
            },
        };
    }

    pub fn finish(self: *CodegenBuilder) types.LLVMModuleRef {
        self.ctx.deinit();
        return self.ctx.module;
    }

    fn compileType(ptr: *anyopaque, functype: wasm.types.FuncType, _: u32) !void {
        const self: *CodegenBuilder = @ptrCast(@alignCast(ptr));
        try self.ctx.functypes.append(
            self.ctx.allocator,
            try conv.funcTypeToLLVM(
                self.ctx.allocator,
                functype,
                self.ctx.context,
            ),
        );
    }

    fn compileFunc(ptr: *anyopaque, type_idx: u32, _: u32) !void {
        const self: *CodegenBuilder = @ptrCast(@alignCast(ptr));
        const functype = self.ctx.functypes.items[type_idx];
        const func = core.LLVMAddFunction(self.ctx.module, "", functype);
        try self.ctx.funcs.append(self.ctx.allocator, func);
    }

    fn compileCode(ptr: *anyopaque, body: wasm.types.FuncBody, idx: u32) !void {
        const self: *CodegenBuilder = @ptrCast(@alignCast(ptr));
        const func = self.ctx.funcs.items[idx - self.ctx.counts.imported_funcs];
        try code.CodeCompiler.compile(self.ctx, func, body);
    }

    fn compileExport(ptr: *anyopaque, exp: wasm.types.Export, _: u32) !void {
        const self: *CodegenBuilder = @ptrCast(@alignCast(ptr));
        switch (exp.kind) {
            .func => |func_idx| {
                const func = self.ctx.funcs.items[func_idx];
                core.LLVMSetLinkage(func, types.LLVMLinkage.LLVMExternalLinkage);
                core.LLVMSetValueName2(func, @ptrCast(exp.name), exp.name.len);
            },
            else => {},
        }
    }
};
