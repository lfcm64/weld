const std = @import("std");
const llvm = @import("llvm");
const wasm = @import("wasm");

const core = llvm.core;
const types = llvm.types;

const Allocator = std.mem.Allocator;

const ValType = wasm.types.ValType;
const FuncType = wasm.types.FuncType;
const BlockType = wasm.instr.BlockType;

pub fn typeToLLVM(ty: ValType, context: types.LLVMContextRef) types.LLVMTypeRef {
    return switch (ty) {
        .i32 => core.LLVMInt32TypeInContext(context),
        .i64 => core.LLVMInt64TypeInContext(context),
        .f32 => core.LLVMFloatTypeInContext(context),
        .f64 => core.LLVMDoubleTypeInContext(context),
    };
}

pub fn blockTypeToPhi(block_type: BlockType, context: types.LLVMContextRef, builder: types.LLVMBuilderRef) ?types.LLVMValueRef {
    const val_ty = if (block_type == .valtype) block_type.valtype else return null;

    const llvm_ty = switch (val_ty) {
        .i32 => core.LLVMInt32TypeInContext(context),
        .i64 => core.LLVMInt64TypeInContext(context),
        .f32 => core.LLVMFloatTypeInContext(context),
        .f64 => core.LLVMDoubleTypeInContext(context),
    };
    return core.LLVMBuildPhi(builder, llvm_ty, "");
}

pub fn funcTypeToLLVM(allocator: Allocator, func_type: FuncType, context: types.LLVMContextRef) !types.LLVMTypeRef {
    const param_count = func_type.params.len;

    const param_types = try allocator.alloc(types.LLVMTypeRef, param_count + 1);
    defer allocator.free(param_types);

    param_types[0] = core.LLVMPointerTypeInContext(context, 0);
    for (0..param_count) |i| param_types[i + 1] = typeToLLVM(func_type.params[i], context);

    if (func_type.results.len > 1) @panic("compiler does not support multi return function");
    const return_type = switch (func_type.results.len) {
        0 => core.LLVMVoidTypeInContext(context),
        else => typeToLLVM(func_type.results[0], context),
    };

    return core.LLVMFunctionType(
        return_type,
        param_types.ptr,
        @intCast(param_types.len),
        0,
    );
}
