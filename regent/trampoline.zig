const std = @import("std");
const Allocator = std.mem.Allocator;
const units = @import("./units.zig");

// After calling trampoline, DO NOT return anything past this point that has been allocated from the stack allocator
pub fn stackTrampoline(
    R: type,
    // The lower the less code gen is created
    StackSizeType: type,
    init: anytype,
    callback: fn (@TypeOf(init), ?Allocator) R,
    comptime reservedInMibs: usize,
) R {
    const StackSizeTInfo = @typeInfo(StackSizeType);
    if (@typeInfo(StackSizeType) != .int or StackSizeTInfo.int.signedness == .signed) @compileError("StackSizeType must be a uX type");

    const rlimit = std.posix.getrlimit(.STACK) catch return callback(init, null);
    const currMib = rlimit.cur / units.ByteUnit.mb;
    const targetMaxT = std.math.maxInt(StackSizeType);

    if (currMib <= targetMaxT and currMib > 5) {
        switch (@as(StackSizeType, @intCast(currMib))) {
            inline else => |targetMib| {
                if (targetMib <= reservedInMibs) return callback(init, null);

                const target: usize = @intCast(targetMib - reservedInMibs);
                const targetInMib = target * units.ByteUnit.mb;

                return innerStackTrampoline(
                    R,
                    init,
                    targetInMib,
                    callback,
                );
            },
        }
    }

    return callback(init, null);
}

// This is needed to avoid stack allocations unless called
fn innerStackTrampoline(
    R: type,
    init: anytype,
    comptime allocize: usize,
    callback: fn (@TypeOf(init), ?Allocator) R,
) R {
    var buffer: [allocize]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    return callback(init, allocator);
}
