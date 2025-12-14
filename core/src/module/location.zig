const std = @import("std");
const log = std.log.scoped(.location_mod);

const common = @import("graphite-common");
const Client = common.client.Client;
const Context = common.Context;
const EntityLocation = common.types.EntityLocation;
const hook = common.hook;
const zcs = common.zcs;

pub fn euclideanDist(a: EntityLocation, b: EntityLocation) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;

    return @sqrt(dx * dx + dy * dy + dz * dz);
}

pub const LocationModuleOptions = struct {
    spawn_point: EntityLocation,
    max_dist: ?f64 = null,
};

/// Resets a client's location component when a position packet is received
pub fn LocationModule(comptime opt: LocationModuleOptions) type {
    return struct {
        _: u8 = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return @This(){};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onJoin(cb: *zcs.CmdBuf, h: hook.JoinHook) !void {
            _ = h.client.e.add(cb, EntityLocation, opt.spawn_point);
        }

        pub fn onMove(
            ctx: *Context,
            h: hook.MoveHook,
        ) !void {
            const l = h.client.e.get(ctx.entities, EntityLocation).?;
            if (opt.max_dist) |md| {
                const dist = euclideanDist(h.location, l.*);
                if (dist > md) {
                    log.warn("kicking {s}: moved too fast: {d} blocks", .{
                        h.client.username.items,
                        dist,
                    });
                    ctx.disconnect(h.client.fd);
                    return;
                }
            }
            l.* = h.location;
        }
    };
}
