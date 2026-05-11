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
        return @Enum(u0, .exhaustive, &.{}, &.{});
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

    var enumNames: [field_infos.len][]const u8 = undefined;
    for (field_infos, &enumNames) |field, *name| name.* = field.name;
    const IntTag = std.math.IntFittingRange(0, field_infos.len);
    return @Enum(IntTag, .exhaustive, &enumNames, &std.simd.iota(IntTag, enumNames.len));
}

pub fn Array(arr: std.builtin.Type.Array) type {
    return if (arr.sentinel()) |sentinel|
        [arr.len:sentinel]arr.child
    else
        [arr.len]arr.child;
}

pub fn Optional(opt: std.builtin.Type.Optional) type {
    return ?opt.child;
}

pub fn pointerAttributes(ptr: std.builtin.Type.Pointer) std.builtin.Type.Pointer.Attributes {
    return .{
        .@"addrspace" = ptr.address_space,
        .@"align" = ptr.alignment,
        .@"const" = ptr.is_const,
        .@"allowzero" = ptr.is_allowzero,
        .@"volatile" = ptr.is_volatile,
    };
}

pub fn Pointer(ptr: std.builtin.Type.Pointer) type {
    return @Pointer(ptr.size, pointerAttributes(ptr), ptr.child, ptr.sentinel());
}

pub fn Union(uni: std.builtin.Type.Union) type {
    var names: [uni.fields.len][]const u8 = undefined;
    var tTypes: [uni.fields.len]type = undefined;
    var fieldAttrs: [uni.fields.len]std.builtin.Type.UnionField.Attributes = undefined;
    for (&names, &fieldAttrs, &tTypes, uni.fields) |*name, *fieldAttr, *tType, *field| {
        name.* = field.name;
        tType.* = field.type;
        fieldAttr.* = .{ .@"align" = field.alignment };
    }

    return @Union(uni.layout, uni.tag_type, &names, &tTypes, &fieldAttrs);
}
