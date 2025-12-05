const std = @import("std");

const Context = @import("mod.zig").Context;

const WHEEL_COUNT = 4;
const SLOTS_PER_WHEEL = 256;

pub const TaskCallback = *const fn (ctx: *Context, userdata: u64) void;

pub const Task = struct {
    callback: TaskCallback,
    expiry: usize,
    userdata: u64,
};

const TaskNode = struct {
    node: std.SinglyLinkedList.Node,
    data: Task,
};

pub const Scheduler = struct {
    wheels: [WHEEL_COUNT][SLOTS_PER_WHEEL]std.SinglyLinkedList,
    current_time: usize,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Scheduler {
        var wheels: [WHEEL_COUNT][SLOTS_PER_WHEEL]std.SinglyLinkedList = undefined;

        for (&wheels) |*wheel| {
            for (wheel) |*slot| {
                slot.first = null;
            }
        }

        return Scheduler{
            .wheels = wheels,
            .current_time = 0,
            .alloc = alloc,
        };
    }

    pub fn schedule(self: *Scheduler, callback: TaskCallback, delay: usize, userdata: u64) !void {
        const node = try self.alloc.create(TaskNode);
        node.data.callback = callback;
        node.data.expiry = self.current_time + delay;
        node.data.userdata = userdata;
        node.node.next = null;

        self.insertNode(node);
    }

    pub fn tick(self: *Scheduler, ctx: *Context) void {
        const slot_idx = self.current_time & (SLOTS_PER_WHEEL - 1);
        while (self.wheels[0][slot_idx].popFirst()) |node| {
            const task: *TaskNode = @fieldParentPtr("node", node);
            task.data.callback(ctx, task.data.userdata);
            self.alloc.destroy(task);
        }

        var time = self.current_time + 1;
        var wheel_idx: usize = 0;

        while ((time & (SLOTS_PER_WHEEL - 1)) == 0 and wheel_idx < WHEEL_COUNT - 1) {
            time >>= 8;
            wheel_idx += 1;

            while (self.wheels[wheel_idx][time & (SLOTS_PER_WHEEL - 1)].popFirst()) |node| {
                const task_node: *TaskNode = @fieldParentPtr("node", node);
                self.insertNode(task_node);
            }
        }

        self.current_time += 1;
    }

    fn insertNode(self: *Scheduler, node: *TaskNode) void {
        const delay = node.data.expiry -| self.current_time;

        var wheel_idx: usize = 0;
        var limit: usize = SLOTS_PER_WHEEL;
        while (delay >= limit and wheel_idx < WHEEL_COUNT - 1) {
            limit *= SLOTS_PER_WHEEL;
            wheel_idx += 1;
        }

        const shift = @as(u6, @intCast(wheel_idx * 8));
        const slot_idx = (node.data.expiry >> shift) & (SLOTS_PER_WHEEL - 1);

        self.wheels[wheel_idx][slot_idx].prepend(&node.node);
    }

    pub fn deinit(self: *Scheduler) void {
        for (&self.wheels) |*wheel| {
            for (wheel) |*slot| {
                while (slot.popFirst()) |node| {
                    const task: *TaskNode = @fieldParentPtr("node", node);
                    self.alloc.destroy(task);
                }
            }
        }
    }
};
