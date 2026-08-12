const root = @import("root");
const vga = root.vga;
const kb = @import("../drivers/keyboard.zig");
const http = @import("../net/http.zig");

var url_buf: [256]u8 = undefined;

pub fn run(args: []const u8) void {
    if (args.len == 0) {
        interactiveMode();
        return;
    }

    fetchUrl(args);
}

fn interactiveMode() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== CLI Web Browser ===\n\n");
    vga.setColor(.white, .black);
    vga.write("  Enter URL to fetch (e.g. example.com/index.html)\n");
    vga.write("  Type 'exit' to quit.\n\n");

    while (true) {
        vga.setColor(.light_green, .black);
        vga.write("url> ");
        vga.setColor(.white, .black);

        const len = kb.readLine(&url_buf, 256);
        if (len == 0) continue;

        if (eql(url_buf[0..len], "exit")) return;

        fetchUrl(url_buf[0..len]);
    }
}

fn fetchUrl(url: []const u8) void {
    // Parse [scheme://]host[:port][/path]
    var host_start: usize = 0;

    // Skip scheme
    if (url.len > 7 and url[0] == 'h' and url[1] == 't' and url[2] == 't' and url[3] == 'p') {
        host_start = 7;
        if (url.len > 8 and url[7] == 's') host_start = 8;
        if (host_start < url.len and url[host_start] == '/') host_start += 1;
    }

    var host_end: usize = url.len;
    var path_start: usize = url.len;
    var port: u16 = http.DEFAULT_PORT;

    var i: usize = host_start;
    while (i < url.len) : (i += 1) {
        if (url[i] == '/') {
            host_end = i;
            path_start = i;
            break;
        }
        if (url[i] == ':') {
            // Explicit port. The old code set both host_end and path_start here,
            // so "host:8080/x" was fetched with the path ":8080/x".
            host_end = i;
            var p: u32 = 0;
            var j = i + 1;
            while (j < url.len and url[j] >= '0' and url[j] <= '9') : (j += 1) {
                p = p * 10 + (url[j] - '0');
            }
            if (p > 0 and p <= 65535) port = @intCast(p);
            path_start = j;
            break;
        }
    }

    const host = url[host_start..host_end];
    const path = if (path_start < url.len) url[path_start..] else "/";

    if (host.len == 0) {
        vga.setColor(.light_red, .black);
        vga.write("  Usage: get <host>[:port][/path]\n");
        vga.setColor(.white, .black);
        return;
    }

    vga.setColor(.light_cyan, .black);
    vga.write("  Host: ");
    vga.setColor(.white, .black);
    vga.write(host);
    if (port != http.DEFAULT_PORT) {
        vga.putChar(':');
        vga.writeDec(port);
    }
    vga.write("\n");
    vga.setColor(.light_cyan, .black);
    vga.write("  Path: ");
    vga.setColor(.white, .black);
    vga.write(path);
    vga.write("\n\n");

    const serial = root.serial;
    serial.serialWrite("[WEB] Host: ");
    serial.serialWrite(host);
    serial.serialWrite(" Path: ");
    serial.serialWrite(path);
    serial.serialWrite("\n");

    http.httpGetPort(host, path, port);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
