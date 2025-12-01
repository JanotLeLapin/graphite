const std = @import("std");

pub const types = @import("types/mod.zig");

fn genDecodeBasic(comptime T: anytype) fn ([]const u8) ?T {
    return struct {
        fn decode(buf: []const u8) ?T {
            var res: T = undefined;
            var offset: usize = 0;

            inline for (std.meta.fields(T)) |field| {
                if (offset >= buf.len) {
                    return null;
                }

                const rem = buf[offset..];
                const FieldType = field.type;

                switch (@typeInfo(FieldType)) {
                    .int, .float => {
                        const size = @sizeOf(FieldType);
                        if (rem.len < size) {
                            return null;
                        }

                        const raw = std.mem.readInt(FieldType, rem[0..size], .big);
                        @field(res, field.name) = @bitCast(raw);
                        offset += size;
                    },
                    .pointer => |p| {
                        if (p.size != .slice or !p.is_const or p.child != u8) {
                            std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                        }

                        const string = types.String.decode(rem) orelse return null;
                        @field(res, field.name) = string.value;
                        offset += string.len;
                    },
                    .@"struct" => {
                        const val = FieldType.decode(rem) orelse return null;
                        @field(res, field.name) = val;
                        offset += val.len;
                    },
                    else => {
                        std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                    },
                }
            }

            return res;
        }
    }.decode;
}

fn genEncodeBasic(comptime T: anytype) fn (*const T, []u8) ?usize {
    return struct {
        fn encode(self: *const T, buf: []u8) ?usize {
            var offset: usize = 0;

            inline for (std.meta.fields(T)) |field| {
                if (offset >= buf.len) {
                    return null;
                }

                const rem = buf[offset..];
                const FieldType = field.type;

                switch (@typeInfo(FieldType)) {
                    .int, .float => {
                        const size = @sizeOf(FieldType);
                        if (rem.len < size) {
                            return null;
                        }

                        std.mem.writeInt(FieldType, rem[0..size], @field(self, field.name), .big);
                        offset += size;
                    },
                    .pointer => |p| {
                        if (p.size != .slice or !p.is_const or p.child != u8) {
                            std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                        }

                        const size = types.String.encode(@field(self, field.name), rem) orelse return null;
                        offset += size;
                    },
                    .@"struct" => {
                        const size = FieldType.encode(@field(self, field.name).value, rem) orelse return null;
                        offset += size;
                    },
                    else => {
                        std.debug.panic("can't parse field '{s}' with type: {any}", .{ field.name, FieldType });
                    },
                }
            }

            return offset;
        }
    }.encode;
}

pub const ServerHandshake = struct {
    protocol_version: types.VarInt,
    server_address: []const u8,
    server_port: u16,
    next_state: u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};

pub const ClientStatusResponse = struct {
    response: []const u8,

    pub fn encode(self: *const @This(), buf: []u8) ?usize {
        var offset: usize = 5;
        offset += types.VarInt.encode(0x00, buf[offset..]) orelse return null;
        offset += genEncodeBasic(@This())(self, buf[offset..]) orelse return null;

        const size = types.VarInt.encode(@intCast(offset - 5), buf) orelse return null;
        @memmove(buf[size .. size + offset], buf[5 .. 5 + offset]);

        std.debug.print("offset: {d}\n", .{size + offset});
        return size + offset - 5;
    }
};
