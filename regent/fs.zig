const std = @import("std");
const builtin = @import("builtin");
const ergo = @import("ergo.zig");
const units = @import("units.zig");
const rlinux = @import("linux.zig");
const Context = ergo.Context;
const File = std.Io.File;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assertM = ergo.assertM;
const assert = std.debug.assert;
const rDir = @import("dir.zig");

const rIO = @This();

pub const BufferType = enum {
    full,
    byte,
    mmap,
};

pub const Mode = enum {
    write,
    read,
};

pub const bufferAlignment = std.mem.Alignment.fromByteUnits(std.simd.suggestVectorLengthForCpu(u8, builtin.cpu) orelse 8);
const oDirectAlignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize());
const blockAlignment = std.mem.Alignment.fromByteUnits(4 * units.ByteUnit.kb);
fn resolveAlignment(comptime oDirect: bool) std.mem.Alignment {
    return if (oDirect) return oDirectAlignment else return bufferAlignment;
}

pub const BufferConfig = struct {
    blockBufferSize: usize,
    fileBufferSize: usize,
    defaultPipeSize: usize,
    maxPipeSize: usize,
    charDeviceBuff: usize,
    unixSocketBuff: usize,

    pub const defaultReaderConfig: BufferConfig = .{
        .blockBufferSize = units.ByteUnit.mb,
        .fileBufferSize = 256 * units.ByteUnit.kb,
        .defaultPipeSize = 64 * units.ByteUnit.kb,
        .maxPipeSize = units.ByteUnit.mb,
        .charDeviceBuff = 1 * units.ByteUnit.kb,
        .unixSocketBuff = 4 * units.ByteUnit.kb,
    };

    pub const defaultWriterConfig: BufferConfig = .{
        .blockBufferSize = units.ByteUnit.mb,
        .fileBufferSize = 256 * units.ByteUnit.kb,
        .defaultPipeSize = 64 * units.ByteUnit.kb,
        .maxPipeSize = units.ByteUnit.mb,
        .charDeviceBuff = 4 * units.ByteUnit.kb,
        .unixSocketBuff = 32 * units.ByteUnit.kb,
    };

    pub fn initSame(size: usize) @This() {
        const newSize = @max(1, size);
        return .{
            .blockBufferSize = newSize,
            .fileBufferSize = newSize,
            .defaultPipeSize = newSize,
            .maxPipeSize = newSize,
            .charDeviceBuff = newSize,
            .unixSocketBuff = newSize,
        };
    }
};

pub fn defaultBufferConfig(mode: Mode) BufferConfig {
    return switch (mode) {
        .read => .defaultReaderConfig,
        .write => .defaultWriterConfig,
    };
}

pub const OpenConfig = struct {
    oDirect: bool = false,
    expandPipe: bool = true,
    followSymlink: bool = true,

    fn convertMode(mode: Mode) std.Io.Dir.OpenFileOptions.Mode {
        return switch (mode) {
            .read => .read_only,
            .write => .write_only,
        };
    }

    pub fn validate(_: @This(), mode: Mode, openFileOptions: std.Io.Dir.OpenFileOptions) OpenError!void {
        if (openFileOptions.mode != convertMode(mode))
            return OpenError.MismatchingOpenFileOptionsAndConfig;
    }

    pub fn toOpenFileOptions(self: @This(), mode: Mode) std.Io.Dir.OpenFileOptions {
        return .{
            .mode = convertMode(mode),
            .follow_symlinks = self.followSymlink,
        };
    }
};

fn setODirect(io: Io, fd: std.os.linux.fd_t) rlinux.SetFdStatusFlagsError!void {
    try rlinux.setFdStatusFlags(io, fd, .{ .DIRECT = true });
}

fn alignODirectSize(size: usize) usize {
    const x = oDirectAlignment.toByteUnits() - 1;
    return @max(1, (size + x) & ~x);
}

fn StreamT(comptime mode: Mode) type {
    return switch (mode) {
        .read => std.Io.File.Reader,
        .write => std.Io.File.Writer,
    };
}

pub fn cwdOpen(io: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!File {
    const cwd = std.Io.Dir.cwd();
    return try cwd.openFile(io, path, options);
}

pub fn expandPipeSize(io: Io, fd: std.os.linux.fd_t, maxSize: usize) bool {
    return if (rlinux.fcntlSetPipeSZ(io, fd, maxSize)) true else |_| false;
}

pub const OpenError = error{
    FileCannotBeOpenedForRead,
    MismatchingOpenFileOptionsAndConfig,
    MMapUsedInStreamingFd,
    TBA,
} ||
    rlinux.SetFdStatusFlagsError ||
    std.Io.File.StatError ||
    std.Io.File.OpenError ||
    std.mem.Allocator.Error ||
    std.posix.MMapError;

pub fn OpenResponse(mode: Mode) type {
    return struct {
        stat: std.Io.File.Stat,
        stream: StreamT(mode),
        alignment: std.mem.Alignment,
    };
}

pub fn open(
    context: Context,
    path: []const u8,
    comptime mode: Mode,
    openConfig: OpenConfig,
    openFileOptions: std.Io.Dir.OpenFileOptions,
    bufferType: BufferType,
    bufferConfig: BufferConfig,
) OpenError!OpenResponse(mode) {
    const file = try cwdOpen(context.io, path, openFileOptions);
    errdefer file.close(context.io);

    return openStream(
        context,
        file,
        mode,
        openConfig,
        bufferType,
        bufferConfig,
    );
}

// Im gonna have to find a way to move Stat out of this method
// Also I will have to change the File.Stat call to a posix.syscall instead to bypass the
// zig parser
// stat has to be Io'd
pub fn openStream(
    context: Context,
    file: File,
    comptime mode: Mode,
    openConfig: OpenConfig,
    bufferType: BufferType,
    bufferConfig: BufferConfig,
) OpenError!OpenResponse(mode) {
    const T = StreamT(mode);
    const openStreamingF: fn (File, std.Io, []u8) T = switch (mode) {
        .read => File.readerStreaming,
        .write => File.writerStreaming,
    };
    const openF: fn (File, std.Io, []u8) T = switch (mode) {
        .read => File.reader,
        .write => File.writer,
    };

    const oDirect = openConfig.oDirect;
    const stat = try file.stat(context.io);
    const statSizeBuff: usize = @max(1, stat.size);
    switch (stat.kind) {
        .character_device,
        => {
            if (bufferType == .mmap) return error.MMapUsedInStreamingFd;

            // Absolutely nothing fancy to do here, char devices are incredibly simple
            // and this is tty oriented, this might be a giant waste for other char devices
            return .{
                .stat = stat,
                .stream = openStreamingF(file, context.io, try context.allocator.alignedAlloc(
                    u8,
                    bufferAlignment,
                    bufferConfig.charDeviceBuff,
                )),
                .alignment = bufferAlignment,
            };
        },
        .named_pipe,
        => {
            if (bufferType == .mmap) return error.MMapUsedInStreamingFd;

            var pipeSize: usize = bufferConfig.defaultPipeSize;
            if (openConfig.expandPipe) {
                // Attempt to set pipesize to 1mb, this is best effort
                if (expandPipeSize(context.io, file.handle, bufferConfig.maxPipeSize))
                    pipeSize = bufferConfig.maxPipeSize;
            }

            // ODirect and types are ignored since pipes can only be read buffered
            return .{
                .stat = stat,
                .stream = openStreamingF(file, context.io, try context.allocator.alignedAlloc(
                    u8,
                    bufferAlignment,
                    pipeSize,
                )),
                .alignment = bufferAlignment,
            };
        },
        .unix_domain_socket,
        => {
            if (bufferType == .mmap) return error.MMapUsedInStreamingFd;
            // ODirect and types are ignored since pipes can only be read buffered
            return .{
                .stat = stat,
                .stream = openStreamingF(file, context.io, try context.allocator.alignedAlloc(
                    u8,
                    bufferAlignment,
                    bufferConfig.unixSocketBuff,
                )),
                .alignment = bufferAlignment,
            };
        },
        .block_device,
        => {
            switch (bufferType) {
                // Block devices dont return size on stat, so they have to be queried some other way
                // mmap and direct works
                .full => return OpenError.TBA,
                .byte,
                => {
                    if (oDirect) try setODirect(context.io, file.handle);
                    return .{
                        .stat = stat,
                        .stream = openF(file, context.io, try context.allocator.alignedAlloc(
                            u8,
                            blockAlignment,
                            if (oDirect) alignODirectSize(bufferConfig.blockBufferSize) else r: {
                                break :r bufferConfig.blockBufferSize;
                            },
                        )),
                        .alignment = blockAlignment,
                    };
                },
                .mmap => return OpenError.TBA,
            }
        },
        .file,
        => {
            switch (bufferType) {
                .full,
                => {
                    if (oDirect) {
                        try setODirect(context.io, file.handle);
                        const alignment = comptime resolveAlignment(true);
                        return .{
                            .stat = stat,
                            .stream = openF(file, context.io, try context.allocator.alignedAlloc(
                                u8,
                                alignment,
                                alignODirectSize(statSizeBuff),
                            )),
                            .alignment = alignment,
                        };
                    } else {
                        const alignment = comptime resolveAlignment(false);
                        return .{
                            .stat = stat,
                            .stream = openF(file, context.io, try context.allocator.alignedAlloc(
                                u8,
                                alignment,
                                statSizeBuff,
                            )),
                            .alignment = alignment,
                        };
                    }
                },
                .byte,
                => {
                    if (oDirect) {
                        try setODirect(context.io, file.handle);
                        const alignment = comptime resolveAlignment(true);
                        return .{
                            .stat = stat,
                            .stream = openF(file, context.io, try context.allocator.alignedAlloc(
                                u8,
                                alignment,
                                alignODirectSize(bufferConfig.fileBufferSize),
                            )),
                            .alignment = alignment,
                        };
                    } else {
                        const alignment = comptime resolveAlignment(false);
                        return .{
                            .stat = stat,
                            .stream = openF(file, context.io, try context.allocator.alignedAlloc(
                                u8,
                                alignment,
                                bufferConfig.fileBufferSize,
                            )),
                            .alignment = alignment,
                        };
                    }
                },
                .mmap,
                => {
                    switch (mode) {
                        .read => {
                            const ptr = try std.posix.mmap(
                                null,
                                // MMAP fails with 0, so min has to 1
                                @max(@as(usize, @intCast(stat.size)), 1),
                                .{ .READ = true },
                                .{ .TYPE = .PRIVATE },
                                file.handle,
                                0,
                            );

                            var stream = openF(file, context.io, ptr);
                            stream.interface.end = stat.size;
                            stream.pos = stat.size;
                            stream.size = stat.size;
                            return .{
                                .stat = stat,
                                .stream = stream,
                                .alignment = std.mem.Alignment.fromByteUnits(std.heap.pageSize()),
                            };
                        },
                        .write => return error.TBA,
                    }
                },
            }
        },
        .sym_link,
        .door,
        .directory,
        .event_port,
        .unknown,
        .whiteout,
        => return OpenError.FileCannotBeOpenedForRead,
    }
}

pub fn FileStream(mode: Mode) type {
    return struct {
        stream: StreamT(mode),
        stat: std.Io.File.Stat,
        bufferType: BufferType = DefaultBufferType,
        alignment: std.mem.Alignment,

        pub const DefaultBufferType: BufferType = .byte;

        pub fn open(
            context: Context,
            path: []const u8,
        ) OpenError!@This() {
            const openConfig: OpenConfig = .{};
            const r = try rIO.open(
                context,
                path,
                mode,
                openConfig,
                openConfig.toOpenFileOptions(mode),
                DefaultBufferType,
                defaultBufferConfig(mode),
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = DefaultBufferType,
                .alignment = r.alignment,
            };
        }

        pub fn openStream(
            context: Context,
            file: File,
        ) OpenError!@This() {
            const r = try rIO.openStream(
                context,
                file,
                mode,
                .{},
                DefaultBufferType,
                defaultBufferConfig(mode),
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = DefaultBufferType,
                .alignment = r.alignment,
            };
        }

        pub fn openWithConfig(
            context: Context,
            path: []const u8,
            openConfig: OpenConfig,
            openFileOptions: std.Io.Dir.OpenFileOptions,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) OpenError!@This() {
            try openConfig.validate(mode, openFileOptions);
            const r = try rIO.open(
                context,
                path,
                mode,
                openConfig,
                openFileOptions,
                bufferType,
                bufferConfig,
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = bufferType,
                .alignment = r.alignment,
            };
        }

        pub fn openStreamWithConfig(
            context: Context,
            file: File,
            openConfig: OpenConfig,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) OpenError!@This() {
            const r = try rIO.openStream(
                context,
                file,
                mode,
                openConfig,
                bufferType,
                bufferConfig,
            );
            return .{
                .stream = r.stream,
                .stat = r.stat,
                .bufferType = bufferType,
                .alignment = r.alignment,
            };
        }

        pub fn fadvise(
            self: @This(),
            context: Context,
            offset: usize,
            len: usize,
            flags: []const rlinux.FADVISE,
        ) void {
            for (flags) |flag| {
                rlinux.fadvise(
                    context.io,
                    self.stream.file.handle,
                    offset,
                    len,
                    flag,
                ) catch continue;
            }
        }

        pub fn close(self: @This(), context: Context) void {
            self.stream.file.close(context.io);
        }

        pub fn deinit(self: *@This(), context: Context) void {
            switch (self.bufferType) {
                .full,
                .byte,
                => {
                    const memory = self.stream.interface.buffer;
                    const slice_info = @typeInfo(@TypeOf(memory)).pointer;
                    comptime assert(slice_info.size == .slice);
                    const bytes: []u8 = @ptrCast(@constCast(std.mem.absorbSentinel(memory)));
                    if (bytes.len == 0) return;
                    @memset(bytes, undefined);

                    context.allocator.rawFree(memory, self.alignment, @returnAddress());
                    self.stream.interface.buffer = undefined;
                },
                .mmap,
                => std.posix.munmap(@alignCast(self.stream.interface.buffer)),
            }
        }
    };
}

pub const FileCursorError = error{
    FollowSymlinkDisabled,
};

pub const FileCursorConfig = struct {
    recursive: bool = true,
    followSymlink: bool = true,
    policy: Policy = r: {
        const p = DefaultFileCursorPolicy{};
        break :r .{ .data = @ptrCast(@constCast(&p)), .interface = &.{
            .open = &DefaultFileCursorPolicy.open,
            .enter = &DefaultFileCursorPolicy.enter,
        } };
    },

    // This is mirrored to avoid the sentinel
    pub const PolicyEntryData = struct {
        dir: std.Io.Dir,
        basename: []const u8,
        path: []const u8,
        kind: File.Kind,
        inode: File.INode,
    };

    pub const PolicyEntry = union(enum) {
        // This means it's not yet handled by the walker
        preWalkerEntry: PolicyEntryData,
        // This means we are inside the walker (recurisve)
        entry: rDir.Walker.Entry,
        stdin,
        stdout,
        stderr,
    };

    pub const PolicyVTable = struct {
        open: *const fn (*anyopaque, PolicyEntry) bool,
        enter: *const fn (*anyopaque, PolicyEntry) bool,
    };

    // Policy checks happen at FileCursor.path resolution
    // Once that's covered, they also happen after entry resolution
    // which, means the path will get tracked through symlink (if toggled)
    // so this isn't a visitor mechanism, this is a matching path mechanism for the
    // return given by FileCursor.next
    pub const Policy = struct {
        data: *anyopaque,
        interface: *const PolicyVTable,
    };

    pub const DefaultFileCursorPolicy = struct {
        pub fn open(_: *anyopaque, _: PolicyEntry) bool {
            return true;
        }

        pub fn enter(_: *anyopaque, _: PolicyEntry) bool {
            return true;
        }
    };
};

pub fn FileCursor(mode: Mode) type {
    return struct {
        paths: []const []const u8,
        i: usize = 0,
        hasTrailingPath: bool = false,
        cursor: ?rDir.Walker = null,
        currentEntry: ?rDir.Walker.Entry = null,
        config: FileCursorConfig = .{},

        pub fn init(paths: []const []const u8) @This() {
            return .{ .paths = paths };
        }

        pub fn initWithConfig(paths: []const []const u8, config: FileCursorConfig) @This() {
            return .{
                .paths = paths,
                .config = config,
            };
        }

        // Current path is guaranteed to be at the path that failed in case you query it
        // after an error return
        pub fn currentPath(self: @This()) ?[]const u8 {
            if (self.i < 1 or self.i > self.paths.len) return null;

            if (self.currentEntry) |entry|
                return entry.path;

            const path = self.paths[self.i - 1];
            return if (self.hasTrailingPath) path[0 .. path.len - 1] else path;
        }

        pub fn next(self: *@This(), context: Context) !?FileStream(mode) {
            return try self.nextWithConfig(
                context,
                .{},
                FileStream(mode).DefaultBufferType,
                defaultBufferConfig(mode),
            );
        }

        fn pickPath(self: *@This()) !?[]const u8 {
            if (self.i >= self.paths.len) return null;
            const path = self.paths[self.i];
            self.i += 1;

            self.hasTrailingPath = path[path.len - 1] == '/';
            return if (self.hasTrailingPath) path[0 .. path.len - 1] else path;
        }

        pub fn nextWithConfig(
            self: *@This(),
            context: Context,
            openConfig: OpenConfig,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) !?FileStream(mode) {
            pathLoop: while (true) {
                if (self.cursor) |*cursor| {
                    while (true) {
                        if (cursor.next(context.io) catch continue) |entry| {
                            switch (entry.kind) {
                                .sym_link, .directory => continue,
                                else => {
                                    if (!self.config.policy.interface.open(self.config.policy.data, .{ .entry = entry })) continue;

                                    self.currentEntry = entry;
                                    const file = try entry.dir.openFile(context.io, entry.basename, .{});
                                    errdefer file.close(context.io);

                                    return try .openStreamWithConfig(
                                        context,
                                        file,
                                        openConfig,
                                        bufferType,
                                        bufferConfig,
                                    );
                                },
                            }
                        } else {
                            self.cursor.?.deinit();
                            self.cursor = null;
                            self.currentEntry = null;
                            continue :pathLoop;
                        }
                    }
                }

                const path = try self.pickPath() orelse return null;
                // In all cases, even if there's an error, we move to i += 1
                // the only case where we dont do that is when we are running the cursor loop at the beginning
                // This means any failure we move forward already
                if (std.mem.eql(u8, "-", path)) {
                    @branchHint(.unlikely);

                    if (!self.config.policy.interface.open(self.config.policy.data, .stdin)) continue;

                    return try .openStreamWithConfig(
                        context,
                        std.Io.File.stdin(),
                        openConfig,
                        bufferType,
                        bufferConfig,
                    );
                }

                const cwd = std.Io.Dir.cwd();
                const maybeFile = try cwd.openFile(context.io, path, openConfig.toOpenFileOptions(.read));
                const stat = maybeFile.stat(context.io) catch |e| {
                    maybeFile.close(context.io);
                    return e;
                };
                switch (stat.kind) {
                    .directory, .sym_link => {
                        if (self.config.recursive) {
                            if (stat.kind == .sym_link and !self.config.followSymlink) {
                                @branchHint(.unlikely);
                                return FileCursorError.FollowSymlinkDisabled;
                            }
                            maybeFile.close(context.io);

                            if (!self.config.policy.interface.enter(self.config.policy.data, .{
                                .preWalkerEntry = .{
                                    .dir = cwd,
                                    .basename = "",
                                    .path = path,
                                    .kind = stat.kind,
                                    .inode = stat.inode,
                                },
                            })) continue;

                            const dir = try cwd.openDir(context.io, path, .{ .iterate = true });
                            errdefer dir.close(context.io);

                            self.cursor = try rDir.walk(
                                context.io,
                                dir,
                                path,
                                context.allocator,
                                self.config.followSymlink,
                                self.config.policy,
                            );

                            continue :pathLoop;
                        } else {
                            maybeFile.close(context.io);
                            return error.FileCannotBeOpenedForRead;
                        }
                    },
                    else => {
                        if (!self.config.policy.interface.open(self.config.policy.data, .{
                            .preWalkerEntry = .{
                                .dir = cwd,
                                .basename = "",
                                .path = path,
                                .kind = stat.kind,
                                .inode = stat.inode,
                            },
                        })) {
                            maybeFile.close(context.io);
                            continue;
                        }

                        errdefer maybeFile.close(context.io);
                        return try .openStreamWithConfig(
                            context,
                            maybeFile,
                            openConfig,
                            bufferType,
                            bufferConfig,
                        );
                    },
                }
            }
        }

        pub fn deinit(self: *@This()) void {
            if (self.cursor) |*cursor| {
                cursor.deinit();
                self.cursor = null;
            }
            self.currentEntry = null;
        }
    };
}
