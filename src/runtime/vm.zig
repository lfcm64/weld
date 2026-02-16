const std = @import("std");
const wasm = @import("wasm");

const Ast = @import("../parser/Ast.zig");

const Allocator = std.mem.Allocator;

pub const Memory = []u8;
pub const Global = u64;
pub const Table = []?u32;

pub const VmContext = struct {
    allocator: Allocator,
    memories: []Memory,
    globals: []Global,
    tables: []Table,

    pub fn init(allocator: Allocator, ast: Ast) !VmContext {
        var builder = VmContextBuilder.init(allocator);
        try ast.traverse(builder.visitor());
        return builder.build();
    }

    pub fn deinit(self: *VmContext) void {
        for (self.memories) |m| self.allocator.free(m);
        self.allocator.free(self.memories);
        self.allocator.free(self.globals);
        for (self.tables) |t| self.allocator.free(t);
        self.allocator.free(self.tables);
    }
};

pub const VmContextBuilder = struct {
    allocator: Allocator,
    memories: std.ArrayList(Memory) = .{},
    globals: std.ArrayList(Global) = .{},
    tables: std.ArrayList(Table) = .{},

    pub fn init(allocator: Allocator) VmContextBuilder {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VmContextBuilder) void {
        for (self.memories.items) |m| self.allocator.free(m);
        self.memories.deinit();
        self.globals.deinit();
        for (self.tables.items) |t| self.allocator.free(t);
        self.tables.deinit();
    }

    pub fn visitor(self: *VmContextBuilder) Ast.Visitor {
        return .{
            .ptr = self,
            .vtable = &.{
                .visitMemory = visitMemory,
                .visitGlobal = visitGlobal,
                .visitTable = visitTable,
                .visitElem = visitElem,
                .visitData = visitData,
            },
        };
    }

    fn visitMemory(ptr: *anyopaque, mem: wasm.types.Memory, _: u32) !void {
        const self: *VmContextBuilder = @ptrCast(@alignCast(ptr));
        const pages = mem.min;
        const data = try self.allocator.alloc(u8, pages * 65536);
        @memset(data, 0);
        try self.memories.append(self.allocator, data);
    }

    fn visitGlobal(ptr: *anyopaque, global: wasm.types.Global, _: u32) !void {
        const self: *VmContextBuilder = @ptrCast(@alignCast(ptr));
        const value: Global = switch (global.init_expr) {
            .i32 => |v| @bitCast(@as(i64, v)),
            .i64 => |v| @bitCast(v),
            .f32 => |v| @bitCast(@as(f64, v)),
            .f64 => |v| @bitCast(v),
            else => 0,
        };
        try self.globals.append(self.allocator, value);
    }

    fn visitTable(ptr: *anyopaque, table: wasm.types.Table, _: u32) !void {
        const self: *VmContextBuilder = @ptrCast(@alignCast(ptr));
        const slots = try self.allocator.alloc(?u32, table.limits.min);
        @memset(slots, null);
        try self.tables.append(self.allocator, slots);
    }

    fn visitData(ptr: *anyopaque, data: wasm.types.Segment, _: u32) !void {
        const self: *VmContextBuilder = @ptrCast(@alignCast(ptr));
        const offset: u32 = switch (data.offset) {
            .i32 => |v| @intCast(v),
            else => return error.UnsupportedOffsetExpr,
        };
        if (data.mem_idx >= self.memories.items.len) return error.UnknownMemory;
        const mem = self.memories.items[data.mem_idx];
        if (offset + data.bytes.len > mem.len) return error.DataSegmentOutOfBounds;
        @memcpy(mem[offset..][0..data.bytes.len], data.bytes);
    }

    fn visitElem(ptr: *anyopaque, elem: wasm.types.Element, _: u32) !void {
        const self: *VmContextBuilder = @ptrCast(@alignCast(ptr));
        const offset: u32 = switch (elem.offset) {
            .i32 => |v| @intCast(v),
            else => return error.UnsupportedOffsetExpr,
        };
        if (elem.table_idx >= self.tables.items.len) return error.UnknownTable;
        const table = self.tables.items[elem.table_idx];

        var it = elem.indices.iter();
        var i: u32 = 0;

        while (try it.next()) |func_idx| : (i += 1) {
            const slot = offset + i;
            if (slot >= table.len) return error.ElemSegmentOutOfBounds;
            table[slot] = func_idx;
        }
    }

    pub fn build(self: *VmContextBuilder) !VmContext {
        return VmContext{
            .allocator = self.allocator,
            .memories = try self.memories.toOwnedSlice(self.allocator),
            .globals = try self.globals.toOwnedSlice(self.allocator),
            .tables = try self.tables.toOwnedSlice(self.allocator),
        };
    }
};

pub fn get_i8(vm: *VmContext, offset: u32) callconv(.c) i8 {
    const mem = vm.memories[0];
    if (offset + 1 > mem.len) @panic("memory access out of bounds");
    return @intCast(mem[offset]);
}

pub fn set_i8(vm: *VmContext, offset: u32, value: i8) callconv(.c) void {
    const mem = vm.memories[0];
    if (offset + 1 > mem.len) @panic("memory access out of bounds");
    mem[offset] = @bitCast(value);
}

pub fn get_i16(vm: *VmContext, offset: u32) callconv(.c) i16 {
    const mem = vm.memories[0];
    if (offset + 2 > mem.len) @panic("memory access out of bounds");
    return std.mem.readInt(i16, mem[offset..][0..2], .little);
}

pub fn set_i16(vm: *VmContext, offset: u32, value: i16) callconv(.c) void {
    const mem = vm.memories[0];
    if (offset + 2 > mem.len) @panic("memory access out of bounds");
    std.mem.writeInt(i16, mem[offset..][0..2], value, .little);
}
