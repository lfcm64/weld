const std = @import("std");
const wasm = @import("wasm");

pub const Ast = @import("Ast.zig");
pub const Payload = @import("payload.zig").Payload;

const io = std.io;
const types = wasm.types;

const SectionType = wasm.sections.SectionType;
const Section = wasm.sections.Section;

pub const IncrementalParser = struct {
    source: []const u8,
    reader: io.Reader,

    state: State = .not_started,

    pub const State = union(enum) {
        not_started,
        header,
        section: SectionType,
    };

    pub fn init(source: []const u8) IncrementalParser {
        return .{
            .source = source,
            .reader = io.Reader.fixed(source),
        };
    }

    pub fn parseNext(self: *IncrementalParser) !?Payload {
        if (self.reader.seek == self.source.len) return null;

        switch (self.state) {
            .not_started => {
                const header = try types.Header.fromReader(&self.reader);
                self.state = .header;
                return .{ .module_header = header };
            },
            .header, .section => {
                const section_type: SectionType = @enumFromInt(try self.reader.takeByte());

                if (self.state == .section and section_type != .custom) {
                    if (@intFromEnum(self.state.section) >= @intFromEnum(section_type)) {
                        return error.SectionsOutOfOrder;
                    }
                }
                switch (section_type) {
                    inline else => |ty| {
                        const info = @typeInfo(Payload);
                        const field = info.@"union".fields[@intFromEnum(ty) + 1];

                        const section = try Section(ty).fromReaderSized(&self.reader);
                        self.state = .{ .section = section_type };
                        return @unionInit(Payload, field.name, section);
                    },
                }
            },
        }
    }
};

pub fn parseAll(source: []const u8) !Ast {
    var ast = Ast{};
    var ip = IncrementalParser.init(source);

    while (try ip.parseNext()) |payload| switch (payload) {
        .module_header => |h| {
            ast.magic = h.magic;
            ast.version = h.version;
        },
        .custom_section => ast.custom_section_num += 1,
        .type_section => |s| ast.types = s,
        .import_section => |s| ast.imports = s,
        .func_section => |s| ast.funcs = s,
        .table_section => |s| ast.tables = s,
        .memory_section => |s| ast.memory = s,
        .global_section => |s| ast.globals = s,
        .export_section => |s| ast.exports = s,
        .start_section => |s| ast.start = s,
        .element_section => |s| ast.elems = s,
        .code_section => |s| ast.code = s,
        .data_section => |s| ast.data = s,
    };
    return ast;
}
