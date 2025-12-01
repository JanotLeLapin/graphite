pub const client = @import("client.zig");
pub const uring = @import("uring.zig");

pub const Context = struct {
    client_manager: client.ClientManager,
    ring: uring.Ring,
    server_fd: i32,
};
