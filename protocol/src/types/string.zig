const std = @import("std");

const VarInt = @import("../types/mod.zig").VarInt;

pub const StringError = error{
    OutOfBounds,
};

pub const String = struct {
    value: []const u8,
    len: usize,

    pub fn decode(buf: []const u8) !String {
        const len = try VarInt.decode(buf);
        const len_value: usize = @intCast(len.value);
        const total_len = len.len + len_value;

        if (buf.len < total_len) {
            return StringError.OutOfBounds;
        }

        return String{
            .value = buf[len.len..total_len],
            .len = total_len,
        };
    }

    pub fn encode(value: []const u8, buf: []u8) !usize {
        const offset = try VarInt.encode(@intCast(value.len), buf);
        if (offset + value.len > buf.len) {
            return StringError.OutOfBounds;
        }

        @memcpy(buf[offset .. offset + value.len], value[0..value.len]);
        return offset + value.len;
    }
};
