//! A socket reader where every read has a timeout.
//!
//! Socket-level timeouts (SO_RCVTIMEO) cannot be used: the read then fails
//! with EAGAIN, which `std.Io.Threaded` treats as a programmer bug and
//! panics on. This reader asks `Io` itself for a timeout instead. It is
//! `std.Io.net.Stream.Reader` without control messages, plus the timeout.

const std = @import("std");
const Io = std.Io;

pub const TimedReader = struct {
    io: Io,
    interface: Io.Reader,
    stream: Io.net.Stream,
    timeout: Io.Duration,
    /// Why the last read failed, when `interface` returned error.ReadFailed.
    err: ?anyerror = null,

    const max_iovecs_len = 8;

    pub fn init(stream: Io.net.Stream, io: Io, buffer: []u8, timeout: Io.Duration) TimedReader {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .stream = stream,
            .timeout = timeout,
        };
    }

    fn streamImpl(io_r: *Io.Reader, io_w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [max_iovecs_len][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const result = r.io.operateTimeout(
            .{ .net_read = .{ .socket_handle = r.stream.socket.handle, .data = dest } },
            .{ .duration = .{ .raw = r.timeout, .clock = .awake } },
        ) catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        const read = result.net_read catch |err| {
            r.err = err;
            return error.ReadFailed;
        };
        if (read.data_len == 0) return error.EndOfStream;
        if (read.data_len > data_size) {
            r.interface.end += read.data_len - data_size;
            return data_size;
        }
        return read.data_len;
    }
};
