const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const rIo = @import("io.zig");
const units = @import("units.zig");
const Context = @import("ergo.zig").Context;

pub const Entry = struct {};

pub const DirReader = struct {
    reader: Dir.Reader,
    readerBuffer: []align(rIo.bufferAlignment.toByteUnits()) u8,

    pub const InitError = Allocator.Error;

    pub fn init(dir: Dir, allocator: Allocator) InitError!@This() {
        const buff = try allocator.alignedAlloc(
            u8,
            rIo.bufferAlignment,
            64 * units.ByteUnit.kb,
        );

        // need to use posix.fstat instead of Io.vtable because Dir.Stat and File.Stat
        // doesnt return st_dev
        // this means I might have to code Io support for those calls
        // it's a copy-paste but it sucks
        // stat has to be Io'd

        return .{
            .reader = .{
                .dir = dir,
                .state = .reset,
                .index = 0,
                .end = 0,
                .buffer = buff,
            },
            .readerBuffer = buff,
        };
    }

    pub const NextError = Dir.Reader.Error;

    pub fn next(
        dr: *@This(),
        io: Io,
    ) NextError!?Entry {
        // the least Threaded.io.vtable.dirRead (as dirReadLinux) takes is 1 entry,
        // everything > 1 entry will be buffered, but at least 1 entry has to be 'parsed'
        // to Entry
        //
        // Size of buffer: []Entry is best effort, but has to be allocated and because the struct
        // is not the same as linux_dirent, it's largely a waste to even try to handle it
        //
        // if buffer is always taken from a known position (0), you can walk the entries
        // if you move if for a ring buffer, you will be reading less entries, so it's best to keep
        // this and allow the upstream to close the bucket of entries we are working on
        //
        // dirRead only lazily parses the results inside, so while it does contain multiple entries
        // it's impossible to know how many until all entries are traversed at least once
        //
        // we can keep chunking the slice of buffered and parsing on every next call, once something is not returned
        // we can call read again
        // first entry needs to be completely discarded on sight
        //
        const buff: [1]Entry = undefined;
        const optEntry = try dr.reader.read(io, &buff);
        if (optEntry == null) return null;

        return buff[0];
    }

    pub fn deinit(dr: *@This(), allocator: Allocator) void {
        allocator.free(dr.readerBuffer);
        dr.readerBuffer = undefined;
        dr.* = undefined;
    }
};
