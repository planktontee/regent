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

    pub fn initSame(size: usize) @This() {
        return .{
            .blockBufferSize = size,
            .fileBufferSize = size,
            .defaultPipeSize = size,
            .maxPipeSize = size,
            .charDeviceBuff = size,
            .unixSocketBuff = size,
        };
    }
};

const defaultReaderBufferConfig: BufferConfig = .{
    .blockBufferSize = units.ByteUnit.mb,
    .fileBufferSize = 256 * units.ByteUnit.kb,
    .defaultPipeSize = 64 * units.ByteUnit.kb,
    .maxPipeSize = units.ByteUnit.mb,
    .charDeviceBuff = 1 * units.ByteUnit.kb,
    .unixSocketBuff = 4 * units.ByteUnit.kb,
};

const defaultWriterBufferConfig: BufferConfig = .{
    .blockBufferSize = units.ByteUnit.mb,
    .fileBufferSize = 256 * units.ByteUnit.kb,
    .defaultPipeSize = 64 * units.ByteUnit.kb,
    .maxPipeSize = units.ByteUnit.mb,
    .charDeviceBuff = 4 * units.ByteUnit.kb,
    .unixSocketBuff = 32 * units.ByteUnit.kb,
};

pub fn defaultBufferConfig(mode: Mode) BufferConfig {
    return switch (mode) {
        .read => defaultReaderBufferConfig,
        .write => defaultWriterBufferConfig,
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
    return (size + x) & ~x;
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

pub fn open(
    context: Context,
    path: []const u8,
    comptime mode: Mode,
    openConfig: OpenConfig,
    openFileOptions: std.Io.Dir.OpenFileOptions,
    bufferType: BufferType,
    bufferConfig: BufferConfig,
) OpenError!StreamT(mode) {
    const file = try cwdOpen(context.io, path, openFileOptions);
    errdefer file.close(context.io);

    return try openStream(
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
) OpenError!StreamT(mode) {
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
    switch (stat.kind) {
        .character_device,
        => {
            if (bufferType == .mmap) return error.MMapUsedInStreamingFd;

            // Absolutely nothing fancy to do here, char devices are incredibly simple
            // and this is tty oriented, this might be a giant waste for other char devices
            return openStreamingF(file, context.io, try context.allocator.alignedAlloc(
                u8,
                bufferAlignment,
                bufferConfig.charDeviceBuff,
            ));
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
            return openStreamingF(file, context.io, try context.allocator.alignedAlloc(
                u8,
                bufferAlignment,
                pipeSize,
            ));
        },
        .unix_domain_socket,
        => {
            if (bufferType == .mmap) return error.MMapUsedInStreamingFd;
            // ODirect and types are ignored since pipes can only be read buffered
            return openStreamingF(file, context.io, try context.allocator.alignedAlloc(
                u8,
                bufferAlignment,
                bufferConfig.unixSocketBuff,
            ));
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
                    return openF(file, context.io, try context.allocator.alignedAlloc(
                        u8,
                        blockAlignment,
                        if (oDirect) alignODirectSize(bufferConfig.blockBufferSize) else r: {
                            break :r bufferConfig.blockBufferSize;
                        },
                    ));
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
                        return openF(file, context.io, try context.allocator.alignedAlloc(
                            u8,
                            resolveAlignment(true),
                            alignODirectSize(stat.size),
                        ));
                    } else {
                        return openF(file, context.io, try context.allocator.alignedAlloc(
                            u8,
                            resolveAlignment(false),
                            stat.size,
                        ));
                    }
                },
                .byte,
                => {
                    if (oDirect) {
                        try setODirect(context.io, file.handle);
                        return openF(file, context.io, try context.allocator.alignedAlloc(
                            u8,
                            resolveAlignment(true),
                            alignODirectSize(bufferConfig.fileBufferSize),
                        ));
                    } else {
                        return openF(file, context.io, try context.allocator.alignedAlloc(
                            u8,
                            resolveAlignment(false),
                            bufferConfig.fileBufferSize,
                        ));
                    }
                },
                .mmap,
                => {
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
                    return stream;
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

pub fn close(context: Context, bufferType: BufferType, fileStream: anytype) void {
    fileStream.file.close(context.io);

    switch (bufferType) {
        .full,
        .byte,
        => context.allocator.free(fileStream.interface.buffer),
        .mmap,
        => std.posix.munmap(@alignCast(fileStream.interface.buffer)),
    }
}

pub fn FileStream(mode: Mode) type {
    return struct {
        stream: StreamT(mode),
        bufferType: BufferType = DefaultBufferType,

        pub const DefaultBufferType: BufferType = .byte;

        pub fn open(
            context: Context,
            path: []const u8,
        ) OpenError!@This() {
            const openConfig: OpenConfig = .{};
            return .{
                .stream = try rIO.open(
                    context,
                    path,
                    openConfig,
                    openConfig.toOpenFileOptions(mode),
                    DefaultBufferType,
                    defaultBufferConfig(mode),
                ),
                .bufferType = DefaultBufferType,
            };
        }

        pub fn openStream(
            context: Context,
            file: File,
        ) OpenError!@This() {
            const openConfig: OpenConfig = .{};
            return .{
                .stream = try rIO.openStream(
                    context,
                    file,
                    openConfig,
                    DefaultBufferType,
                    defaultBufferConfig(mode),
                ),
                .bufferType = DefaultBufferType,
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
            return .{
                .stream = try rIO.open(
                    context,
                    path,
                    mode,
                    openConfig,
                    openFileOptions,
                    bufferType,
                    bufferConfig,
                ),
                .bufferType = bufferType,
            };
        }

        pub fn openStreamWithConfig(
            context: Context,
            file: File,
            openConfig: OpenConfig,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) OpenError!@This() {
            return .{
                .stream = try rIO.openStream(
                    context,
                    file,
                    mode,
                    openConfig,
                    bufferType,
                    bufferConfig,
                ),
                .bufferType = bufferType,
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
            rIO.close(
                context,
                self.bufferType,
                self.stream,
            );
        }
    };
}

pub const FileCursorError = error{
    FollowSymlinkDisabled,
};

pub fn FileCursor(mode: Mode) type {
    return struct {
        paths: []const []const u8,
        i: usize = 0,
        cursor: ?rDir.Walker = null,
        currentEntry: ?rDir.Walker.Entry = null,
        hasTrailingPath: bool = false,
        recursive: bool = true,
        followSymlink: bool = true,

        pub fn init(paths: []const []const u8) @This() {
            return .{ .paths = paths };
        }

        pub fn initWithFlags(paths: []const []const u8, recursive: bool, followSymlink: bool) @This() {
            return .{
                .paths = paths,
                .recursive = recursive,
                .followSymlink = followSymlink,
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
                        if (self.recursive) {
                            if (stat.kind == .sym_link and !self.followSymlink) {
                                @branchHint(.unlikely);
                                return FileCursorError.FollowSymlinkDisabled;
                            }

                            maybeFile.close(context.io);

                            const dir = try cwd.openDir(context.io, path, .{ .iterate = true });
                            errdefer dir.close(context.io);

                            self.cursor = try rDir.walk(context.io, dir, path, context.allocator, self.followSymlink);

                            continue :pathLoop;
                        } else {
                            maybeFile.close(context.io);
                            return error.FileCannotBeOpenedForRead;
                        }
                    },
                    else => {
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
