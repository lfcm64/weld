const std = @import("std");

const types = @import("types.zig");
const indices = @import("indices.zig");
const Vec = @import("vecs.zig").Vec;

const io = std.io;

pub const SectionType = enum(u8) {
    custom = 0x00,
    type = 0x01,
    import = 0x02,
    func = 0x03,
    table = 0x04,
    memory = 0x05,
    global = 0x06,
    @"export" = 0x07,
    start = 0x08,
    elem = 0x09,
    code = 0x0a,
    data = 0x0b,
};

pub fn Section(comptime section_type: SectionType) type {
    return switch (section_type) {
        .custom => CustomSection,
        .type => Vec(types.FuncType),
        .import => Vec(types.Import),
        .func => Vec(u32),
        .table => Vec(types.Table),
        .memory => Vec(types.Memory),
        .global => Vec(types.Global),
        .@"export" => Vec(types.Export),
        .start => StartSection,
        .elem => Vec(types.Element),
        .code => Vec(types.FuncBody),
        .data => Vec(types.Segment),
    };
}

const CustomSection = struct {
    name: []const u8,
    bytes: []const u8,

    pub fn fromReaderSized(reader: *io.Reader) !CustomSection {
        _ = try reader.takeLeb128(u32);
        const name_size = try reader.takeLeb128(u32);
        const name = try reader.take(name_size);

        _ = try reader.takeLeb128(u32);
        const bytes_size = try reader.takeLeb128(u32);
        const bytes = try reader.take(bytes_size);
        return .{
            .name = name,
            .bytes = bytes,
        };
    }
};

pub const StartSection = struct {
    func_idx: indices.Func,

    pub fn fromReaderSized(reader: *io.Reader) !StartSection {
        return .{ .func_idx = try reader.takeLeb128(u32) };
    }
};

pub fn SectionItem(section_type: SectionType) type {
    return switch (section_type) {
        .type => types.FuncType,
        .import => types.Import,
        .func => u32,
        .table => types.Table,
        .memory => types.Memory,
        .global => types.Global,
        .@"export" => types.Export,
        .elem => types.Element,
        .code => types.FuncBody,
        .data => types.Segment,
        else => unreachable,
    };
}
