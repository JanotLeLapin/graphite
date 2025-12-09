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
    wool = 35,
};

pub const WoolColor = enum(u4) {
    orange = 1,
    magenta = 2,
    light_blue = 3,
    yellow = 4,
    lime = 5,
    pink = 6,
    gray = 7,
    light_gray = 8,
    cyan = 9,
    purple = 10,
    blue = 11,
    brown = 12,
    green = 13,
    red = 14,
    black = 15,
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
