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

    pub fn encode(value: common.chunk.Location, buf: []u8) !usize {
        const x: u64 = @intCast(value.x);
        const y: u64 = @intCast(value.y);
        const z: u64 = @intCast(value.z);
        const p = ((x & 0x3FFFFFF) << 38) | ((y & 0xFFF) << 26) | (z & 0x3FFFFFF);
        std.mem.writeInt(u64, buf[0..8], p, .big);
        return 8;
    }
};
