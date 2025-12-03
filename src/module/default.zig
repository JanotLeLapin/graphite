const std = @import("std");

const common = @import("../common/mod.zig");
const packet = @import("../packet/mod.zig");

pub const DefaultModuleError = error{
    EncodingFailure,
};

pub const DefaultModule = struct {
    pub fn init(_: std.mem.Allocator) !DefaultModule {
        return DefaultModule{};
    }

    pub fn deinit(_: *DefaultModule) !void {}

    pub fn onJoin(
        // _: *DefaultModule,
        ctx: *common.Context,
        client: *common.client.Client,
    ) !void {
        if (ctx.buffer_pool.allocBuf()) |b| {
            errdefer ctx.buffer_pool.releaseBuf(b.idx);

            var json: [128]u8 = undefined;
            const size = packet.ClientPlayChatMessage.encode(
                &.{
                    .json = try std.fmt.bufPrint(
                        json[0..],
                        "{{\"text\":\"{s} joined the game.\",\"color\":\"yellow\"}}",
                        .{client.username.items},
                    ),
                    .position = .Chat,
                },
                &b.data,
            ) orelse return DefaultModuleError.EncodingFailure;
            try b.prepareBroadcast(ctx.ring, ctx.client_manager.lookup.items, size);
            _ = try ctx.ring.submit();
        }
    }
};
