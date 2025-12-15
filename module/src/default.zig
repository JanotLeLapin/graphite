const std = @import("std");
const log = std.log.scoped(.default_mod);

const common = @import("graphite-common");
const Chat = common.chat.Chat;
const Client = common.client.Client;
const Context = common.Context;
const EntityLocation = common.types.EntityLocation;
const hook = common.hook;
const zcs = common.zcs;

const protocol = @import("graphite-protocol");

pub const DefaultModuleOptions = struct {
    pub const Status = struct {
        max_players: ?usize = null,
        version_name: []const u8,
        description: Chat,
    };

    /// server list status
    status: ?Status = null,

    /// add/remove players from the tab list on join/quit
    update_playerlist: bool = true,

    /// enforce max player count on the server
    max_players: ?usize = null,

    /// tab-complete with currently online player names
    tab_complete_player_names: bool = true,
};

/// Convenient features
pub fn DefaultModule(comptime opt: DefaultModuleOptions) type {
    const StatusData = if (opt.status == null)
        void
    else
        struct {
            buf: [256]u8,
            len: usize,
        };

    return struct {
        status: StatusData = undefined,
        alloc: std.mem.Allocator,

        fn prepareAddOne(ctx: *Context, client: *Client) !void {
            const b, const size = try ctx.encode(protocol.ClientPlayPlayerListItem{
                .add_player = &.{
                    .{
                        .uuid = client.uuid,
                        .name = client.username.items,
                        .gamemode = @intFromEnum(protocol.GamemodeType.survival),
                        .ping = 0,
                        .display_name = null,
                    },
                },
            }, .@"10");
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

            const b, const size = try ctx.encode(protocol.ClientPlayPlayerListItem{
                .add_player = list.items,
            }, .@"14");
            ctx.prepareOneshot(client.fd, b, size);
        }

        pub fn init(alloc: std.mem.Allocator) !@This() {
            var self = @This(){ .alloc = alloc };
            if (opt.status) |status| {
                const slice = std.fmt.bufPrint(&self.status.buf, "{f}", .{status.description}) catch unreachable;
                self.status.len = slice.len;
            }
            return self;
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onStatus(self: *@This(), ctx: *Context, h: hook.StatusHook) !void {
            const status = opt.status orelse return;

            const max_players = if (opt.max_players) |mp|
                mp
            else if (status.max_players) |mp|
                mp
            else
                @compileError("one of opt.max_players or opt.status.max_players must be set");

            var json: [512]u8 = undefined;
            const b, const size = try ctx.encode(protocol.ClientStatusResponse{
                .response = try std.fmt.bufPrint(
                    json[0..],
                    "{{\"version\":{{\"name\":\"" ++ status.version_name ++ "\",\"protocol\":47}},\"players\":{{\"max\":{d},\"online\":{d},\"sample\":[]}},\"description\":{s}}}",
                    .{
                        max_players,
                        ctx.client_manager.count,
                        self.status.buf[0..self.status.len],
                    },
                ),
            }, .@"10");
            ctx.prepareOneshot(h.fd, b, size);
        }

        pub fn onJoin(self: *@This(), ctx: *Context, h: hook.JoinHook) !void {
            if (opt.max_players) |max_players| {
                if (ctx.client_manager.count > max_players) {
                    log.warn("kicked {s}: max player count reached", .{h.client.username.items});
                    ctx.disconnect(h.client.fd);
                    return;
                }
            }

            if (opt.update_playerlist) {
                prepareAddOne(ctx, h.client) catch log.warn("could not update player list", .{});
                prepareAddAll(self, ctx, h.client) catch log.warn("could not update player list", .{});
            }
        }

        pub fn onTabComplete(self: *@This(), ctx: *Context, h: hook.TabCompleteHook) !void {
            if (!opt.tab_complete_player_names) {
                return;
            }

            var matches = try std.ArrayList([]const u8).initCapacity(self.alloc, ctx.client_manager.count);
            defer matches.deinit(self.alloc);

            const text = blk: {
                var cursor = h.text.len;
                while (cursor > 0) {
                    if (h.text[cursor - 1] == ' ') {
                        break;
                    }
                    cursor -= 1;
                }
                break :blk h.text[cursor..];
            };

            for (ctx.client_manager.lookup.items) |slot| {
                const c = slot.client orelse continue;
                if (std.mem.startsWith(u8, c.username.items, text)) {
                    matches.appendAssumeCapacity(c.username.items);
                }
            }

            if (matches.items.len <= 0) {
                return;
            }

            const b, const size = try ctx.encode(protocol.ClientPlayTabComplete{
                .matches = matches.items,
            }, .@"14");
            ctx.prepareOneshot(h.client.fd, b, size);
        }

        pub fn onQuit(ctx: *Context, h: hook.QuitHook) !void {
            if (opt.update_playerlist) {
                const b, const size = try ctx.encode(protocol.ClientPlayPlayerListItem{
                    .remove_player = &.{h.client.uuid},
                }, .@"10");
                ctx.prepareBroadcast(b, size);
            }
        }
    };
}
