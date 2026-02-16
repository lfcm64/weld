const Compiler = @This();

const std = @import("std");
const wasm = @import("wasm");
const llvm = @import("llvm");

const Ast = @import("../parser/Ast.zig");
const Context = @import("Context.zig");
const CodegenBuilder = @import("codegen/codegen.zig").CodegenBuilder;

const types = llvm.types;
const orc = llvm.orc;
const jit = llvm.jit;
const errors = llvm.errors;

const Allocator = std.mem.Allocator;

pub const Config = struct {};

config: Config = .{},

pub const Code = struct {
    lljit: types.LLVMOrcLLJITRef,
    dylib: orc.LLVMOrcJITDylibRef,
};

pub fn compile(_: Compiler, allocator: Allocator, ast: Ast) !Code {
    _ = llvm.target.LLVMInitializeNativeTarget();
    _ = llvm.target.LLVMInitializeNativeAsmPrinter();
    _ = llvm.target.LLVMInitializeNativeAsmParser();

    const tsctx = orc.LLVMOrcCreateNewThreadSafeContext();
    defer orc.LLVMOrcDisposeThreadSafeContext(tsctx);

    var ctx = try Context.init(allocator, tsctx);

    var builder = CodegenBuilder{ .ctx = &ctx };
    try ast.traverse(builder.visitor());

    const llvm_mod = builder.finish();

    const jit_builder = jit.LLVMOrcCreateLLJITBuilder();

    var lljit: types.LLVMOrcLLJITRef = null;
    const create_err = jit.LLVMOrcCreateLLJIT(&lljit, jit_builder);
    if (create_err != null) {
        errors.LLVMConsumeError(create_err);
        return error.LlvmError;
    }
    errdefer _ = jit.LLVMOrcDisposeLLJIT(lljit);

    const tsm = orc.LLVMOrcCreateNewThreadSafeModule(llvm_mod, tsctx);
    const dylib = jit.LLVMOrcLLJITGetMainJITDylib(lljit);

    const add_err = jit.LLVMOrcLLJITAddLLVMIRModule(lljit, dylib, tsm);
    if (add_err != null) {
        errors.LLVMConsumeError(add_err);
        return error.LlvmError;
    }

    return Code{
        .lljit = lljit,
        .dylib = dylib,
    };
}
