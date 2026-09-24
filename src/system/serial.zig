const COM1: u16 = 0x3F8;
const EARLY_LOG_CAPACITY: usize = 64 * 1024;

pub const LogSink = *const fn (data: []const u8) void;

var early_log: [EARLY_LOG_CAPACITY]u8 = undefined;
var early_len: usize = 0;
var early_dropped: u32 = 0;
var live_sink: ?LogSink = null;
var in_sink: bool = false;

fn outb(port_addr: u16, val: u8) void {
    asm volatile ("outb %%al, %%dx"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port_addr),
    );
}

fn inb(port_addr: u16) u8 {
    return asm volatile ("inb %%dx, %%al"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port_addr),
    );
}

pub fn init() void {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x0B);

    early_len = 0;
    early_dropped = 0;
    live_sink = null;
    in_sink = false;
}

fn isTransmitEmpty() bool {
    return (inb(COM1 + 5) & 0x20) != 0;
}

/// Poll the receive side of COM1: returns one byte when data is ready.
/// Used by the shell and console stdin so the kernel can be driven over a
/// headless serial link (QEMU -serial stdio).
pub fn pollRead() ?u8 {
    if ((inb(COM1 + 5) & 0x01) == 0) return null;
    return inb(COM1);
}

fn writeChar(ch: u8) void {
    while (!isTransmitEmpty()) {}
    outb(COM1, ch);
}

fn appendEarly(data: []const u8) void {
    if (data.len == 0) return;
    if (data.len >= EARLY_LOG_CAPACITY) {
        @memcpy(early_log[0..], data[data.len - EARLY_LOG_CAPACITY ..]);
        early_len = EARLY_LOG_CAPACITY;
        early_dropped +|= @intCast(data.len - EARLY_LOG_CAPACITY);
        return;
    }

    if (early_len + data.len > EARLY_LOG_CAPACITY) {
        const drop = early_len + data.len - EARLY_LOG_CAPACITY;
        @memmove(early_log[0 .. early_len - drop], early_log[drop..early_len]);
        early_len -= drop;
        early_dropped +|= @intCast(drop);
    }
    @memcpy(early_log[early_len .. early_len + data.len], data);
    early_len += data.len;
}

fn capture(data: []const u8) void {
    if (live_sink) |sink| {
        if (!in_sink) {
            in_sink = true;
            sink(data);
            in_sink = false;
        }
    } else {
        appendEarly(data);
    }
}

fn emit(data: []const u8) void {
    for (data) |ch| writeChar(ch);
    capture(data);
}

pub fn setLogSink(sink: ?LogSink) void {
    live_sink = sink;
}

/// Replay messages emitted before a filesystem-backed sink was available.
/// The callback must only copy data into RAM; disk I/O belongs in flush().
pub fn replayEarly(sink: LogSink) void {
    if (early_len != 0) {
        in_sink = true;
        sink(early_log[0..early_len]);
        in_sink = false;
    }
    early_len = 0;
}

pub fn earlyDropped() u32 {
    return early_dropped;
}

pub fn serialWrite(str: []const u8) void {
    emit(str);
}

pub fn serialWriteHex(value: u64) void {
    const hex = "0123456789ABCDEF";
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        buf[15 - i] = hex[(value >> @intCast(i * 4)) & 0xF];
    }
    emit(buf[0..]);
}

pub fn serialWriteHexShort(value: u64) void {
    const hex = "0123456789ABCDEF";
    var buf: [16]u8 = undefined;
    var pos: usize = buf.len;
    var started = false;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        const nibble: u8 = @intCast((value >> @intCast(i * 4)) & 0xF);
        if (nibble != 0 or started or i == 0) {
            started = true;
            pos -= 1;
            buf[pos] = hex[nibble];
        }
    }
    emit(buf[pos..]);
}

pub fn serialWriteDec(value: u64) void {
    if (value == 0) {
        emit("0");
        return;
    }
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var v = value;
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    emit(buf[i..]);
}
