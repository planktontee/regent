const std = @import("std");

pub fn asPtrConCast(T: type, value: *const T) *T {
    return @constCast(value);
}

pub const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
};

pub fn assertM(predicate: bool, comptime message: ?[]const u8) void {
    if (!predicate) {
        if (message != null) std.debug.panic("{s}\n", .{message.?});
        std.debug.assert(predicate);
    }
}

pub fn assertDeepNotUndefined(v: anytype) void {
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
