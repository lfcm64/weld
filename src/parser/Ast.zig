const Ast = @This();

const std = @import("std");
const wasm = @import("wasm");

const Section = wasm.sections.Section;

magic: u32 = 0,
version: u32 = 0,

types: ?Section(.type) = null,
imports: ?Section(.import) = null,
funcs: ?Section(.func) = null,
tables: ?Section(.table) = null,
memory: ?Section(.memory) = null,
globals: ?Section(.global) = null,
exports: ?Section(.@"export") = null,
start: ?Section(.start) = null,
elems: ?Section(.elem) = null,
code: ?Section(.code) = null,
data: ?Section(.data) = null,

custom_section_num: u32 = 0,

pub const Visitor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        visitType: ?*const fn (ptr: *anyopaque, ty: wasm.types.FuncType, idx: u32) anyerror!void = null,
        visitImport: ?*const fn (ptr: *anyopaque, import: wasm.types.Import, idx: u32) anyerror!void = null,
        visitFunc: ?*const fn (ptr: *anyopaque, type_idx: wasm.indices.Func, idx: u32) anyerror!void = null,
        visitTable: ?*const fn (ptr: *anyopaque, table: wasm.types.Table, idx: u32) anyerror!void = null,
        visitMemory: ?*const fn (ptr: *anyopaque, mem: wasm.types.Memory, idx: u32) anyerror!void = null,
        visitGlobal: ?*const fn (ptr: *anyopaque, global: wasm.types.Global, idx: u32) anyerror!void = null,
        visitExport: ?*const fn (ptr: *anyopaque, exp: wasm.types.Export, idx: u32) anyerror!void = null,
        visitStart: ?*const fn (ptr: *anyopaque, start: wasm.indices.Func) anyerror!void = null,
        visitElem: ?*const fn (ptr: *anyopaque, elem: wasm.types.Element, idx: u32) anyerror!void = null,
        visitCode: ?*const fn (ptr: *anyopaque, body: wasm.types.FuncBody, idx: u32) anyerror!void = null,
        visitData: ?*const fn (ptr: *anyopaque, data: wasm.types.Segment, idx: u32) anyerror!void = null,
    };
};

pub fn traverse(self: Ast, visitor: Visitor) !void {
    if (self.types) |types| {
        if (visitor.vtable.visitType) |visitType| {
            try types.forEachWithIndex(visitor.ptr, visitType);
        }
    }
    if (self.imports) |imports| {
        if (visitor.vtable.visitImport) |visitImport| {
            try imports.forEachWithIndex(visitor.ptr, visitImport);
        }
    }
    if (self.funcs) |funcs| {
        if (visitor.vtable.visitFunc) |visitFunc| {
            try funcs.forEachWithIndex(visitor.ptr, visitFunc);
        }
    }
    if (self.tables) |tables| {
        if (visitor.vtable.visitTable) |visitTable| {
            try tables.forEachWithIndex(visitor.ptr, visitTable);
        }
    }
    if (self.memory) |memory| {
        if (visitor.vtable.visitMemory) |visitMemory| {
            try memory.forEachWithIndex(visitor.ptr, visitMemory);
        }
    }
    if (self.globals) |globals| {
        if (visitor.vtable.visitGlobal) |visitGlobal| {
            try globals.forEachWithIndex(visitor.ptr, visitGlobal);
        }
    }
    if (self.exports) |exports| {
        if (visitor.vtable.visitExport) |visitExport| {
            try exports.forEachWithIndex(visitor.ptr, visitExport);
        }
    }
    if (self.elems) |elems| {
        if (visitor.vtable.visitElem) |visitElem| {
            try elems.forEachWithIndex(visitor.ptr, visitElem);
        }
    }
    if (self.code) |code| {
        if (visitor.vtable.visitCode) |visitCode| {
            try code.forEachWithIndex(visitor.ptr, visitCode);
        }
    }
    if (self.data) |data| {
        if (visitor.vtable.visitData) |visitData| {
            try data.forEachWithIndex(visitor.ptr, visitData);
        }
    }
    if (self.start) |start| {
        if (visitor.vtable.visitStart) |visitStart| {
            try visitStart(visitor.ptr, start.func_idx);
        }
    }
}
