const std = @import("std");

const common = @import("graphite-common");
const Client = common.client.Client;
const Context = common.Context;
const EntityLocation = common.types.EntityLocation;
const zcs = common.zcs;

pub fn euclideanDist(a: EntityLocation, b: EntityLocation) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    const dz = a.z - b.z;

    return @sqrt(dx * dx + dy * dy + dz * dz);
}

pub const LocationModuleOptions = struct {
    spawn_point: EntityLocation,
    max_dist: ?usize = null,
};

pub fn LocationModule(comptime opt: LocationModuleOptions) type {
    return struct {
        _: u8 = 0,

        pub fn init(_: std.mem.Allocator) !@This() {
            return @This(){};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn onJoin(cb: *zcs.CmdBuf, client: *Client) !void {
            _ = client.e.add(cb, EntityLocation, opt.spawn_point);
        }

        pub fn onMove(
            ctx: *Context,
            client: *Client,
            location: EntityLocation,
        ) !void {
            const l = client.e.get(ctx.entities, EntityLocation).?;
            if (opt.max_dist == null or euclideanDist(location, l.*) <= opt.max_dist.?) {
                l.* = location;
                return;
            }

            std.log.warn("moving too fast: {s}!", .{client.username.items});
            // TODO: kick or something
        }
    };
}
