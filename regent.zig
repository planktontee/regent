pub const collections = @import("regent/collections.zig");
pub const meta = @import("regent/meta.zig");
pub const units = @import("regent/units.zig");
pub const result = @import("regent/result.zig");
pub const testing = @import("regent/testing.zig");

comptime {
    _ = collections;
    _ = meta;
    _ = units;
    _ = result;
    _ = testing;
}
