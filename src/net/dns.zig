const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const udp = @import("udp.zig");

const DNS_SERVER = udp.DNS_SERVER;

var dns_rx_buf: [512]u8 = undefined;
var dns_rx_len: usize = 0;
var dns_rx_ready: bool = false;
var dns_query_id: u16 = 0xAAAA;

pub fn resolve(hostname: []const u8) ?[4]u8 {
    dns_rx_len = 0;
    dns_rx_ready = false;
    dns_query_id +%= 1;

    const pkt_len = buildQuery(hostname, &dns_rx_buf);

    vga.setColor(.light_cyan, .black);
    vga.write("[DNS] Resolving ");
    vga.setColor(.white, .black);
    vga.write(hostname);
    vga.setColor(.light_cyan, .black);
    vga.write("...\n");
    vga.setColor(.white, .black);

    udp.sendPacket(DNS_SERVER, 53, 43210, dns_rx_buf[0..pkt_len]);

    // Poll for response
    var timeout: u32 = 0;
    while (timeout < 200 and !dns_rx_ready) : (timeout += 1) {
        net.poll();
        var j: u32 = 0;
        while (j < 100000) : (j += 1) {
            asm volatile ("nop");
        }
    }

    if (!dns_rx_ready) {
        vga.setColor(.light_red, .black);
        vga.write("[DNS] Resolution failed (timeout)\n");
        vga.setColor(.white, .black);
        return null;
    }

    return parseResponse(dns_rx_buf[0..dns_rx_len]);
}

fn buildQuery(hostname: []const u8, buf: []u8) usize {
    var pos: usize = 0;

    // Transaction ID
    buf[0] = @intCast(dns_query_id >> 8);
    buf[1] = @intCast(dns_query_id & 0xFF);

    // Flags: standard query, recursion desired
    buf[2] = 0x01;
    buf[3] = 0x00;

    // QDCOUNT = 1
    buf[4] = 0x00;
    buf[5] = 0x01;

    // ANCOUNT = 0
    buf[6] = 0x00;
    buf[7] = 0x00;

    // NSCOUNT = 0
    buf[8] = 0x00;
    buf[9] = 0x00;

    // ARCOUNT = 0
    buf[10] = 0x00;
    buf[11] = 0x00;

    pos = 12;

    // Encode hostname as DNS labels
    var i: usize = 0;
    var label_start: usize = 0;
    while (i <= hostname.len) : (i += 1) {
        if (i == hostname.len or hostname[i] == '.') {
            const label_len = i - label_start;
            buf[pos] = @intCast(label_len);
            pos += 1;
            var j: usize = label_start;
            while (j < i) : (j += 1) {
                buf[pos] = hostname[j];
                pos += 1;
            }
            label_start = i + 1;
        }
    }
    buf[pos] = 0; // root label
    pos += 1;

    // QTYPE = A (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // QCLASS = IN (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    return pos;
}

fn parseResponse(data: []const u8) ?[4]u8 {
    if (data.len < 12) return null;

    // Check response code
    const rcode = data[3] & 0x0F;
    if (rcode != 0) {
        vga.setColor(.light_red, .black);
        vga.write("[DNS] Server error rcode=");
        vga.writeDec(rcode);
        vga.write("\n");
        vga.setColor(.white, .black);
        return null;
    }

    const ancount = (@as(u16, data[6]) << 8) | data[7];
    if (ancount == 0) {
        vga.setColor(.light_red, .black);
        vga.write("[DNS] No records found\n");
        vga.setColor(.white, .black);
        return null;
    }

    // Skip header (12 bytes)
    var pos: usize = 12;

    // Skip question section
    const qdcount = (@as(u16, data[4]) << 8) | data[5];
    var q: u16 = 0;
    while (q < qdcount) : (q += 1) {
        // Skip QNAME
        while (pos < data.len) : (pos += 1) {
            if (data[pos] == 0) {
                pos += 1;
                break;
            }
            pos += data[pos];
        }
        // Skip QTYPE (2) + QCLASS (2)
        pos += 4;
    }

    // Parse answer section
    var a: u16 = 0;
    while (a < ancount and pos < data.len) : (a += 1) {
        // Skip NAME (might be pointer)
        if (data[pos] & 0xC0 == 0xC0) {
            pos += 2;
        } else {
            while (pos < data.len and data[pos] != 0) {
                pos += data[pos] + 1;
            }
            pos += 1;
        }

        if (pos + 10 > data.len) return null;

        const atype = (@as(u16, data[pos]) << 8) | data[pos + 1];
        // const atype = ...; // skip class
        _ = (@as(u16, data[pos + 2]) << 8) | data[pos + 3]; // CLASS
        // skip TTL
        _ = (@as(u32, data[pos + 4]) << 24) | (@as(u32, data[pos + 5]) << 16) |
            (@as(u32, data[pos + 6]) << 8) | data[pos + 7];
        const rdlength = (@as(u16, data[pos + 8]) << 8) | data[pos + 9];
        pos += 10;

        if (atype == 1 and rdlength == 4 and pos + 4 <= data.len) {
            const ip: [4]u8 = .{ data[pos], data[pos + 1], data[pos + 2], data[pos + 3] };
            vga.setColor(.light_green, .black);
            vga.write("[DNS] Resolved to ");
            net.printIp(ip);
            vga.write("\n");
            vga.setColor(.white, .black);
            return ip;
        }

        pos += rdlength;
    }

    vga.setColor(.light_red, .black);
    vga.write("[DNS] No A records found\n");
    vga.setColor(.white, .black);
    return null;
}

pub fn handleResponse(frame: []const u8, ihl: usize, udp_hdr_len: usize) void {
    const payload_start = 14 + ihl + udp_hdr_len;
    if (payload_start >= frame.len) return;

    const data = frame[payload_start..];
    const copy_len = @min(data.len, dns_rx_buf.len);
    @memcpy(dns_rx_buf[0..copy_len], data[0..copy_len]);
    dns_rx_len = copy_len;
    dns_rx_ready = true;
}
