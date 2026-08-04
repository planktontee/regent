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
pub const mem = @import("regent/mem.zig");
pub const trampoline = @import("regent/trampoline.zig");
pub const tagged = @import("regent/tagged.zig");
pub const hash = @import("regent/hash.zig");
pub const str = @import("regent/str.zig");
pub const sort = @import("regent/sort.zig");
pub const fmt = @import("regent/fmt.zig");

comptime {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
