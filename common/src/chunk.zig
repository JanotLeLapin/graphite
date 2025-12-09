pub const Location = struct {
    x: i32,
    y: u8,
    z: i32,
};

pub const BlockType = enum(u8) {
    air = 0,
    stone = 1,
    grass = 2,
    dirt = 3,
};

pub const BiomeType = enum(u8) {
    the_void = 0,
    plains = 1,
    desert = 2,
};

pub fn BlockData(t: BlockType, m: u4) u16 {
    const tn: u16 = @intFromEnum(t);
    return (tn << 4) | (m & 0x0F);
}

pub const ChunkSection = struct {
    blocks: [4096]u16,
    block_light: [4096]u4,
    sky_light: [4096]u4,
};

pub const Chunk = struct {
    sections: [16]ChunkSection,
    biomes: [256]BiomeType,
};
