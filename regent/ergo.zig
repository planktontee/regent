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
