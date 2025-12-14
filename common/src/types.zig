pub const chunk = @import("types/chunk.zig");

pub const ClientTag = struct { fd: i32 };

pub const EntityLocation = struct {
    x: f64,
    y: f64,
    z: f64,
    on_ground: bool,
};

pub const BlockLocation = struct {
    x: i32,
    y: u8,
    z: i32,
};

pub const SlotData = packed struct {
    block_id: i16,
    item_count: u8,
    item_damage: u16,
};

pub const DigStatus = enum(u8) {
    started_digging = 0,
    cancelled_digging,
    finished_digging,
    drop_item_stack,
    drop_item,
    shoot_arrow_finish_eating,
};
