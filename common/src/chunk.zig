pub const Location = struct {
    x: i32,
    y: u8,
    z: i32,
};

pub const BlockType = enum(u16) {
    air = 0,
    stone,
    grass,
    dirt,
    cobblestone,
    wood_plank,
    sapling,
    bedrock,
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
    granite,
    polished_granite,
    diorite,
    polished_diorite,
    andesite,
    polished_andesite,
};

pub const DirtType = enum(u4) {
    dirt = 0,
    coarse_dirt,
    podzol,
};

pub const WoodType = enum(u4) {
    oak = 0,
    spruce,
    birch,
    jungle,
    acacia,
    dark_oak,
};

pub const WoolColor = enum(u4) {
    white = 0,
    orange,
    magenta,
    light_blue,
    yellow,
    lime,
    pink,
    gray,
    light_gray,
    cyan,
    purple,
    blue,
    brown,
    green,
    red,
    black,
};

pub const BiomeType = enum(u8) {
    the_void = 0,
    plains,
    desert,
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
