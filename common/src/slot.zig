pub const BlockId = enum(i16) {
    diamond_pickaxe = 278,
};

pub const SlotData = packed struct {
    block_id: BlockId,
    item_count: u8,
    item_damage: u16,
};
