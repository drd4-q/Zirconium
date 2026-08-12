const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const icmp = @import("icmp.zig");
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");

pub fn handlePacket(frame: []const u8) void {
    if (frame.len < 34) return;
    const ip = frame[14..];

    if (ip[0] >> 4 != 4) return; // IPv4 only
    const ihl = @as(usize, ip[0] & 0x0F) * 4;
    if (ihl < 20 or 14 + ihl > frame.len) return;

    const total_len = (@as(u16, ip[2]) << 8) | ip[3];
    if (total_len < ihl) return;
    const protocol = ip[9];

    const dst_ip = [4]u8{ ip[16], ip[17], ip[18], ip[19] };

    if (!isForUs(dst_ip)) return;

    // Ethernet pads frames to 60 bytes, so frame.len is NOT the packet length.
    // Every upper layer derives its payload size from the slice it gets, so a
    // 40-byte TCP/IP packet used to arrive with 6 bytes of padding appended and
    // those bytes were treated as TCP payload (corrupting rx_buf and ack_num).
    // Trim to the length the IP header declares before dispatching.
    const packet_end = @min(frame.len, 14 + @as(usize, total_len));
    const packet = frame[0..packet_end];

    switch (protocol) {
        1 => icmp.handlePacket(packet, ihl),
        6 => tcp.handlePacket(packet, ihl),
        17 => udp.handlePacket(packet, ihl),
        else => {},
    }
}

/// True when a received packet is addressed to this host: our unicast address,
/// the all-ones broadcast, or anything at all while we have no address yet
/// (DHCP replies arrive before `our_ip` is configured).
fn isForUs(dst_ip: [4]u8) bool {
    if (dst_ip[0] == 255 and dst_ip[1] == 255 and dst_ip[2] == 255 and dst_ip[3] == 255) return true;

    if (net.our_ip[0] == 0 and net.our_ip[1] == 0 and net.our_ip[2] == 0 and net.our_ip[3] == 0) {
        return true;
    }

    if (dst_ip[0] == net.our_ip[0] and dst_ip[1] == net.our_ip[1] and
        dst_ip[2] == net.our_ip[2] and dst_ip[3] == net.our_ip[3])
    {
        return true;
    }

    // Subnet-directed broadcast (e.g. 10.0.2.255)
    var bcast: [4]u8 = undefined;
    for (0..4) |i| bcast[i] = net.our_ip[i] | ~net.netmask[i];
    return dst_ip[0] == bcast[0] and dst_ip[1] == bcast[1] and
        dst_ip[2] == bcast[2] and dst_ip[3] == bcast[3];
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

pub fn buildHeader(src: [4]u8, dst: [4]u8, protocol: u8, total_len: u16, buf: []u8) void {
    buf[0] = 0x45; // IPv4, IHL=5
    buf[1] = 0x00; // DSCP
    buf[2] = @intCast(total_len >> 8);
    buf[3] = @intCast(total_len & 0xFF);
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
