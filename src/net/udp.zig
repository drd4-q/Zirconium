const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const ip_mod = @import("ip.zig");
const e1000 = @import("../drivers/e1000.zig");
const dns = @import("dns.zig");
const dhcp = @import("dhcp.zig");

pub var dns_server: [4]u8 = .{ 10, 0, 2, 3 };
pub const DNS_PORT: u16 = 53;
pub const DHCP_SERVER_PORT: u16 = 67;
pub const DHCP_CLIENT_PORT: u16 = 68;

var udp_tx_buf: [42 + 1500]u8 align(16) = undefined;

pub var last_src_port: u16 = 0;
pub var last_src_ip: [4]u8 = .{ 0, 0, 0, 0 };

pub fn handlePacket(frame: []const u8, ihl: usize) void {
    if (frame.len < 14 + ihl + 8) return;
    const udp_data = frame[14 + ihl ..];

    const src_port = (@as(u16, udp_data[0]) << 8) | udp_data[1];
    const dst_port = (@as(u16, udp_data[2]) << 8) | udp_data[3];
    const udp_len = (@as(u16, udp_data[4]) << 8) | udp_data[5];

    const src_ip = [4]u8{ frame[26], frame[27], frame[28], frame[29] };

    _ = udp_len;
    last_src_port = src_port;
    last_src_ip = src_ip;

    if (dst_port == DNS_PORT) {
        dns.handleResponse(frame, ihl, 8);
    } else if (dst_port == DHCP_CLIENT_PORT) {
        dhcp.handleResponse(frame, ihl, 8);
    }
}

pub fn sendPacket(dst_ip: [4]u8, dst_port_val: u16, src_port_val: u16, payload: []const u8) void {
    // Resolve destination MAC via ARP cache
    const dst_mac = net.resolveMac(dst_ip) orelse {
        // ARP request + poll
        _ = net.ensureArp(dst_ip);
        return;
    };

    @memset(&udp_tx_buf, 0);

    const udp_hdr_len: u16 = 8;
    const ip_total: u16 = 20 + udp_hdr_len + @as(u16, @intCast(payload.len));

    // Ethernet
    @memcpy(udp_tx_buf[0..6], &dst_mac);
    @memcpy(udp_tx_buf[6..12], &net.our_mac);
    udp_tx_buf[12] = 0x08;
    udp_tx_buf[13] = 0x00;

    // IP header (proto=17 UDP)
    ip_mod.buildHeader(net.our_ip, dst_ip, 17, ip_total, udp_tx_buf[14..34]);

    // UDP header at offset 34
    const udp_off = 34;
    udp_tx_buf[udp_off + 0] = @intCast(src_port_val >> 8);
    udp_tx_buf[udp_off + 1] = @intCast(src_port_val & 0xFF);
    udp_tx_buf[udp_off + 2] = @intCast(dst_port_val >> 8);
    udp_tx_buf[udp_off + 3] = @intCast(dst_port_val & 0xFF);
    const total_udp = udp_hdr_len + @as(u16, @intCast(payload.len));
    udp_tx_buf[udp_off + 4] = @intCast(total_udp >> 8);
    udp_tx_buf[udp_off + 5] = @intCast(total_udp & 0xFF);
    udp_tx_buf[udp_off + 6] = 0; // checksum (0 = not computed)
    udp_tx_buf[udp_off + 7] = 0;

    // UDP checksum (optional for IPv4, but we compute it for correctness)
    const cs = ip_mod.checksumPseudo(net.our_ip, dst_ip, 17, udp_tx_buf[udp_off..][0 .. 8 + payload.len]);
    udp_tx_buf[udp_off + 6] = @intCast(cs >> 8);
    udp_tx_buf[udp_off + 7] = @intCast(cs & 0xFF);

    // Payload
    if (payload.len > 0) {
        @memcpy(udp_tx_buf[udp_off + 8 ..][0..payload.len], payload);
    }

    e1000.transmit(udp_tx_buf[0 .. udp_off + 8 + payload.len]);
}
