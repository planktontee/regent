const std = @import("std");
const builtin = @import("builtin");

pub const isDebug = builtin.mode == .Debug;

pub fn asPtrConCast(T: type, value: *const T) *T {
    return @constCast(value);
}

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub fn assertM(predicate: bool, message: ?[]const u8) void {
    @disableInstrumentation();
    if (isDebug and !predicate) {
        if (message != null) std.debug.panic("{s}\n", .{message.?});
        std.debug.assert(predicate);
    }
}

pub fn assertDeepNotUndefined(v: anytype) void {
    if (isDebug) return;

    const vTypeI = @typeInfo(@TypeOf(v));
    if (vTypeI != .@"struct")
        @compileError("assertDeepNotUndefined only supports structs");

    inline for (vTypeI.@"struct".fields) |field| {
        const offset = @offsetOf(@TypeOf(v), field.name);
        const ptr: []const u8 = @as([*]const u8, @ptrFromInt(@as(usize, @intFromPtr(&v) + offset)))[0..@sizeOf(field.type)];
        // This uh super awkward :D, but works more often than not
        var expectedV: [@sizeOf(field.type)]u8 = undefined;
        const expected: []const u8 = expectedV[0..];

        assertM(!std.mem.eql(u8, ptr, expected), "✘ " ++ @typeName(@TypeOf(v)) ++ "." ++ field.name ++ " is undefined");
        if (@typeInfo(field.type) == .@"struct") {
            assertDeepNotUndefined(@field(v, field.name));
        }
    }
}

pub fn RotType(comptime predicate: bool, T: type) type {
    return if (predicate)
        T
    else
        void;
}

pub inline fn rotValue(comptime predicate: bool, value: anytype) RotType(predicate, @TypeOf(value)) {
    return if (predicate) value else {};
}
