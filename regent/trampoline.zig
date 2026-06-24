const std = @import("std");
const Allocator = std.mem.Allocator;
const units = @import("./units.zig");

// After calling trampoline, DO NOT return anything past this point that has been allocated from the stack allocator
pub fn stackTrampoline(
    // The lower the less code gen is created
    StackSizeType: type,
    comptime reservedInMibs: usize,
    f: anytype,
    args: @typeInfo(@TypeOf(f)).@"fn".params[0].type.?,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    if (@typeInfo(@TypeOf(args)).@"struct".fields[0].type != ?std.mem.Allocator)
        @compileError("First arg of stackTrampoline(..., f, ...) has to be ?std.mem.Allocator");

    const StackSizeTInfo = @typeInfo(StackSizeType);
    if (@typeInfo(StackSizeType) != .int or StackSizeTInfo.int.signedness == .signed) @compileError("StackSizeType must be a uX type");

    const rlimit = std.posix.getrlimit(.STACK) catch {
        var a = args;
        a.@"0" = null;
        return f(a);
    };
    const currMib = rlimit.cur / units.ByteUnit.mb;
    const targetMaxT = std.math.maxInt(StackSizeType);

    if (currMib <= targetMaxT and currMib > 5) {
        switch (@as(StackSizeType, @intCast(currMib))) {
            inline else => |targetMib| {
                if (targetMib <= reservedInMibs) {
                    var a = args;
                    a.@"0" = null;
                    return f(a);
                }

                const target: usize = @intCast(targetMib - reservedInMibs);
                const targetInMib = target * units.ByteUnit.mb;

                return innerStackTrampoline(targetInMib, f, args);
            },
        }
    }

    var a = args;
    a.@"0" = null;
    return f(a);
}

// This is needed to avoid stack allocations unless called
fn innerStackTrampoline(
    comptime allocSize: usize,
    f: anytype,
    args: @typeInfo(@TypeOf(f)).@"fn".params[0].type.?,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    var buffer: [allocSize]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var a = args;

    // TODO: figure out if we need the threadSafe version
    a.@"0" = fba.allocator();
    return f(a);
}
