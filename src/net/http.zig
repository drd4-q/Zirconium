const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const tcp = @import("tcp.zig");
const dns = @import("dns.zig");

var http_req_buf: [512]u8 = undefined;

pub fn httpGet(host: []const u8, path: []const u8) void {
    tcp.resetState();

    // Try to parse host as IP first, otherwise resolve via DNS
    var host_ip: [4]u8 = undefined;
    if (parseIp(host)) |ip| {
        host_ip = ip;
    } else {
        const resolved = dns.resolve(host) orelse {
            vga.setColor(.light_red, .black);
            vga.write("[HTTP] Failed to resolve host\n");
            vga.setColor(.white, .black);
            return;
        };
        host_ip = resolved;
    }

    if (!tcp.connect(host_ip, 80)) {
        vga.setColor(.light_red, .black);
        vga.write("[HTTP] Connection failed\n");
        vga.setColor(.white, .black);
        return;
    }

    vga.setColor(.light_green, .black);
    vga.write("[HTTP] Connected to ");
    net.printIp(host_ip);
    vga.putChar(':');
    vga.writeDec(80);
    vga.write("\n");
    vga.setColor(.white, .black);

    var pos: usize = 0;

    for ("GET ") |ch| { http_req_buf[pos] = ch; pos += 1; }
    for (path) |ch| { http_req_buf[pos] = ch; pos += 1; }
    for (" HTTP/1.0\r\nHost: ") |ch| { http_req_buf[pos] = ch; pos += 1; }
    for (host) |ch| { http_req_buf[pos] = ch; pos += 1; }
    for ("\r\nConnection: close\r\n\r\n") |ch| { http_req_buf[pos] = ch; pos += 1; }

    tcp.send(http_req_buf[0..pos]);

    vga.write("[HTTP] Request sent, waiting for response...\n");

    // Wait for response
    tcp.rx_len = 0;
    tcp.rx_ready = false;

    var timeout: u32 = 0;
    while (timeout < 300 and (!tcp.rx_ready or tcp.state == .established)) : (timeout += 1) {
        net.poll();
        var j: u32 = 0;
        while (j < 100000) : (j += 1) {
            asm volatile ("nop");
        }
    }

    // Print response
    if (tcp.rx_len > 0) {
        printResponse(tcp.rx_data[0..tcp.rx_len]);
    } else {
        vga.setColor(.light_red, .black);
        vga.write("[HTTP] No response received\n");
        vga.setColor(.white, .black);
    }

    tcp.close();
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
            return null; // non-numeric char = not an IP
        }
    }

    if (!has_digit or part_idx != 3) return null;
    parts[part_idx] = @intCast(num);
    return parts;
}

fn printResponse(data: []const u8) void {
    // Skip headers (find \r\n\r\n)
    var body_start: usize = 0;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n') {
            body_start = i + 4;
            break;
        }
    }

    // Print status line
    vga.setColor(.light_cyan, .black);
    var j: usize = 0;
    while (j < data.len and data[j] != '\r') : (j += 1) {
        vga.putChar(data[j]);
    }
    vga.write("\n");
    vga.setColor(.white, .black);

    // Print body (strip HTML tags for display)
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
            // Skip HTML entities
            skip_line = true;
        } else {
            skip_line = false;
            vga.putChar(ch);
        }
    }
}
