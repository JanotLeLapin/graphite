const std = @import("std");

const common = @import("graphite-common");

pub const Location = struct {
    value: common.chunk.Location,

    const DecodedType = struct {
        value: common.chunk.Location,
        len: usize,
    };

    pub fn decode(buf: []const u8) !DecodedType {
        const p: u64 = std.mem.readInt(u64, buf[0..8], .big);
        return DecodedType{
            .value = .{
                .x = @intCast(p >> 38),
                .y = @intCast((p >> 26) & 0xFF),
                .z = @intCast(p & 0xFFFFFFFF),
            },
            .len = 8,
        };
    }
};
