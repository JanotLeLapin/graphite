/// pachelbel.zig
///
/// plays pachelbel's canon in a loop to every player on join
const std = @import("std");

const common = @import("graphite-common");
const protocol = @import("graphite-protocol");

/// data passed to a task callback
const ScheduleTaskData = packed struct(u64) {
    client_fd: i32,
    /// the index of the pattern that should be scheduled
    schedule: u8,
    _: u24 = 0,
};

const Part = enum(u16) {
    bass = 1 << 0,
    main_a = 1 << 1,
    main_b = 1 << 2,
    alt_a = 1 << 3,
};

const Instrument = enum(u8) {
    bass,
    bd,
    harp,
    hat,
    pling,
    snare,

    pub fn getName(self: @This()) []const u8 {
        return switch (self) {
            .bass => "note.bass",
            .bd => "note.bd",
            .harp => "note.harp",
            .hat => "note.hat",
            .pling => "note.pling",
            .snare => "note.snare",
        };
    }
};

const NoteTaskData = packed struct(u64) {
    client_fd: i32,
    midi: u8,
    instrument: Instrument,
    _: u16 = 0,
};

const NoteData = struct {
    time: usize,
    midi: u8,
    instrument: Instrument,
};

const BassPart = [_]NoteData{
    .{ .time = 0, .midi = 62, .instrument = .bass },
    .{ .time = 8, .midi = 57, .instrument = .bass },
    .{ .time = 16, .midi = 59, .instrument = .bass },
    .{ .time = 24, .midi = 54, .instrument = .bass },
    .{ .time = 32, .midi = 55, .instrument = .bass },
    .{ .time = 40, .midi = 50, .instrument = .bass },
    .{ .time = 48, .midi = 55, .instrument = .bass },
    .{ .time = 56, .midi = 57, .instrument = .bass },
};

const MainAPart = [_]NoteData{
    .{ .time = 0, .midi = 50, .instrument = .harp },
    .{ .time = 0, .midi = 54, .instrument = .harp },
    .{ .time = 8, .midi = 49, .instrument = .harp },
    .{ .time = 8, .midi = 52, .instrument = .harp },
    .{ .time = 16, .midi = 47, .instrument = .harp },
    .{ .time = 16, .midi = 54, .instrument = .harp },
    .{ .time = 24, .midi = 45, .instrument = .harp },
    .{ .time = 24, .midi = 49, .instrument = .harp },
    .{ .time = 32, .midi = 43, .instrument = .harp },
    .{ .time = 32, .midi = 47, .instrument = .harp },
    .{ .time = 40, .midi = 42, .instrument = .harp },
    .{ .time = 40, .midi = 45, .instrument = .harp },
    .{ .time = 48, .midi = 43, .instrument = .harp },
    .{ .time = 48, .midi = 47, .instrument = .harp },
    .{ .time = 56, .midi = 45, .instrument = .harp },
    .{ .time = 56, .midi = 49, .instrument = .harp },
};

const MainBPart = [_]NoteData{
    .{ .time = 0, .midi = 54, .instrument = .harp },
    .{ .time = 0, .midi = 62, .instrument = .harp },
    .{ .time = 8, .midi = 57, .instrument = .harp },
    .{ .time = 8, .midi = 61, .instrument = .harp },
    .{ .time = 16, .midi = 50, .instrument = .harp },
    .{ .time = 16, .midi = 59, .instrument = .harp },
    .{ .time = 24, .midi = 54, .instrument = .harp },
    .{ .time = 24, .midi = 57, .instrument = .harp },
    .{ .time = 32, .midi = 47, .instrument = .harp },
    .{ .time = 32, .midi = 55, .instrument = .harp },
    .{ .time = 40, .midi = 50, .instrument = .harp },
    .{ .time = 40, .midi = 54, .instrument = .harp },
    .{ .time = 48, .midi = 47, .instrument = .harp },
    .{ .time = 48, .midi = 55, .instrument = .harp },
    .{ .time = 56, .midi = 49, .instrument = .harp },
    .{ .time = 56, .midi = 57, .instrument = .harp },
};

const AltAPart = [_]NoteData{
    .{ .time = 0, .midi = 50, .instrument = .pling },
    .{ .time = 4, .midi = 54, .instrument = .pling },
    .{ .time = 8, .midi = 57, .instrument = .pling },
    .{ .time = 12, .midi = 55, .instrument = .pling },
    .{ .time = 16, .midi = 54, .instrument = .pling },
    .{ .time = 20, .midi = 50, .instrument = .pling },
    .{ .time = 24, .midi = 54, .instrument = .pling },
    .{ .time = 28, .midi = 52, .instrument = .pling },
    .{ .time = 32, .midi = 50, .instrument = .pling },
    .{ .time = 36, .midi = 47, .instrument = .pling },
    .{ .time = 40, .midi = 50, .instrument = .pling },
    .{ .time = 44, .midi = 45, .instrument = .pling },
    .{ .time = 48, .midi = 43, .instrument = .pling },
    .{ .time = 52, .midi = 47, .instrument = .pling },
    .{ .time = 56, .midi = 49, .instrument = .pling },
    .{ .time = 60, .midi = 45, .instrument = .pling },
};

const TotalTime = 64;
const Delta = 4;

const Schedules = [_]u8{
    @intFromEnum(Part.bass) | @intFromEnum(Part.main_a),
    @intFromEnum(Part.bass) | @intFromEnum(Part.main_b) | @intFromEnum(Part.alt_a),
};

fn playNoteTask(ctx: *common.Context, userdata: u64) void {
    const noteData: NoteTaskData = @bitCast(userdata);

    const client = ctx.client_manager.get(noteData.client_fd) orelse return;
    // get location component from player entity
    const l = client.e.get(ctx.entities, common.ecs.Location) orelse return;

    // allocate a buffer of 2^10 bytes
    const b = ctx.buffer_pools.allocBuf(.@"10") catch return;
    // encode sound packet into the buffer
    const size = protocol.ClientPlaySoundEffect.encode(
        &.{
            .sound_name = noteData.instrument.getName(),
            // i genuinely don't know why coordinates must be
            // multiplied by 8 here
            .x = @intFromFloat(l.x * 8),
            .y = @intFromFloat(l.y * 8),
            .z = @intFromFloat(l.z * 8),
            .volume = 1.0,
            .pitch = common.pitchFromMidi(noteData.midi),
        },
        b.ptr,
    ) catch {
        // release buffer if encoding failed
        ctx.buffer_pools.releaseBuf(b.idx);
        return;
    };

    // send buffer to client
    ctx.prepareOneshot(noteData.client_fd, b, size);
}

fn schedulePart(ctx: *common.Context, client_fd: i32, schedule: u8, comptime Array: anytype, comptime P: Part) void {
    if ((schedule & @intFromEnum(P)) != 0x00) {
        for (Array) |note| {
            ctx.scheduler.schedule(&playNoteTask, note.time * Delta + 1, @bitCast(NoteTaskData{ .client_fd = client_fd, .midi = note.midi, .instrument = note.instrument })) catch {};
        }
    }
}

fn scheduleTask(ctx: *common.Context, ud: u64) void {
    const d: ScheduleTaskData = @bitCast(ud);
    _ = ctx.client_manager.get(d.client_fd) orelse return;

    const schedule = Schedules[@intCast(d.schedule)];

    schedulePart(ctx, d.client_fd, schedule, BassPart, Part.bass);
    schedulePart(ctx, d.client_fd, schedule, MainAPart, Part.main_a);
    schedulePart(ctx, d.client_fd, schedule, MainBPart, Part.main_b);
    schedulePart(ctx, d.client_fd, schedule, AltAPart, Part.alt_a);

    ctx.scheduler.schedule(
        &scheduleTask,
        TotalTime * Delta + 1,
        @bitCast(ScheduleTaskData{ .client_fd = d.client_fd, .schedule = @intCast((d.schedule + 1) % Schedules.len) }),
    ) catch {};
}

pub const PachelbelModule = struct {
    _: u8 = 0,

    pub fn init(_: std.mem.Allocator) !PachelbelModule {
        return PachelbelModule{};
    }

    pub fn deinit(_: *PachelbelModule) void {}

    pub fn onJoin(
        ctx: *common.Context,
        client: *common.client.Client,
    ) !void {
        try ctx.scheduler.schedule(&scheduleTask, 1, @bitCast(ScheduleTaskData{ .client_fd = client.fd, .schedule = 0 }));
    }
};
