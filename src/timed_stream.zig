//! A socket reader and writer where every operation has a timeout (R3.4).
//!
//! Socket-level timeouts (SO_RCVTIMEO, SO_SNDTIMEO) cannot be used: the
//! call then fails with EAGAIN, which `std.Io.Threaded` treats as a
//! programmer bug and panics on. These ask `Io` itself for a timeout
//! instead. They are `std.Io.net.Stream.Reader` and `.Writer` without
//! control messages, plus the timeouts.

const std = @import("std");
const Io = std.Io;

pub const TimedReader = struct {
    io: Io,
    interface: Io.Reader,
    stream: Io.net.Stream,
    /// Each read must finish within this long.
    timeout: Io.Duration,
    /// When set, reads also fail once this moment passes, however steadily
    /// bytes arrive. Bounds the time to send a request head.
    deadline: ?Io.Clock.Timestamp = null,
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
        const idle_end: Io.Clock.Timestamp = .fromNow(r.io, .{ .raw = r.timeout, .clock = .awake });
        const end = if (r.deadline) |d| (if (d.raw.nanoseconds < idle_end.raw.nanoseconds) d else idle_end) else idle_end;
        const result = r.io.operateTimeout(
            .{ .net_read = .{ .socket_handle = r.stream.socket.handle, .data = dest } },
            .{ .deadline = end },
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

pub const TimedWriter = struct {
    io: Io,
    interface: Io.Writer,
    stream: Io.net.Stream,
    /// Each write must finish within this long. A client that stops reading
    /// fills the socket buffer, and the write then times out.
    timeout: Io.Duration,
    /// Why the last write failed, when `interface` returned error.WriteFailed.
    err: ?anyerror = null,

    pub fn init(stream: Io.net.Stream, io: Io, buffer: []u8, timeout: Io.Duration) TimedWriter {
        return .{
            .io = io,
            .interface = .{
                .vtable = &.{ .drain = drain, .sendFile = sendFile },
                .buffer = buffer,
            },
            .stream = stream,
            .timeout = timeout,
        };
    }

    fn drain(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *TimedWriter = @alignCast(@fieldParentPtr("interface", io_w));
        const result = w.io.operateTimeout(.{ .net_write = .{
            .socket_handle = w.stream.socket.handle,
            .header = io_w.buffered(),
            .data = data,
            .splat = splat,
        } }, .{ .duration = .{ .raw = w.timeout, .clock = .awake } }) catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        const n = result.net_write catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }

    /// No timed file-to-socket path; `Io.Writer` falls back to read and write.
    fn sendFile(_: *Io.Writer, _: *Io.File.Reader, _: Io.Limit) Io.Writer.FileError!usize {
        return error.Unimplemented;
    }
};
