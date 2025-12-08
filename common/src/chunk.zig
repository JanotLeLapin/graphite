pub const BlockType = enum(u8) {
    air = 0,
    stone = 1,
    grass = 2,
    dirt = 3,
};

pub fn BlockData(comptime t: BlockType, comptime m: u4) u16 {
    const tn: u16 = @intFromEnum(t);
    return (((tn << 4) | (m & 0x0F)) << 8) | (tn >> 4);
}

pub const ChunkSection = struct {
    blocks: [4096]u16,
    block_light: [4096]u4,
    sky_light: [4096]u4,
};

pub const Chunk = struct {
    sections: [16]ChunkSection,
};
