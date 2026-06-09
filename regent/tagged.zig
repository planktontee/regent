const std = @import("std");

pub fn tagEnum(comptime T: type, ptr: anytype, comptime tag: @typeInfo(T).@"union".tag_type.?) t: {
    const B = @FieldType(T, @tagName(tag));
    break :t if (@typeInfo(@TypeOf(ptr)).pointer.is_const) *const B else *B;
} {
    const TagE = @typeInfo(T).@"union".tag_type.?;
    const tagET = @typeInfo(TagE).@"enum".tag_type;
    const max = std.math.maxInt(tagET);

    if (@typeInfo(tagET).int.signedness != .unsigned or max > 255)
        @compileError("tagEnum only supports tags <= 255");

    var ptrI = @intFromPtr(ptr);
    ptrI |= @as(usize, @intCast(@intFromEnum(tag))) << 56;
    return @ptrFromInt(ptrI);
}

pub fn getTag(comptime T: type, ptr: anytype) @typeInfo(T).@"union".tag_type.? {
    return @enumFromInt((@intFromPtr(ptr) & 0xFF00000000000000) >> 56);
}

pub fn untag(ptr: anytype) @TypeOf(ptr) {
    return @ptrFromInt(@intFromPtr(ptr) & 0x00FFFFFFFFFFFF);
}

test "tagEnum" {
    const T = union(enum) {
        a,
        b: u4,
        c: f32,
    };

    const p: *const f32 = &2.2;
    const tp = tagEnum(T, p, .c);
    try std.testing.expectEqual(
        @as(@typeInfo(T).@"union".tag_type.?, .c),
        getTag(T, tp),
    );
    const up = untag(tp);
    try std.testing.expect(p == up);
}
