const llvm = @import("llvm");

const types = llvm.types;
const core = llvm.core;

const Module = types.LLVMModuleRef;
const Context = types.LLVMContextRef;
const Value = types.LLVMValueRef;

pub const StubKind = enum {
    get_i8,
    set_i8,

    get_i16,
    set_i16,

    get_i32,
    set_i32,

    get_i64,
    set_i64,

    get_f32,
    set_f32,

    get_f64,
    set_f64,

    memory_size,
    memory_grow,
};

pub const Stubs = struct {
    const cache_size = @typeInfo(StubKind).@"enum".fields.len;

    module: Module,
    ctx: Context,
    cache: [cache_size]?Value = [_]?Value{null} ** cache_size,

    pub fn init(module: Module, ctx: Context) Stubs {
        return .{
            .module = module,
            .ctx = ctx,
        };
    }

    pub fn get(self: *Stubs, comptime kind: StubKind) Value {
        const idx = @intFromEnum(kind);
        if (self.cache[idx]) |stub| return stub;
        const stub = self.createStub(kind);
        self.cache[idx] = stub;
        return stub;
    }

    fn createStub(self: *Stubs, comptime kind: StubKind) types.LLVMValueRef {
        const name = @tagName(kind);
        const void_ty = core.LLVMVoidTypeInContext(self.ctx);

        const i8_ty = core.LLVMInt8TypeInContext(self.ctx);
        const i16_ty = core.LLVMInt16TypeInContext(self.ctx);
        const i32_ty = core.LLVMInt32TypeInContext(self.ctx);
        const i64_ty = core.LLVMInt64TypeInContext(self.ctx);
        const f32_ty = core.LLVMFloatTypeInContext(self.ctx);
        const f64_ty = core.LLVMDoubleTypeInContext(self.ctx);

        const ptr_ty = core.LLVMPointerType(
            core.LLVMInt8TypeInContext(self.ctx),
            0,
        );

        const func_type = switch (kind) {
            .get_i8,
            .get_i16,
            .get_i32,
            => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty };
                break :blk core.LLVMFunctionType(i32_ty, &params, 2, 0);
            },

            .get_i64 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty };
                break :blk core.LLVMFunctionType(i64_ty, &params, 2, 0);
            },

            .get_f32 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty };
                break :blk core.LLVMFunctionType(f32_ty, &params, 2, 0);
            },

            .get_f64 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty };
                break :blk core.LLVMFunctionType(f64_ty, &params, 2, 0);
            },

            .set_i8 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty, i8_ty };
                break :blk core.LLVMFunctionType(void_ty, &params, 3, 0);
            },

            .set_i16 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty, i16_ty };
                break :blk core.LLVMFunctionType(void_ty, &params, 3, 0);
            },

            .set_i32 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty, i32_ty };
                break :blk core.LLVMFunctionType(void_ty, &params, 3, 0);
            },

            .set_i64 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty, i64_ty };
                break :blk core.LLVMFunctionType(void_ty, &params, 3, 0);
            },

            .set_f32 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty, f32_ty };
                break :blk core.LLVMFunctionType(void_ty, &params, 3, 0);
            },

            .set_f64 => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty, f64_ty };
                break :blk core.LLVMFunctionType(void_ty, &params, 3, 0);
            },

            .memory_size => blk: {
                var params = [_]types.LLVMTypeRef{ptr_ty};
                break :blk core.LLVMFunctionType(i32_ty, &params, 1, 0);
            },

            .memory_grow => blk: {
                var params = [_]types.LLVMTypeRef{ ptr_ty, i32_ty };
                break :blk core.LLVMFunctionType(i32_ty, &params, 2, 0);
            },
        };

        const func = core.LLVMAddFunction(self.module, name.ptr, func_type);
        core.LLVMSetLinkage(func, types.LLVMLinkage.LLVMExternalLinkage);
        return func;
    }
};
