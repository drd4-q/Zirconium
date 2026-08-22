const std = @import("std");
const root = @import("root");
const vga = root.vga;
const vfs = @import("../fs/vfs.zig");
const serial = @import("../system/serial.zig");

const MAX_PATH: usize = 256;

pub fn cmdLs(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    var path_len: usize = 0;

    if (args.len == 0) {
        // Default: current directory
        const cwd = vfs.getCwd();
        for (cwd) |ch| {
            if (path_len < MAX_PATH) {
                path_buf[path_len] = ch;
                path_len += 1;
            }
        }
    } else {
        for (args) |ch| {
            if (path_len < MAX_PATH) {
                path_buf[path_len] = ch;
                path_len += 1;
            }
        }
    }

    var entries: [128]vfs.DirEntry = undefined;
    const count = vfs.readdir(path_buf[0..path_len], &entries);

    if (count == 0) {
        // Check if it's a file
        if (vfs.stat(path_buf[0..path_len])) |st| {
            if (st.file_type == .file) {
                printFileEntry(path_buf[0..path_len], st);
                return;
            }
        }
        vga.setColor(.light_gray, .black);
        vga.write("  (empty)\n");
        vga.setColor(.white, .black);
        return;
    }

    // Sort entries alphabetically (simple bubble sort)
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j = i + 1;
        while (j < count) : (j += 1) {
            if (compareNames(&entries[j].name, entries[j].name_len, &entries[i].name, entries[i].name_len) < 0) {
                const tmp = entries[i];
                entries[i] = entries[j];
                entries[j] = tmp;
            }
        }
    }

    i = 0;
    while (i < count) : (i += 1) {
        printDirEntry(&entries[i]);
    }
}

fn compareNames(a: []const u8, a_len: usize, b: []const u8, b_len: usize) i32 {
    const min_len = if (a_len < b_len) a_len else b_len;
    var k: usize = 0;
    while (k < min_len) : (k += 1) {
        if (a[k] < b[k]) return -1;
        if (a[k] > b[k]) return 1;
    }
    if (a_len < b_len) return -1;
    if (a_len > b_len) return 1;
    return 0;
}

fn printDirEntry(entry: *const vfs.DirEntry) void {
    const name = entry.name[0..entry.name_len];

    if (entry.file_type == .directory) {
        vga.setColor(.light_cyan, .black);
        vga.write("  ");
        vga.write(name);
        vga.write("/\n");
    } else {
        printFileEntry(name, .{
            .file_type = entry.file_type,
            .size = entry.size,
            .inode = 0,
        });
    }
    vga.setColor(.white, .black);
}

fn printFileEntry(name: []const u8, st: vfs.StatInfo) void {
    vga.setColor(.white, .black);
    vga.write("  ");
    vga.write(name);
    var pad: usize = name.len;
    while (pad < 30) : (pad += 1) {
        vga.putChar(' ');
    }
    vga.writeDec(st.size);
    vga.write(" bytes\n");
}

pub fn cmdCat(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: cat <file>\n");
        vga.setColor(.white, .black);
        return;
    }

    const handle = vfs.open(args, .{ .read = true }) orelse {
        vga.setColor(.light_red, .black);
        vga.write("  cat: ");
        vga.write(args);
        vga.write(": No such file\n");
        vga.setColor(.white, .black);
        return;
    };
    defer vfs.close(handle);

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = vfs.read(handle, &buf);
        if (n == 0) break;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            vga.putChar(buf[i]);
        }
    }
    vga.putChar('\n');
}

pub fn cmdTouch(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: touch <file>\n");
        vga.setColor(.white, .black);
        return;
    }

    const handle = vfs.open(args, .{ .create = true, .write = true }) orelse {
        vga.setColor(.light_red, .black);
        vga.write("  touch: ");
        vga.write(args);
        vga.write(": Failed to create\n");
        vga.setColor(.white, .black);
        return;
    };
    vfs.close(handle);
}

pub fn cmdMkdir(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: mkdir <directory>\n");
        vga.setColor(.white, .black);
        return;
    }

    if (vfs.mkdir(args)) {
        // success
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  mkdir: ");
        vga.write(args);
        vga.write(": Failed (already exists or invalid path)\n");
        vga.setColor(.white, .black);
    }
}

pub fn cmdRm(args: []const u8) void {
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: rm <file>\n");
        vga.setColor(.white, .black);
        return;
    }

    if (vfs.unlink(args)) {
        // success
    } else {
        vga.setColor(.light_red, .black);
        vga.write("  rm: ");
        vga.write(args);
        vga.write(": No such file\n");
        vga.setColor(.white, .black);
    }
}

pub fn cmdWrite(args: []const u8) void {
    // Write text to a file: write <file> <text>
    if (args.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: write <file> <text>\n");
        vga.setColor(.white, .black);
        return;
    }

    var path_buf: [MAX_PATH]u8 = undefined;
    var path_len: usize = 0;
    var text_start: usize = 0;

    for (args, 0..) |ch, i| {
        if (ch == ' ' and path_len > 0) {
            text_start = i + 1;
            break;
        }
        if (path_len < MAX_PATH) {
            path_buf[path_len] = ch;
            path_len += 1;
        }
    }

    if (path_len == 0 or text_start >= args.len) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: write <file> <text>\n");
        vga.setColor(.white, .black);
        return;
    }

    const text = args[text_start..];

    const handle = vfs.open(path_buf[0..path_len], .{ .create = true, .write = true }) orelse {
        vga.setColor(.light_red, .black);
        vga.write("  write: Failed to open ");
        vga.write(path_buf[0..path_len]);
        vga.write("\n");
        vga.setColor(.white, .black);
        return;
    };
    defer vfs.close(handle);

    _ = vfs.write(handle, text);
}

pub fn cmdCd(args: []const u8) void {
    if (args.len == 0) {
        vga.write("  ");
        vga.write(vfs.getCwd());
        vga.putChar('\n');
        return;
    }

    // Resolve to absolute path first
    const abs_path = vfs.resolveAbsolute(args);

    // Check if directory exists
    if (vfs.stat(abs_path)) |st| {
        if (st.file_type == .directory) {
            vfs.setCwd(abs_path);
            return;
        }
    }

    vga.setColor(.light_red, .black);
    vga.write("  cd: ");
    vga.write(args);
    vga.write(": Not a directory\n");
    vga.setColor(.white, .black);
}

pub fn cmdCopy(args: []const u8) void {
    var src_end: usize = args.len;
    for (args, 0..) |ch, i| {
        if (ch == ' ') {
            src_end = i;
            break;
        }
    }
    var dst = if (src_end < args.len) args[src_end + 1 ..] else "";
    while (dst.len > 0 and dst[0] == ' ') : (dst = dst[1..]) {}
    const src = args[0..src_end];
    if (src.len == 0 or dst.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: cp <src> <dst>\n");
        vga.setColor(.white, .black);
        return;
    }

    const in = vfs.open(src, .{ .read = true }) orelse {
        vga.setColor(.light_red, .black);
        vga.write("  cp: cannot open ");
        vga.write(src);
        vga.write("\n");
        vga.setColor(.white, .black);
        return;
    };
    defer vfs.close(in);

    const out = vfs.open(dst, .{ .create = true, .truncate = true, .write = true }) orelse {
        vga.setColor(.light_red, .black);
        vga.write("  cp: cannot create ");
        vga.write(dst);
        vga.write("\n");
        vga.setColor(.white, .black);
        return;
    };
    defer vfs.close(out);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = vfs.read(in, &buf);
        if (n == 0) break;
        _ = vfs.write(out, buf[0..n]);
        total += n;
    }
    vga.write("  Copied ");
    vga.writeDec(total);
    vga.write(" bytes -> ");
    vga.write(dst);
    vga.write("\n");
}

fn hexNibble(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + (v - 10);
}

fn writeHexByte(v: u8) void {
    vga.putChar(hexNibble(v >> 4));
    vga.putChar(hexNibble(v & 0x0F));
}

/// hexdump <file> � classic offset/hex/ASCII dump, 16 bytes per row.
pub fn cmdHexdump(args: []const u8) void {
    var it = args;
    while (it.len > 0 and it[0] == ' ') : (it = it[1..]) {}
    var path_end: usize = it.len;
    for (it, 0..) |ch, i| {
        if (ch == ' ') {
            path_end = i;
            break;
        }
    }
    const path = it[0..path_end];
    var rest = if (path_end < it.len) it[path_end..] else "";
    var count: u64 = std.math.maxInt(u64);
    var skip: u64 = 0;
    for ([_]*u64{ &count, &skip }) |slot| {
        var v: u64 = 0;
        var any = false;
        while (rest.len > 0 and rest[0] == ' ') : (rest = rest[1..]) {}
        while (rest.len > 0 and rest[0] >= '0' and rest[0] <= '9') : (rest = rest[1..]) {
            v = v * 10 + (rest[0] - '0');
            any = true;
        }
        if (any) slot.* = v;
    }
    if (path.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: hexdump <file> [count] [skip]\n");
        vga.setColor(.white, .black);
        return;
    }

    const handle = vfs.open(path, .{ .read = true }) orelse {
        vga.setColor(.light_red, .black);
        vga.write("  hexdump: cannot open ");
        vga.write(path);
        vga.write("\n");
        vga.setColor(.white, .black);
        return;
    };
    defer vfs.close(handle);
    if (skip > 0) _ = vfs.seek(handle, skip);
    var printed: u64 = 0;
    var row: [16]u8 = undefined;
    var offset: usize = @intCast(skip);
    var line: [96]u8 = undefined;

    while (printed < count) {
        const want_rows: usize = @intCast(@min(@as(u64, 16), count - printed));
        const n = vfs.read(handle, row[0..want_rows]);
        if (n == 0) break;

        // Compose the row into one buffer so it goes to the VGA console and
        // the serial log together (serial is how headless tests read output).
        var ln: usize = 0;
        const put = struct {
            fn ch(dst: []u8, l: *usize, c: u8) void {
                if (l.* < dst.len) {
                    dst[l.*] = c;
                    l.* += 1;
                }
            }
            fn s(dst: []u8, l: *usize, src: []const u8) void {
                for (src) |c| ch(dst, l, c);
            }
        }.s;

        put(&line, &ln, "  ");
        var i: usize = 0;
        while (i < 16 and (offset >> @intCast((15 - i) * 4)) & 0xF == 0 and i < 7) : (i += 1) put(&line, &ln, "0");
        var v = offset;
        var digits: [8]u8 = undefined;
        var dn: usize = 0;
        while (dn < 8) : (dn += 1) {
            digits[7 - dn] = hexNibble(@intCast(v & 0xF));
            v >>= 4;
        }
        put(&line, &ln, &digits);
        put(&line, &ln, "  ");

        i = 0;
        while (i < 16) : (i += 1) {
            if (i == 8) put(&line, &ln, " ");
            if (i < n) {
                put(&line, &ln, &[1]u8{hexNibble(row[i] >> 4)});
                put(&line, &ln, &[1]u8{hexNibble(row[i] & 0x0F)});
                put(&line, &ln, " ");
            } else {
                put(&line, &ln, "   ");
            }
        }

        put(&line, &ln, " ");
        i = 0;
        while (i < n) : (i += 1) {
            put(&line, &ln, &[1]u8{if (row[i] >= 0x20 and row[i] < 0x7F) row[i] else '.'});
        }
        put(&line, &ln, "\n");
        vga.write(line[0..ln]);
        serial.serialWrite(line[0..ln]);
        offset += n;
        printed += n;
    }
}
