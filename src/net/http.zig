const root = @import("root");
const vga = root.vga;
const port_io = root.serial;
const net = @import("mod.zig");
const tcp = @import("tcp.zig");
const dns = @import("dns.zig");
const timer = @import("../drivers/timer.zig");

var http_req_buf: [512]u8 = undefined;

pub const DEFAULT_PORT: u16 = 80;

pub fn httpGet(host: []const u8, path: []const u8) void {
    httpGetPort(host, path, DEFAULT_PORT);
}

pub fn httpGetPort(host: []const u8, path: []const u8, dst_port: u16) void {
    // Try to parse host as IP first, otherwise resolve via DNS
    var host_ip: [4]u8 = undefined;
    if (parseIp(host)) |ip| {
        host_ip = ip;
    } else {
        const resolved = dns.resolve(host) orelse {
            vga.setColor(.light_red, .black);
            vga.write("[HTTP] Failed to resolve host\n");
            vga.setColor(.white, .black);
            port_io.serialWrite("[HTTP] Failed to resolve host\n");
            return;
        };
        host_ip = resolved;
    }

    const conn = tcp.connect(host_ip, dst_port) orelse {
        vga.setColor(.light_red, .black);
        vga.write("[HTTP] No free connection slots\n");
        vga.setColor(.white, .black);
        return;
    };

    // Wait up to 5s for TCP handshake (real internet RTT)
    if (!tcp.waitEstablished(conn, 500)) {
        vga.setColor(.light_red, .black);
        vga.write("[HTTP] Connection failed\n");
        vga.setColor(.white, .black);
        port_io.serialWrite("[HTTP] Connection failed\n");
        tcp.disconnect(conn);
        return;
    }

    vga.setColor(.light_green, .black);
    vga.write("[HTTP] Connected to ");
    net.printIp(host_ip);
    vga.putChar(':');
    vga.writeDec(dst_port);
    vga.write("\n");
    vga.setColor(.white, .black);

    port_io.serialWrite("[HTTP] Connected to ");
    net.printIpSerial(host_ip);
    port_io.serialWrite("\n");

    const req_len = buildRequest(host, path) orelse {
        vga.setColor(.light_red, .black);
        vga.write("[HTTP] URL too long\n");
        vga.setColor(.white, .black);
        tcp.close(conn);
        tcp.disconnect(conn);
        return;
    };

    // Clear any stale bytes before the request so the response starts at 0.
    tcp.resetState(conn);
    tcp.send(conn, http_req_buf[0..req_len]);

    vga.write("[HTTP] Request sent, waiting for response...\n");
    port_io.serialWrite("[HTTP] Request sent, waiting for response...\n");

    // Wait for the server to finish: with "Connection: close" it FINs after the
    // body, so keep polling while the connection is still established. Also
    // stop early if the peer stalls for 3s after we already have data.
    const response_deadline = timer.ticks +% 1500; // 15s hard cap
    var last_len: usize = 0;
    var last_progress = timer.ticks;
    while (timer.ticks < response_deadline and conn.state == .established) {
        net.poll();
        if (conn.rx_len != last_len) {
            last_len = conn.rx_len;
            last_progress = timer.ticks;
        } else if (last_len > 0 and timer.ticks -% last_progress > 300) {
            break;
        }
    }

    // Print response
    if (conn.rx_len > 0) {
        port_io.serialWrite("[HTTP] Response received: ");
        port_io.serialWriteDec(conn.rx_len);
        port_io.serialWrite(" bytes\n");
        printStatusSerial(conn.rx_buf[0..@min(conn.rx_len, 512)]);
        printResponse(conn.rx_buf[0..conn.rx_len]);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("[HTTP] No response received\n");
        vga.setColor(.white, .black);
        port_io.serialWrite("[HTTP] No response received\n");
    }

    tcp.close(conn);
    tcp.disconnect(conn);
}

/// Serialize "GET <path> HTTP/1.0" into http_req_buf, or null if it won't fit.
fn buildRequest(host: []const u8, path: []const u8) ?usize {
    var pos: usize = 0;

    const parts = [_][]const u8{
        "GET ",
        path,
        " HTTP/1.0\r\nHost: ",
        host,
        "\r\nConnection: close\r\n\r\n",
    };

    for (parts) |part| {
        if (pos + part.len > http_req_buf.len) return null;
        @memcpy(http_req_buf[pos..][0..part.len], part);
        pos += part.len;
    }

    return pos;
}

fn parseIp(host: []const u8) ?[4]u8 {
    var parts: [4]u8 = .{ 0, 0, 0, 0 };
    var part_idx: usize = 0;
    var num: u32 = 0;
    var has_digit = false;

    for (host) |ch| {
        if (ch == '.') {
            if (!has_digit or part_idx >= 4) return null;
            parts[part_idx] = @intCast(num);
            part_idx += 1;
            num = 0;
            has_digit = false;
        } else if (ch >= '0' and ch <= '9') {
            num = num * 10 + @as(u32, ch - '0');
            if (num > 255) return null;
            has_digit = true;
        } else {
            return null;
        }
    }

    if (!has_digit or part_idx != 3) return null;
    parts[part_idx] = @intCast(num);
    return parts;
}

fn printStatusSerial(data: []const u8) void {
    var line: [256]u8 = undefined;
    var n: usize = 0;
    while (n < data.len and n < line.len and data[n] != '\r' and data[n] != '\n') : (n += 1) {
        line[n] = data[n];
    }
    port_io.serialWrite(line[0..n]);
    port_io.serialWrite("\n");
}

fn printResponse(data: []const u8) void {
    var body_start: usize = 0;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') {
            body_start = i + 4;
            break;
        }
    }

    vga.setColor(.light_cyan, .black);
    var j: usize = 0;
    while (j < data.len and data[j] != '\r') : (j += 1) {
        vga.putChar(data[j]);
    }
    vga.write("\n");
    vga.setColor(.white, .black);

    if (body_start < data.len) {
        vga.write("\n");
        printText(data[body_start..]);
    }
}

fn printText(data: []const u8) void {
    var in_tag = false;
    var in_script = false;
    var skip_line = false;

    for (data) |ch| {
        if (ch == '<') {
            in_tag = true;
            continue;
        }
        if (ch == '>') {
            in_tag = false;
            in_script = false;
            continue;
        }
        if (in_tag) {
            continue;
        }
        if (in_script) continue;

        if (ch == '\n' or ch == '\r') {
            if (!skip_line) {
                vga.putChar('\n');
            }
            skip_line = false;
        } else if (ch == ' ' or ch == '\t') {
            if (!skip_line) vga.putChar(' ');
        } else if (ch == '&') {
            skip_line = true;
        } else {
            skip_line = false;
            vga.putChar(ch);
        }
    }
}
