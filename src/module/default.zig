const std = @import("std");

const common = @import("../common/mod.zig");
const packet = @import("../packet/mod.zig");

pub const DefaultModuleError = error{
    EncodingFailure,
};

pub const DefaultModule = struct {
    some_counter: usize,

    pub fn init(_: std.mem.Allocator) !DefaultModule {
        return DefaultModule{
            .some_counter = 0,
        };
    }

    pub fn deinit(_: *DefaultModule) void {}

    pub fn onJoin(
        self: *DefaultModule,
        ctx: *common.Context,
        client: *common.client.Client,
    ) !void {
        self.some_counter += 1;
        const b = try ctx.buffer_pool.allocBuf();
        errdefer ctx.buffer_pool.releaseBuf(b.idx);

        var json: [128]u8 = undefined;
        var counter_buf: [4]u8 = undefined;

        const size = packet.ClientPlayChatMessage.encode(
            &.{
                .json = try std.fmt.bufPrint(
                    json[0..],
                    "{f}",
                    .{common.chat.Chat{ .text = "", .color = .yellow, .extra = &[_]common.chat.Chat{
                        .{ .text = client.username.items, .color = .red },
                        .{ .text = " joined the game, " },
                        .{ .text = try std.fmt.bufPrint(&counter_buf, "{d}", .{self.some_counter}) },
                    } }},
                ),
                .position = .chat,
            },
            &b.data,
        ) orelse return DefaultModuleError.EncodingFailure;
        try b.prepareBroadcast(ctx.ring, ctx.client_manager.lookup.items, size);
    }
};
