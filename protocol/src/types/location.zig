const std = @import("std");

const common = @import("graphite-common");
const BlockLocation = common.types.BlockLocation;

const DecodedType = struct {
    value: BlockLocation,
    len: usize,
};

pub fn decode(buf: []const u8) !DecodedType {
    const p: i64 = std.mem.readInt(i64, buf[0..8], .big);
    return DecodedType{
        .value = .{
            .x = @intCast(p >> 38),
            .y = @intCast((p >> 26) & 0xFF),
            .z = @intCast(p & 0xFFFFFFFF),
        },
        .len = 8,
    };
}

pub fn encode(value: BlockLocation, buf: []u8) !usize {
    const x: i64 = @intCast(value.x);
    const y: i64 = @intCast(value.y);
    const z: i64 = @intCast(value.z);
    const p = ((x & 0x3FFFFFF) << 38) | ((y & 0xFFF) << 26) | (z & 0x3FFFFFF);
    std.mem.writeInt(i64, buf[0..8], p, .big);
    return 8;
}
