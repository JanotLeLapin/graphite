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

pub const ServerHandshake = struct {
    protocol_version: types.VarInt,
    server_address: []const u8,
    server_port: u16,
    next_state: u8,

    pub fn decode(buf: []const u8) ?@This() {
        return genDecodeBasic(@This())(buf);
    }
};
