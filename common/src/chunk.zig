pub const Location = struct {
    x: i32,
    y: u8,
    z: i32,
};

pub const BlockType = enum(u16) {
    air = 0,
    stone = 1,
    grass = 2,
    dirt = 3,
    cobblestone = 4,
    wood_plank = 5,
    sapling = 6,
    bedrock = 7,
    wool = 35,

    pub fn getBlockData(self: BlockType) u16 {
        return @as(u16, @intFromEnum(self)) << 4;
    }

    pub fn getBlockDataMeta(self: BlockType, meta: anytype) u16 {
        return (@as(u16, @intFromEnum(self)) << 4) | (@as(u4, @intFromEnum(meta)) & 0x0F);
    }
};

pub const StoneType = enum(u4) {
    stone = 0,
    granite = 1,
    polished_granite = 2,
    diorite = 3,
    polished_diorite = 4,
    andesite = 5,
    polished_andesite = 6,
};

pub const DirtType = enum(u4) {
    dirt = 0,
    coarse_dirt = 1,
    podzol = 2,
};

pub const WoodType = enum(u4) {
    oak = 0,
    spruce = 1,
    birch = 2,
    jungle = 3,
    acacia = 4,
    dark_oak = 5,
};

pub const WoolColor = enum(u4) {
    white = 0,
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

pub const ChunkSection = struct {
    blocks: [4096]u16,
    block_light: [4096]u4,
    sky_light: [4096]u4,
};

pub const Chunk = struct {
    sections: [16]ChunkSection,
    biomes: [256]BiomeType,
};
