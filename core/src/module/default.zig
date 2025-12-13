const std = @import("std");
const log = std.log.scoped(.default_mod);

const common = @import("graphite-common");
const Client = common.client.Client;
const Context = common.Context;
const EntityLocation = common.types.EntityLocation;
const zcs = common.zcs;

const protocol = @import("graphite-protocol");

pub const DefaultModuleOptions = struct {
    update_playerlist: bool = true,
};

pub fn DefaultModule(comptime opt: DefaultModuleOptions) type {
    return struct {
        alloc: std.mem.Allocator,

        fn prepareAddOne(ctx: *Context, client: *Client) !void {
            const b = try ctx.buffer_pools.allocBuf(.@"6");
            const size = try (protocol.ClientPlayPlayerListItem{
                .add_player = &.{
                    .{
                        .uuid = client.uuid,
                        .name = client.username.items,
                        .gamemode = @intFromEnum(protocol.GamemodeType.survival),
                        .ping = 0,
                        .display_name = null,
                    },
                },
            }).encode(b.ptr);
            ctx.prepareBroadcast(b, size);
        }

        fn prepareAddAll(self: *@This(), ctx: *Context, client: *Client) !void {
            var list = try std.ArrayList(protocol.ClientPlayPlayerListItem.AddPlayer).initCapacity(self.alloc, ctx.client_manager.count);
            defer list.deinit(self.alloc);

            for (ctx.client_manager.lookup.items) |slot| {
                if (slot.client) |c| {
                    if (c.fd == client.fd) {
                        continue;
                    }

                    try list.append(self.alloc, .{
                        .uuid = c.uuid,
                        .name = c.username.items,
                        .gamemode = @intFromEnum(protocol.GamemodeType.survival),
                        .ping = 0,
                        .display_name = null,
                    });
                }
            }

            const b = try ctx.buffer_pools.allocBuf(.@"14");
            const size = try (protocol.ClientPlayPlayerListItem{
                .add_player = list.items,
            }).encode(b.ptr);
            ctx.prepareOneshot(client.fd, b, size);
        }

        pub fn init(alloc: std.mem.Allocator) !@This() {
            return @This(){
                .alloc = alloc,
            };
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onJoin(self: *@This(), ctx: *Context, client: *Client) !void {
            if (opt.update_playerlist) {
                prepareAddOne(ctx, client) catch log.warn("could not update player list", .{});
                prepareAddAll(self, ctx, client) catch log.warn("could not update player list", .{});
            }
        }

        // pub fn onQuit(ctx: *Context) !void {}
    };
}
