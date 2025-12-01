const std = @import("std");

fn Varlen(comptime T: type, comptime n: usize) type {
    const ShiftType = std.math.Log2Int(T);
    return struct {
        value: T,
        len: usize,

        pub fn decode(buf: []const u8, buf_len: usize) ?@This() {
            var res = @This(){
                .value = 0,
                .len = 0,
            };

            var b: u8 = 0;
            for (0..@min(n, buf_len)) |i| {
                b = buf[i];
                const shift = @as(ShiftType, 7 * @as(ShiftType, @intCast(i)));
                const byte_val = @as(T, @intCast(b & 0x7F));
                res.value |= (byte_val << shift);
                if (0 == (b & 0x80)) {
                    res.len = i + 1;
                    return res;
                }
            }

            return null;
        }

        pub fn encode(value: T, buf: []u8, buf_len: usize) ?usize {
            var b: u8 = 0;
            for (0..@min(n, buf_len)) |i| {
                b = value & 0x7F;
                value = value >> 7;
                if (0 != value) {
                    b |= 0x80;
                }

                buf[i] = b;

                if (0 == value) {
                    return i;
                }
            }

            return null;
        }
    };
}

pub const VarInt = Varlen(i32, 5);
pub const VarLong = Varlen(i32, 10);
