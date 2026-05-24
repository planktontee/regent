pub const collections = @import("regent/collections.zig");
pub const meta = @import("regent/meta.zig");
pub const units = @import("regent/units.zig");
pub const result = @import("regent/result.zig");
pub const testing = @import("regent/testing.zig");
pub const ergo = @import("regent/ergo.zig");
pub const fs = @import("regent/fs.zig");
pub const dir = @import("regent/dir.zig");
pub const linux = @import("regent/linux.zig");
pub const xstr = @import("regent/xstr.zig");

comptime {
    _ = collections;
    _ = meta;
    _ = units;
    _ = result;
    _ = testing;
    _ = ergo;
    _ = fs;
    _ = dir;
    _ = linux;
    _ = xstr;
}
