const Validator = @This();

const std = @import("std");
const wasm = @import("wasm");
const code = @import("code.zig");

const Ast = @import("../parser/Ast.zig");
const Context = @import("Context.zig");

const types = wasm.types;
const indices = wasm.indices;

const Allocator = std.mem.Allocator;

pub const Config = struct {};

config: Config = .{},

pub fn validate(self: *const Validator, allocator: Allocator, ast: Ast) !void {
    var ctx = Context.init(allocator);
    defer ctx.deinit();

    var vv = ValidationVisitor{ .ctx = &ctx, .config = self.config };
    try ast.traverse(vv.visitor());
}

const ValidationVisitor = struct {
    ctx: *Context,
    config: Config,

    pub fn visitor(self: *ValidationVisitor) Ast.Visitor {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .visitType = visitType,
                .visitImport = visitImport,
                .visitFunc = visitFunc,
                .visitTable = visitTable,
                .visitMemory = visitMemory,
                .visitGlobal = visitGlobal,
                .visitExport = visitExport,
                .visitStart = visitStart,
                .visitElem = visitElem,
                .visitCode = visitCode,
                .visitData = visitData,
            },
        };
    }

    fn visitType(ptr: *anyopaque, ty: types.FuncType, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        try self.ctx.addFuncType(ty);
    }

    fn visitImport(ptr: *anyopaque, import: types.Import, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        switch (import.desc) {
            .func => |type_idx| if (type_idx >= self.ctx.functypes.items.len) return error.FuncIndexOutOfBounds,
            .table => |table| try verifyTable(table),
            .memory => |mem| try verifyMemory(mem),
            .global => |global_ty| if (global_ty.mut != .@"const") return error.ImportedGlobalMustBeImmutable,
        }
        try self.ctx.addImport(import);
    }

    fn visitFunc(ptr: *anyopaque, type_idx: indices.Func, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        if (type_idx >= self.ctx.functypes.items.len) return error.FuncIndexOutOfBounds;
        try self.ctx.addFunc(type_idx);
    }

    fn visitTable(ptr: *anyopaque, table: types.Table, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        try verifyTable(table);
        try self.ctx.addTable(table);
    }

    fn visitMemory(ptr: *anyopaque, mem: types.Memory, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        try verifyMemory(mem);
        try self.ctx.addMemory(mem);
    }

    fn visitGlobal(ptr: *anyopaque, global: types.Global, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        try validateConstExpr(self.ctx, global.init_expr, global.ty.valtype);
        try self.ctx.addGlobal(global);
    }

    fn visitExport(ptr: *anyopaque, exp: types.Export, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        switch (exp.kind) {
            .func => |func_idx| if (func_idx >= self.ctx.funcs.items.len) return error.ExportFuncIndexOutOfBounds,
            .table => |table_idx| if (table_idx >= self.ctx.tables.items.len) return error.ExportTableIndexOutOfBounds,
            .memory => |mem_idx| if (mem_idx >= self.ctx.memories.items.len) return error.ExportMemoryIndexOutOfBounds,
            .global => |global_idx| if (global_idx >= self.ctx.globals.items.len) return error.ExportGlobalIndexOutOfBounds,
        }
        try self.ctx.addExport(exp);
    }

    fn visitStart(ptr: *anyopaque, start: wasm.indices.Func) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        if (start >= self.ctx.funcs.items.len) return error.StartFuncIndexOutOfBounds;
    }

    fn visitElem(ptr: *anyopaque, elem: types.Element, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        if (elem.table_idx >= self.ctx.tables.items.len) return error.TableIndexOutOfBounds;
        try validateConstExpr(self.ctx, elem.offset, .i32);

        const func_count = self.ctx.funcs.items.len;
        var it = elem.indices.iter();
        while (try it.next()) |func_idx| {
            if (func_idx >= func_count) return error.ElementFuncIndexOutOfBounds;
        }
    }

    fn visitCode(ptr: *anyopaque, body: types.FuncBody, idx: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        try code.validateCode(self.ctx, body, idx);
    }

    fn visitData(ptr: *anyopaque, data: types.Segment, _: u32) !void {
        const self: *ValidationVisitor = @ptrCast(@alignCast(ptr));
        if (data.mem_idx >= self.ctx.memories.items.len) return error.MemoryIndexOutOfBounds;
        try validateConstExpr(self.ctx, data.offset, .i32);
    }

    fn validateConstExpr(ctx: *Context, expr: types.Expr, expected_type: types.ValType) !void {
        switch (expr) {
            .i32 => if (expected_type != .i32) return error.ConstExprTypeMismatch,
            .i64 => if (expected_type != .i64) return error.ConstExprTypeMismatch,
            .f32 => if (expected_type != .f32) return error.ConstExprTypeMismatch,
            .f64 => if (expected_type != .f64) return error.ConstExprTypeMismatch,
            .global => |global_idx| {
                if (global_idx >= ctx.imported_globals) return error.ConstExprReferencesNonImportedGlobal;

                const global = ctx.globals.items[global_idx];
                if (global.mut != .@"const") return error.ConstExprReferenceMutableGlobal;
                if (global.valtype != expected_type) return error.ConstExprTypeMismatch;
            },
        }
    }

    fn verifyTable(table: types.Table) !void {
        if (table.limits.max) |max| {
            if (table.limits.min > max) return error.InvalidTableLimits;
        }
    }

    fn verifyMemory(mem: types.Memory) !void {
        if (mem.max) |max| {
            if (mem.min > max) return error.InvalidMemoryLimits;
        }
    }
};
