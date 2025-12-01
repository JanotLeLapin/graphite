const std = @import("std");

const VarInt = @import("../types/mod.zig").VarInt;

pub const String = struct {
    value: []const u8,
    len: usize,

    pub fn decode(buf: []const u8) ?String {
        const len = VarInt.decode(buf) orelse return null;
        const len_value: usize = @intCast(len.value);
        const total_len = len.len + len_value;

        if (buf.len < total_len) {
            return null;
        }

        return String{
            .value = buf[len.len..total_len],
            .len = total_len,
        };
    }

    pub fn encode(value: []const u8, buf: []u8) ?usize {
        const offset = VarInt.encode(@intCast(value.len), buf) orelse return null;
        if (offset + value.len > buf.len) {
            return null;
        }

        @memcpy(buf[offset .. offset + value.len], value[0..value.len]);
        return offset + value.len;
    }
};
