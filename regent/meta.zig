const std = @import("std");
const compPrint = std.fmt.comptimePrint;
const Allocator = std.mem.Allocator;

pub fn stringToEnum(comptime T: type, str: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |enumField| {
        if (std.mem.eql(u8, str, enumField.name)) {
            return @field(T, enumField.name);
        }
    }
    return null;
}

pub fn isUndefined(field: std.builtin.Type.StructField) bool {
    // NOTE: https://github.com/ziglang/zig/issues/18047#issuecomment-1818265581
    // Apparently not IB but would keep an eye on this
    return comptime field.default_value_ptr != null and field.default_value_ptr.? == @as(*const anyopaque, @ptrCast(&@as(field.type, undefined)));
}

pub fn FieldEnum(comptime T: type) type {
    const field_infos = std.meta.fields(T);

    if (field_infos.len == 0) {
        return @Type(.{
            .@"enum" = .{
                .tag_type = u0,
                .fields = &.{},
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    }

    if (@typeInfo(T) == .@"union") {
        if (@typeInfo(T).@"union".tag_type) |tag_type| {
            for (std.enums.values(tag_type), 0..) |v, i| {
                if (@intFromEnum(v) != i) break; // enum values not consecutive
                if (!std.mem.eql(u8, @tagName(v), field_infos[i].name)) break; // fields out of order
            } else {
                return tag_type;
            }
        }
    }

    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    var decls = [_]std.builtin.Type.Declaration{};
    inline for (field_infos, 0..) |field, i| {
        enumFields[i] = .{
            .name = field.name ++ "",
            .value = i,
        };
    }
    return @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, field_infos.len),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
}
