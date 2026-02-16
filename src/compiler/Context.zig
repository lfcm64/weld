const Context = @This();

const std = @import("std");
const llvm = @import("llvm");

const Intrinsics = @import("codegen/intrinsics.zig").Intrinsics;
const Stubs = @import("codegen/stubs.zig").Stubs;

const types = llvm.types;
const core = llvm.core;
const orc = llvm.orc;

const Allocator = std.mem.Allocator;
const Value = types.LLVMValueRef;
const Type = types.LLVMTypeRef;

pub const Symbol = union(enum) {
    global: u32,
    function: u32,
};
pub const SymbolRegistry = std.AutoHashMapUnmanaged(Symbol, Value);

pub const CompilerCounts = struct {
    imported_funcs: u32 = 0,
};

allocator: Allocator,

module: types.LLVMModuleRef,
context: types.LLVMContextRef,

registry: SymbolRegistry = .{},
functypes: std.ArrayList(Type) = .{},

intrinsics: Intrinsics,
stubs: Stubs,

counts: CompilerCounts = .{},

pub fn init(allocator: Allocator, tsctx: orc.LLVMOrcThreadSafeContextRef) !Context {
    const ctx = orc.LLVMOrcThreadSafeContextGetContext(tsctx);
    errdefer core.LLVMContextDispose(ctx);

    const module = core.LLVMModuleCreateWithNameInContext("", ctx);
    errdefer core.LLVMDisposeModule(module);

    return .{
        .allocator = allocator,
        .module = module,
        .context = ctx,
        .intrinsics = Intrinsics.init(module, ctx),
        .stubs = Stubs.init(module, ctx),
    };
}

pub fn deinit(self: *Context) void {
    self.functypes.deinit(self.allocator);
    self.registry.deinit(self.allocator);
}
