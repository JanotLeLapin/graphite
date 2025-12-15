pub const chunk = @import("types/chunk.zig");

pub const ClientTag = struct { fd: i32 };

pub const ClientState = enum(u8) {
    handshake = 0,
    status = 1,
    login = 2,
    play = 3,
};

pub const GamemodeType = enum(u8) {
    survival = 0,
    creative = 1,
    adventure = 2,
    spectator = 3,
};

pub fn Gamemode(comptime Gt: GamemodeType, comptime hardcore: bool) u8 {
    return @intFromEnum(Gt) | (@as(u8, @intCast(@intFromBool(hardcore))) << 7);
}

pub const Dimension = enum(i8) {
    nether = -1,
    overworld = 0,
    end = 1,
};

pub const Difficulty = enum(u8) {
    peaceful = 0,
    easy = 1,
    normal = 2,
    hard = 3,
};

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
