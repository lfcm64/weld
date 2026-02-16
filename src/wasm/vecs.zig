const std = @import("std");

const io = std.io;
const assert = std.debug.assert;

const Allocator = std.mem.Allocator;

pub fn Vec(comptime T: type) type {
    return struct {
        bytes: []const u8,
        count: u32,

        pub fn fromReader(reader: *io.Reader) !@This() {
            const count = try reader.takeLeb128(u32);
            const pos = reader.seek;
            for (0..count) |_| {
                _ = switch (T) {
                    u32 => try reader.takeLeb128(u32),
                    else => try T.fromReader(reader),
                };
            }
            return .{
                .bytes = reader.buffer[pos..reader.seek],
                .count = count,
            };
        }

        pub fn fromReaderSized(reader: *io.Reader) !@This() {
            const size = try reader.takeLeb128(u32);
            const pos = reader.seek;
            const count = try reader.takeLeb128(u32);
            return .{
                .bytes = try reader.take(size - (reader.seek - pos)),
                .count = count,
            };
        }

        pub fn collect(self: *const @This(), allocator: Allocator) ![]T {
            var list = try std.ArrayList(T).initCapacity(allocator, self.count);
            errdefer list.deinit(allocator);

            var it = self.iter();
            while (try it.next()) |item| list.appendAssumeCapacity(item);
            return list.toOwnedSlice(allocator);
        }

        pub fn iter(self: *const @This()) Iterator(T) {
            return .{
                .reader = io.Reader.fixed(self.bytes),
                .remaining = self.count,
            };
        }

        pub fn forEach(
            self: *const @This(),
            ctx: anytype,
            callback: *const fn (@TypeOf(ctx), item: T) anyerror!void,
        ) !void {
            var it = self.iter();
            while (try it.next()) |item| {
                try callback(ctx, item);
            }
        }

        pub fn forEachWithIndex(
            self: *const @This(),
            ctx: anytype,
            callback: *const fn (@TypeOf(ctx), item: T, idx: u32) anyerror!void,
        ) !void {
            var it = self.iter();
            var idx: u32 = 0;
            while (try it.next()) |item| {
                try callback(ctx, item, idx);
                idx += 1;
            }
        }
    };
}

pub fn Iterator(comptime T: type) type {
    return struct {
        reader: io.Reader,
        remaining: u32,

        pub fn next(self: *@This()) !?T {
            if (self.remaining == 0) {
                assert(self.reader.seek == self.reader.buffer.len);
                return null;
            }
            self.remaining -= 1;

            return switch (T) {
                u32 => try self.reader.takeLeb128(u32),
                else => try T.fromReader(&self.reader),
            };
        }
    };
}
