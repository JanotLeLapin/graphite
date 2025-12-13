const std = @import("std");

const common = @import("graphite-common");
const Chat = common.chat.Chat;
const Client = common.client.Client;
const Context = common.Context;
const protocol = @import("graphite-protocol");

pub const VanillaStatusOptions = struct {
    version_name: []const u8,
    description: Chat,
};

pub const VanillaModuleOptions = struct {
    status: ?VanillaStatusOptions = .{
        .version_name = "1.8.8",
        .description = common.chat.Chat{ .text = "A Minecraft Server" },
    },
    send_join_message: bool = true,
    send_quit_message: bool = true,
};

fn broadcastMessage(
    comptime buf_len: usize,
    ctx: *Context,
    message: Chat,
) !void {
    const b = try ctx.buffer_pools.allocBuf(.@"10");
    errdefer ctx.buffer_pools.releaseBuf(b.idx);

    var json: [buf_len]u8 = undefined;
    const size = try protocol.ClientPlayChatMessage.encode(
        &.{
            .json = try std.fmt.bufPrint(
                json[0..],
                "{f}",
                .{message},
            ),
            .position = .chat,
        },
        b.ptr,
    );
    ctx.prepareBroadcast(b, size);
}

pub fn VanillaModule(comptime opt: VanillaModuleOptions) type {
    return struct {
        _: u8 = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return @This(){};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onStatus(
            ctx: *Context,
            fd: i32,
        ) !void {
            const status = opt.status orelse return;

            const b = try ctx.buffer_pools.allocBuf(.@"10");
            errdefer ctx.buffer_pools.releaseBuf(b.idx);

            var json: [512]u8 = undefined;
            const size = try protocol.ClientStatusResponse.encode(
                &.{
                    .response = try std.fmt.bufPrint(json[0..], "{{\"version\":{{\"name\":\"" ++ status.version_name ++ "\",\"protocol\":47}},\"players\":{{\"max\":20,\"online\":{d},\"sample\":[]}},\"description\":{f}}}", .{
                        ctx.client_manager.count,
                        status.description,
                    }),
                },
                b.ptr,
            );

            ctx.prepareOneshot(fd, b, size);
        }

        pub fn onJoin(
            ctx: *Context,
            client: *Client,
        ) !void {
            if (!opt.send_join_message) {
                return;
            }

            try broadcastMessage(256, ctx, common.chat.Chat{
                .text = "",
                .color = .yellow,
                .extra = &.{
                    .{ .text = client.username.items },
                    .{ .text = " joined the game" },
                },
            });
        }

        pub fn onChatMessage(
            ctx: *Context,
            client: *Client,
            message: []const u8,
        ) !void {
            try broadcastMessage(1024, ctx, Chat{
                .text = "",
                .color = .white,
                .extra = &.{
                    .{ .text = "<" },
                    .{ .text = client.username.items },
                    .{ .text = "> " },
                    .{ .text = message },
                },
            });
        }

        pub fn onQuit(
            ctx: *Context,
            client: *Client,
        ) !void {
            if (!opt.send_quit_message) {
                return;
            }

            try broadcastMessage(256, ctx, Chat{
                .text = "",
                .color = .yellow,
                .extra = &.{
                    .{ .text = client.username.items },
                    .{ .text = " left the game" },
                },
            });
        }
    };
}
