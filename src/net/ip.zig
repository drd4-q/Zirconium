const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");

pub fn handlePacket(frame: []const u8) void {
    if (frame.len < 34) return;
    const ip = frame[14..];

    const ihl = @as(usize, ip[0] & 0x0F) * 4;
    const total_len = (@as(u16, ip[2]) << 8) | ip[3];
    const protocol = ip[9];

    const dst_ip = [4]u8{ ip[16], ip[17], ip[18], ip[19] };

    _ = total_len;

    if (dst_ip[0] != net.our_ip[0] or
        dst_ip[1] != net.our_ip[1] or
        dst_ip[2] != net.our_ip[2] or
        dst_ip[3] != net.our_ip[3])
    {
        return;
    }

    switch (protocol) {
        1 => icmp.handlePacket(frame, ihl),
        6 => tcp.handlePacket(frame, ihl),
        else => {},
    }
}

pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

pub fn checksumPseudo(src: [4]u8, dst: [4]u8, proto: u8, data: []const u8) u16 {
    var pseudo: [12]u8 = undefined;
    @memcpy(pseudo[0..4], &src);
    @memcpy(pseudo[4..8], &dst);
    pseudo[8] = 0;
    pseudo[9] = proto;
    pseudo[10] = @intCast(data.len >> 8);
    pseudo[11] = @intCast(data.len & 0xFF);

    var sum: u32 = 0;
    var i: usize = 0;
    while (i < 12) : (i += 2) {
        sum += (@as(u32, pseudo[i]) << 8) | pseudo[i + 1];
    }
    i = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    while (sum >> 16 != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return @intCast(~sum & 0xFFFF);
}

pub fn buildHeader(src: [4]u8, dst: [4]u8, protocol: u8, payload_len: u16, buf: []u8) void {
    buf[0] = 0x45; // IPv4, IHL=5
    buf[1] = 0x00; // DSCP
    buf[2] = @intCast((20 + payload_len) >> 8);
    buf[3] = @intCast((20 + payload_len) & 0xFF);
    buf[4] = 0x00; buf[5] = 0x00; // Identification
    buf[6] = 0x40; buf[7] = 0x00; // Don't fragment
    buf[8] = 0x40;                 // TTL=64
    buf[9] = protocol;
    buf[10] = 0x00; buf[11] = 0x00; // Checksum (filled later)
    @memcpy(buf[12..16], &src);
    @memcpy(buf[16..20], &dst);

    const cs = checksum(buf[0..20]);
    buf[10] = @intCast(cs >> 8);
    buf[11] = @intCast(cs & 0xFF);
}
