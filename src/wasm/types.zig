const std = @import("std");
const indices = @import("indices.zig");
const instr = @import("instr.zig");

const Vec = @import("vecs.zig").Vec;

const io = std.io;

const Allocator = std.mem.Allocator;
const Instruction = instr.Instruction;

pub const Header = struct {
    magic: u32,
    version: u32,

    pub fn fromReader(reader: *io.Reader) !Header {
        return .{
            .magic = try reader.takeInt(u32, .little),
            .version = try reader.takeInt(u32, .little),
        };
    }
};

pub const ValType = enum(u8) {
    i32 = 0x7f,
    i64 = 0x7e,
    f32 = 0x7d,
    f64 = 0x7c,
};

pub const Mutability = enum(u8) {
    @"const" = 0x00,
    @"var" = 0x01,
};

pub const Expr = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    global: indices.Global,

    pub fn fromReader(reader: *io.Reader) !Expr {
        const opcode = try reader.takeByte();
        const expr: Expr = switch (opcode) {
            0x41 => .{ .i32 = try reader.takeLeb128(i32) }, // i32.const
            0x42 => .{ .i64 = try reader.takeLeb128(i64) }, // i64.const
            0x43 => .{ .f32 = @floatFromInt(try reader.takeInt(u32, .little)) }, // f32.const
            0x44 => .{ .f64 = @floatFromInt(try reader.takeInt(u64, .little)) }, // f64.const
            0x23 => .{ .global = try reader.takeLeb128(u32) }, // get_global
            else => return error.InvalidInitExprOpcode,
        };
        const end = try reader.takeByte();
        if (end != 0x0B) return error.MissingEndOpcode;
        return expr;
    }
};

pub const Limits = struct {
    min: u32,
    max: ?u32,

    pub fn fromReader(reader: *io.Reader) !Limits {
        const tag = try reader.takeByte();
        const min = try reader.takeLeb128(u32);
        return switch (tag) {
            0x00 => .{
                .min = min,
                .max = null,
            },
            0x01 => .{
                .min = min,
                .max = try reader.takeLeb128(u32),
            },
            else => error.InvalidLimitsTag,
        };
    }
};

pub const Memory = Limits;

pub const Table = struct {
    limits: Limits,

    pub fn fromReader(reader: *io.Reader) !Table {
        const lim = try Limits.fromReader(reader);
        const funcref = try reader.takeByte();
        if (funcref != 0x70) return error.InvalidElemType;
        return .{ .limits = lim };
    }
};

pub const Local = struct {
    count: u32,
    valtype: ValType,

    pub fn fromReader(reader: *io.Reader) !Local {
        return .{
            .count = try reader.takeLeb128(u32),
            .valtype = @enumFromInt(try reader.takeByte()),
        };
    }
};

pub const GlobalType = struct {
    valtype: ValType,
    mut: Mutability,

    pub fn fromReader(reader: *io.Reader) !GlobalType {
        return .{
            .valtype = @enumFromInt(try reader.takeByte()),
            .mut = @enumFromInt(try reader.takeByte()),
        };
    }
};

pub const Global = struct {
    ty: GlobalType,
    init_expr: Expr,

    pub fn fromReader(reader: *io.Reader) !Global {
        const ty = try GlobalType.fromReader(reader);
        const init_expr = try Expr.fromReader(reader);
        return .{
            .ty = ty,
            .init_expr = init_expr,
        };
    }
};

pub const ExportKind = union(enum) {
    func: indices.Func,
    table: indices.Table,
    memory: indices.Mem,
    global: indices.Global,

    pub fn fromReader(reader: *io.Reader) !ExportKind {
        const tag = try reader.takeByte();
        const idx = try reader.takeLeb128(u32);
        return switch (tag) {
            0x00 => .{ .func = idx },
            0x01 => .{ .table = idx },
            0x02 => .{ .memory = idx },
            0x03 => .{ .global = idx },
            else => return error.InvalidExportKindTag,
        };
    }
};

pub const Export = struct {
    name: []const u8,
    kind: ExportKind,

    pub fn fromReader(reader: *io.Reader) !Export {
        const name_size = try reader.takeLeb128(u32);
        return .{
            .name = try reader.take(name_size),
            .kind = try ExportKind.fromReader(reader),
        };
    }
};

pub const ImportDesc = union(enum) {
    func: indices.Func,
    table: Table,
    memory: Memory,
    global: GlobalType,

    pub fn fromReader(reader: *io.Reader) !ImportDesc {
        const tag = try reader.takeByte();
        return switch (tag) {
            0x00 => .{ .func = try reader.takeLeb128(u32) },
            0x01 => .{ .table = try Table.fromReader(reader) },
            0x02 => .{ .memory = try Memory.fromReader(reader) },
            0x03 => .{ .global = try GlobalType.fromReader(reader) },
            else => return error.InvalidImportDescTag,
        };
    }
};

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    desc: ImportDesc,

    pub fn fromReader(reader: *io.Reader) !Import {
        const module_size = try reader.takeLeb128(u32);
        const module = try reader.take(module_size);

        const name_size = try reader.takeLeb128(u32);
        const name = try reader.take(name_size);

        const desc = try ImportDesc.fromReader(reader);
        return .{
            .module = module,
            .name = name,
            .desc = desc,
        };
    }
};

pub const ResultType = []const ValType;

pub const FuncType = struct {
    params: ResultType,
    results: ResultType,

    pub fn fromReader(reader: *io.Reader) !FuncType {
        const tag = try reader.takeByte();
        if (tag != 0x60) return error.InvalidFuncTypeTag;

        const param_count = try reader.takeLeb128(u32);
        const params: ResultType = @ptrCast(try reader.take(param_count));

        const result_count = try reader.takeLeb128(u32);
        const results: ResultType = @ptrCast(try reader.take(result_count));
        return .{
            .params = params,
            .results = results,
        };
    }
};

pub const FuncBody = struct {
    size: u32,
    locals: Vec(Local),
    code: []const u8,

    pub fn fromReader(reader: *io.Reader) !FuncBody {
        const size = try reader.takeLeb128(u32);
        const end = reader.seek + size;
        const locals = try Vec(Local).fromReader(reader);
        const code = try reader.take(end - reader.seek);
        return .{
            .size = size,
            .locals = locals,
            .code = code,
        };
    }

    pub fn collectLocals(self: FuncBody, allocator: Allocator) ![]ValType {
        var locals: std.ArrayList(ValType) = .{};

        var it = self.locals.iter();
        while (try it.next()) |local| try locals.appendNTimes(allocator, local.valtype, local.count);
        return locals.toOwnedSlice(allocator);
    }
};

pub const Element = struct {
    table_idx: indices.Table,
    offset: Expr,
    indices: Vec(u32),

    pub fn fromReader(reader: *io.Reader) !Element {
        const table_idx = try reader.takeLeb128(u32);
        const offset = try Expr.fromReader(reader);
        return .{
            .table_idx = table_idx,
            .offset = offset,
            .indices = try Vec(u32).fromReader(reader),
        };
    }
};

pub const Segment = struct {
    mem_idx: indices.Mem,
    offset: Expr,
    bytes: []const u8,

    pub fn fromReader(reader: *io.Reader) !Segment {
        const mem_idx = try reader.takeLeb128(u32);
        const offset = try Expr.fromReader(reader);

        const bytes_size = try reader.takeLeb128(u32);
        const bytes: []const u8 = @ptrCast(try reader.take(bytes_size));
        return .{
            .mem_idx = mem_idx,
            .offset = offset,
            .bytes = bytes,
        };
    }
};
