const root = @import("root");
const serial = root.serial;
const vga = root.vga;
const vfs = @import("../fs/vfs.zig");

// The logger is intentionally a RAM queue in front of the filesystem.  A
// serial write must never wait for virtio/USB disk I/O; service() performs a
// bounded flush from the foreground shell/tick path instead.  The current sink
// captures the complete COM1 transcript (including user stdout); this is
// deliberate for the first distribution-friendly bring-up phase.
const BUFFER_SIZE: usize = 64 * 1024;
const FLUSH_THRESHOLD: usize = 16 * 1024;
const MAX_LOG_SIZE: u64 = 768 * 1024 * 1024;

var buffer: [BUFFER_SIZE]u8 = undefined;
var buffered: usize = 0;
var dropped: u64 = 0;
var write_errors: u32 = 0;
var log_file: ?*vfs.FileHandle = null;
var log_path: [128]u8 = undefined;
var log_path_len: usize = 0;
var enabled: bool = false;
var initialized: bool = false;
var flush_requested: bool = false;
var flushing: bool = false;

fn serialSink(data: []const u8) void {
    append(data);
}

fn append(data: []const u8) void {
    if (data.len == 0) return;

    if (data.len >= BUFFER_SIZE) {
        @memcpy(buffer[0..], data[data.len - BUFFER_SIZE ..]);
        buffered = BUFFER_SIZE;
        dropped +|= @intCast(data.len - BUFFER_SIZE);
    } else if (buffered + data.len > BUFFER_SIZE) {
        const remove = buffered + data.len - BUFFER_SIZE;
        @memmove(buffer[0 .. buffered - remove], buffer[remove..buffered]);
        buffered -= remove;
        dropped +|= @intCast(remove);
    }

    @memcpy(buffer[buffered .. buffered + data.len], data);
    buffered += data.len;
    if (buffered >= FLUSH_THRESHOLD) flush_requested = true;
}

pub fn init(mount_point: []const u8) bool {
    if (initialized) return enabled;
    if (mount_point.len == 0 or mount_point[0] != '/') return false;

    var file_path: [128]u8 = undefined;
    if (mount_point.len + 11 > file_path.len) return false;
    @memcpy(file_path[0..mount_point.len], mount_point);
    var pos = mount_point.len;
    if (file_path[pos - 1] != '/') {
        file_path[pos] = '/';
        pos += 1;
    }
    const name = "KERNEL.LOG";
    @memcpy(file_path[pos..][0..name.len], name);
    pos += name.len;
    @memcpy(log_path[0..pos], file_path[0..pos]);
    log_path_len = pos;

    const handle = vfs.open(file_path[0..pos], .{ .read = true, .write = true, .create = true, .append = true }) orelse {
        serial.serialWrite("[KLOG] Failed to open ");
        serial.serialWrite(file_path[0..pos]);
        serial.serialWrite("\n");
        return false;
    };

    // Append to an existing boot log. FAT32 honors the append flag; the
    // explicit seek keeps the FAT16 fallback on the same code path.
    if (vfs.stat(file_path[0..pos])) |st| {
        if (st.file_type == .file) {
            if (st.size >= MAX_LOG_SIZE) {
                _ = vfs.truncate(handle, 0);
                _ = vfs.seek(handle, 0);
                serial.serialWrite("[KLOG] log rotated at size limit\n");
            } else {
                _ = vfs.seek(handle, st.size);
            }
        }
    }
    log_file = handle;

    // Messages emitted before FAT32 was mounted are already in serial's boot
    // ring.  Replay them into the RAM queue before switching to live capture.
    serial.replayEarly(serialSink);
    serial.setLogSink(serialSink);
    initialized = true;
    enabled = true;
    flush_requested = true;

    serial.serialWrite("[KLOG] Enabled on ");
    serial.serialWrite(file_path[0..pos]);
    serial.serialWrite("\n");
    return true;
}

pub fn requestFlush() void {
    if (enabled) flush_requested = true;
}

/// Flush at most the currently queued bytes.  This is safe to call from a
/// foreground service point; it is not called from the UART/serial sink.
pub fn service() void {
    if (!enabled) return;
    if (!flush_requested and buffered < FLUSH_THRESHOLD) return;
    flush_requested = false;
    flush();
}

pub fn flush() void {
    if (flushing) return;
    const handle = log_file orelse return;
    flushing = true;
    defer flushing = false;
    var written: usize = 0;
    while (written < buffered) {
        const n = vfs.write(handle, buffer[written..buffered]);
        if (n == 0) {
            write_errors +|= 1;
            flush_requested = true;
            break;
        }
        written += n;
    }
    if (written != 0 and written < buffered) {
        @memmove(buffer[0 .. buffered - written], buffer[written..buffered]);
    }
    if (written != 0) buffered -= written;
}

pub fn shutdown() void {
    if (!enabled) return;
    flush_requested = true;
    flush();
    serial.setLogSink(null);
    enabled = false;
}

pub fn clear() bool {
    const handle = log_file orelse return false;
    if (!vfs.truncate(handle, 0)) return false;
    if (!vfs.seek(handle, 0)) return false;
    buffered = 0;
    flush_requested = true;
    return true;
}

pub fn dump(max_bytes: usize) usize {
    if (!enabled or log_path_len == 0) return 0;
    const handle = vfs.open(log_path[0..log_path_len], .{ .read = true }) orelse return 0;
    defer vfs.close(handle);

    var buf: [256]u8 = undefined;
    var total: usize = 0;
    vga.write("  Kernel log dump: ");
    vga.write(path());
    vga.write("\n");
    while (total < max_bytes) {
        const want = @min(buf.len, max_bytes - total);
        const n = vfs.read(handle, buf[0..want]);
        if (n == 0) break;
        vga.write(buf[0..n]);
        total += n;
    }
    vga.write("\n  [klog] dumped ");
    vga.writeDec(total);
    vga.write(" bytes\n");
    return total;
}

pub fn path() []const u8 {
    return log_path[0..log_path_len];
}

pub fn isEnabled() bool {
    return enabled;
}

pub fn bufferedBytes() usize {
    return buffered;
}

pub fn droppedBytes() u64 {
    return dropped + serial.earlyDropped();
}

pub fn writeErrors() u32 {
    return write_errors;
}
