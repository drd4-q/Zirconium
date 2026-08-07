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
    // Parse host and path
    var host_start: usize = 0;
    var host_end: usize = url.len;
    var path_start: usize = url.len;

    // Skip protocol
    if (url.len > 7 and url[0] == 'h' and url[1] == 't' and url[2] == 't' and url[3] == 'p') {
        host_start = 7;
        if (url.len > 8 and url[7] == 's') host_start = 8;
        if (host_start < url.len and url[host_start] == '/') host_start += 1;
    }

    var i: usize = host_start;
    while (i < url.len) : (i += 1) {
        if (url[i] == '/' or url[i] == ':') {
            host_end = i;
            path_start = i;
            break;
        }
    }

    const host = url[host_start..host_end];
    const path = if (path_start < url.len) url[path_start..] else "/";

    vga.setColor(.light_cyan, .black);
    vga.write("  Host: ");
    vga.setColor(.white, .black);
    vga.write(host);
    vga.write("\n");
    vga.setColor(.light_cyan, .black);
    vga.write("  Path: ");
    vga.setColor(.white, .black);
    vga.write(path);
    vga.write("\n\n");

    http.httpGet(host, path);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
