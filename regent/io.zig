const std = @import("std");
const builtin = @import("builtin");
const ergo = @import("ergo.zig");
const units = @import("units.zig");
const Context = ergo.Context;
const File = std.Io.File;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assertM = ergo.assertM;
const assert = std.debug.assert;

const io = @This();

pub const BufferType = enum {
    full,
    byte,
    mmap,
};

pub const ExtraOptions = packed struct {
    oDirect: bool = false,
    expandPipe: bool = true,
    followSymlink: bool = true,
};

pub const OpenMode = enum {
    write,
    read,
};

const bufferAlignment = std.mem.Alignment.fromByteUnits(std.simd.suggestVectorLengthForCpu(u8, builtin.cpu) orelse 8);
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

pub const OpenConfig = struct {
    extraOptions: ExtraOptions = .{},
    // Not to be confused with std.Io.Dir.OpenFileOptions.Mode
    // this guy makes far less sense than std.Io.Dir.OpenFileOptions.Mode because its tied ot the return of open
    // rather than the way the file is opened, the reason for that is convenience, you can use
    // open(...) to open a file with .read_write and get a writer and then call openIo with .openMode = .reader
    // to get a writer without reopening the fd
    mode: OpenMode = .read,

    fn convertMode(self: @This()) std.Io.Dir.OpenFileOptions.Mode {
        return switch (self.mode) {
            .read => .read_only,
            .write => .write_only,
        };
    }

    pub fn validate(self: @This(), openFileOptions: std.Io.Dir.OpenFileOptions) OpenError!void {
        if (openFileOptions.mode != self.convertMode())
            return OpenError.MismatchingOpenFileOptionsAndConfig;
    }

    pub fn makeOpenFileOptions(self: @This()) std.Io.Dir.OpenFileOptions {
        return .{
            .mode = self.convertMode(),
            .follow_symlinks = self.extraOptions.followSymlink,
        };
    }

    pub fn bufferConfig(self: @This()) BufferConfig {
        return switch (self.mode) {
            .read => defaultReaderBufferConfig,
            .write => defaultWriterBufferConfig,
        };
    }
};

pub const ExtraFlagsError = error{FailedToSetExtraFlags};

pub const OpenError = error{
    FileCannotBeOpenedForRead,
    MismatchingOpenFileOptionsAndConfig,
    TBA,
} ||
    ExtraFlagsError ||
    std.Io.File.StatError ||
    std.Io.File.OpenError ||
    std.mem.Allocator.Error ||
    std.posix.MMapError;

fn setODirect(fd: std.c.fd_t) ExtraFlagsError!void {
    const flags: i64 = @bitCast(std.os.linux.fcntl(fd, std.os.linux.F.GETFL, 0));
    if (flags < 0) return ExtraFlagsError.FailedToSetExtraFlags;

    var o: std.os.linux.O = @bitCast(@as(i32, @intCast(flags)));
    o.DIRECT = true;

    const rc: i64 = @bitCast(std.os.linux.fcntl(fd, std.os.linux.F.SETFL, @intCast(@as(u32, @bitCast(o)))));
    if (rc < 0) return ExtraFlagsError.FailedToSetExtraFlags;
}

fn alignODirectSize(size: usize) usize {
    const x = oDirectAlignment.toByteUnits() - 1;
    return (size + x) & ~x;
}

fn openR(comptime mode: OpenMode) type {
    return switch (mode) {
        .read => std.Io.File.Reader,
        .write => std.Io.File.Writer,
    };
}

pub fn cwdOpen(stdio: std.Io, path: []const u8, options: std.Io.Dir.OpenFileOptions) std.Io.File.OpenError!File {
    const cwd = std.Io.Dir.cwd();
    return try cwd.openFile(stdio, path, options);
}

pub fn open(
    context: Context,
    path: []const u8,
    comptime openConfig: OpenConfig,
    openFileOptions: std.Io.Dir.OpenFileOptions,
    bufferType: BufferType,
    bufferConfig: BufferConfig,
) OpenError!openR(openConfig.mode) {
    const file = try cwdOpen(context.io, path, openFileOptions);
    errdefer file.close(context.io);

    return try openStream(
        context,
        file,
        openConfig,
        bufferType,
        bufferConfig,
    );
}

pub fn openStream(
    context: Context,
    file: File,
    comptime openConfig: OpenConfig,
    bufferType: BufferType,
    bufferConfig: BufferConfig,
) OpenError!openR(openConfig.mode) {
    const T = openR(openConfig.mode);
    const openStreamingF: fn (File, std.Io, []u8) T = switch (openConfig.mode) {
        .read => File.readerStreaming,
        .write => File.writerStreaming,
    };
    const openF: fn (File, std.Io, []u8) T = switch (openConfig.mode) {
        .read => File.reader,
        .write => File.writer,
    };

    const oDirect = openConfig.extraOptions.oDirect;
    const stat = try file.stat(context.io);
    switch (stat.kind) {
        .character_device,
        => {
            // Absolutely nothing fancy to do here, char devices are incredibly simple
            // and this is tty oriented, this might be a giant waste for other char devices
            return openStreamingF(
                file,
                context.io,
                try context.allocator.alignedAlloc(
                    u8,
                    bufferAlignment,
                    bufferConfig.charDeviceBuff,
                ),
            );
        },
        .named_pipe,
        => {
            var pipeSize: usize = bufferConfig.defaultPipeSize;
            if (openConfig.extraOptions.expandPipe) {
                // Attempt to set pipesize to 1mb, this is best effort
                const rc: i64 = @bitCast(std.os.linux.fcntl(file.handle, std.os.linux.F.SETPIPE_SZ, bufferConfig.maxPipeSize));
                if (rc > 0) pipeSize = bufferConfig.defaultPipeSize;
            }

            // ODirect and types are ignored since pipes can only be read buffered
            return openStreamingF(
                file,
                context.io,
                try context.allocator.alignedAlloc(
                    u8,
                    bufferAlignment,
                    pipeSize,
                ),
            );
        },
        .unix_domain_socket,
        => {
            // ODirect and types are ignored since pipes can only be read buffered
            return openStreamingF(
                file,
                context.io,
                try context.allocator.alignedAlloc(
                    u8,
                    bufferAlignment,
                    bufferConfig.unixSocketBuff,
                ),
            );
        },
        .block_device,
        => {
            switch (bufferType) {
                // Block devices dont return size on stat, so they have to be queried some other way
                // mmap and direct works
                .full,
                => return OpenError.TBA,
                .byte,
                => {
                    if (oDirect) try setODirect(file.handle);
                    return openF(
                        file,
                        context.io,
                        try context.allocator.alignedAlloc(
                            u8,
                            blockAlignment,
                            if (oDirect) alignODirectSize(bufferConfig.blockBufferSize) else bufferConfig.blockBufferSize,
                        ),
                    );
                },
                .mmap,
                => return OpenError.TBA,
            }
        },
        .file,
        => {
            switch (bufferType) {
                .full,
                => {
                    if (oDirect) try setODirect(file.handle);
                    return openF(
                        file,
                        context.io,
                        try context.allocator.alignedAlloc(
                            u8,
                            resolveAlignment(oDirect),
                            if (oDirect) alignODirectSize(stat.size) else stat.size,
                        ),
                    );
                },
                .byte,
                => {
                    if (oDirect) try setODirect(file.handle);
                    return openF(
                        file,
                        context.io,
                        try context.allocator.alignedAlloc(
                            u8,
                            resolveAlignment(oDirect),
                            if (oDirect) alignODirectSize(bufferConfig.fileBufferSize) else bufferConfig.fileBufferSize,
                        ),
                    );
                },
                .mmap,
                => {
                    const ptr = try std.posix.mmap(
                        null,
                        @intCast(stat.size),
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

pub fn fadvise(comptime openConfig: OpenConfig, fileStream: openR(openConfig.mode), comptime flags: anytype) void {
    if (fileStream.size == null) return;
    const compMessage: []const u8 = "regent.io.fadvise only supports comptime_int mapped inside std.c.POSIX_FADV\n";
    const FlagsT = @TypeOf(flags);
    const FlagsTInfo = @typeInfo(@TypeOf(flags));
    var tupleFlags = flags;

    if (FlagsT == comptime_int) tupleFlags = .{flags};
    if (FlagsTInfo == .@"struct" and FlagsTInfo.@"struct".is_tuple) {
        inline for (FlagsTInfo.@"struct".fields) |field| {
            if (@typeInfo(field.type) != .int) @compileError(compMessage);

            _ = std.os.linux.fadvise(
                fileStream.file.handle,
                0,
                @bitCast(fileStream.size.?),
                field.defaultValue().?,
            );
        }
    } else {
        @compileError(compMessage);
    }
}

pub fn close(context: Context, comptime openConfig: OpenConfig, bufferType: BufferType, fileStream: openR(openConfig.mode)) void {
    fileStream.file.close(context.io);

    switch (bufferType) {
        .full,
        .byte,
        => context.allocator.free(fileStream.interface.buffer),
        .mmap,
        => std.posix.munmap(@alignCast(fileStream.interface.buffer)),
    }
}

pub fn FileStream(openConfig: OpenConfig) type {
    return struct {
        fileStream: openR(openConfig.mode),
        bufferType: BufferType = DefaultBufferType,

        const DefaultBufferType: BufferType = .byte;

        pub fn open(
            context: Context,
            path: []const u8,
        ) OpenError!@This() {
            const openFileOptions = openConfig.makeOpenFileOptions();
            try openConfig.validate(openFileOptions);
            return .{
                .fileStream = try io.open(
                    context,
                    path,
                    openConfig,
                    openFileOptions,
                    DefaultBufferType,
                    openConfig.bufferConfig(),
                ),
                .bufferType = DefaultBufferType,
            };
        }

        pub fn openStream(
            context: Context,
            file: File,
        ) OpenError!@This() {
            return .{
                .fileStream = try io.openStream(
                    context,
                    file,
                    openConfig,
                    DefaultBufferType,
                    openConfig.bufferConfig(),
                ),
                .bufferType = DefaultBufferType,
            };
        }

        pub fn openWithBufferConfig(
            context: Context,
            path: []const u8,
            openFileOptions: std.Io.Dir.OpenFileOptions,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) OpenError!@This() {
            try openConfig.validate(openFileOptions);
            return .{
                .fileStream = try io.open(
                    context,
                    path,
                    openConfig,
                    openFileOptions,
                    bufferType,
                    bufferConfig,
                ),
                .bufferType = bufferType,
            };
        }

        pub fn openStreamWithBufferConfig(
            context: Context,
            file: File,
            bufferType: BufferType,
            bufferConfig: BufferConfig,
        ) OpenError!@This() {
            return .{
                .fileStream = try io.openStream(
                    context,
                    file,
                    openConfig,
                    bufferType,
                    bufferConfig,
                ),
                .bufferType = bufferType,
            };
        }

        pub fn fadvise(self: @This(), comptime flags: anytype) void {
            io.fadvise(openConfig, self.fileStream, flags);
        }

        pub fn close(self: @This(), context: Context) void {
            io.close(context, openConfig, self.bufferType, self.fileStream);
        }
    };
}

pub fn FileCursor(openConfig: OpenConfig) type {
    return struct {
        paths: []const []const u8,
        i: usize = 0,

        pub fn init(paths: []const []const u8) @This() {
            return .{ .paths = paths };
        }

        pub fn lastPath(self: @This()) ?[]const u8 {
            if (self.i < 1 or self.i > self.paths.len) return null;
            return self.paths[self.i - 1];
        }

        pub fn peekPath(self: @This()) ?[]const u8 {
            if (self.i >= self.paths.len) return null;
            return self.paths[self.i];
        }

        pub fn hasNext(self: *@This()) bool {
            return self.i < self.paths.len;
        }

        pub fn next(self: *@This(), context: Context) OpenError!?FileStream(openConfig) {
            return try self.nextWithBuffConfig(
                context,
                FileStream(openConfig).DefaultBufferType,
                openConfig.bufferConfig(),
            );
        }

        pub fn nextWithBuffConfig(self: *@This(), context: Context, bufferType: BufferType, bufferConfig: BufferConfig) OpenError!?FileStream(openConfig) {
            const path = self.peekPath() orelse return null;
            // On error we move forward, which is fine
            defer self.i += 1;

            if (std.mem.eql(u8, "-", path)) {
                return try .openStreamWithBufferConfig(
                    context,
                    std.Io.File.stdin(),
                    bufferType,
                    bufferConfig,
                );
            }

            return try .openWithBufferConfig(
                context,
                path,
                openConfig.makeOpenFileOptions(),
                bufferType,
                bufferConfig,
            );
        }
    };
}
