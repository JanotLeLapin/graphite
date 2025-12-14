const root = @import("root.zig");
const Client = root.client.Client;
const EntityLocation = root.types.EntityLocation;
const BlockLocation = root.types.BlockLocation;

pub const StatusHook = struct { fd: i32 };
pub const JoinHook = struct { client: *Client };
pub const QuitHook = struct { client: *Client };
pub const MoveHook = struct {
    client: *Client,
    location: EntityLocation,
};
pub const DigHook = struct {
    client: *Client,
    status: root.types.DigStatus,
    location: BlockLocation,
    face: u8,
};
pub const ChatMessageHook = struct {
    client: *Client,
    message: []const u8,
};
