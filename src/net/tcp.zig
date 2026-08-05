const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const ip_mod = @import("ip.zig");
const e1000 = @import("../drivers/e1000.zig");

pub const TcpState = enum {
    closed,
    syn_sent,
    established,
    fin_wait,
};

pub var state: TcpState = .closed;
pub var seq_num: u32 = 0x1000;
pub var ack_num: u32 = 0;
pub var remote_port: u16 = 0;
pub var local_port: u16 = 12345;
pub var remote_ip: [4]u8 = .{0, 0, 0, 0};
pub var rx_ready: bool = false;
pub var rx_data: [4096]u8 = undefined;
pub var rx_len: usize = 0;

var tcp_tx_buf: [42 + 1500]u8 align(16) = undefined;

pub fn handlePacket(frame: []const u8, ihl: usize) void {
    if (frame.len < 14 + ihl + 20) return;
    const tcp_data = frame[14 + ihl ..];
    const tcp_hdr_len = @as(usize, (@as(u8, tcp_data[12]) >> 4)) * 4;

    const src_port = (@as(u16, tcp_data[0]) << 8) | tcp_data[1];
    const dst_port = (@as(u16, tcp_data[2]) << 8) | tcp_data[3];
    const seq = (@as(u32, tcp_data[4]) << 24) | (@as(u32, tcp_data[5]) << 16) |
        (@as(u32, tcp_data[6]) << 8) | tcp_data[7];
    const ack = (@as(u32, tcp_data[8]) << 24) | (@as(u32, tcp_data[9]) << 16) |
        (@as(u32, tcp_data[10]) << 8) | tcp_data[11];
    const flags = tcp_data[13];

    _ = dst_port;
    _ = ack;

    const src_ip = [4]u8{ frame[26], frame[27], frame[28], frame[29] };

    if (flags & 0x02 != 0 and flags & 0x10 == 0) { // SYN
        remote_port = src_port;
        ack_num = seq + 1;

        vga.setColor(.light_green, .black);
        vga.write("[TCP] SYN received, sending SYN-ACK\n");
        vga.setColor(.white, .black);

        sendPacket(src_ip, src_port, 0x12, null); // SYN-ACK
        seq_num += 1;
    } else if (flags & 0x10 != 0 and flags & 0x02 == 0) { // ACK
        if (state == .syn_sent) {
            state = .established;
            vga.setColor(.light_green, .black);
            vga.write("[TCP] Connection established!\n");
            vga.setColor(.white, .black);
        }
    } else if (flags & 0x01 != 0) { // FIN
        state = .fin_wait;
        vga.write("[TCP] FIN received\n");
        sendPacket(src_ip, src_port, 0x10, null);
    }

    // Data
    if (tcp_hdr_len < tcp_data.len and tcp_hdr_len + 14 + ihl < frame.len) {
        const data = frame[14 + ihl + tcp_hdr_len ..];
        if (data.len > 0 and state == .established) {
            ack_num += @intCast(data.len);
            const copy_len = @min(data.len, rx_data.len - rx_len);
            @memcpy(rx_data[rx_len..][0..copy_len], data[0..copy_len]);
            rx_len += copy_len;
            rx_ready = true;
            sendPacket(src_ip, src_port, 0x10, null); // ACK
        }
    }
}

fn sendPacket(dst_ip: [4]u8, dst_port_val: u16, flags_val: u8, payload: ?[]const u8) void {
    _ = net.ensureArp(dst_ip);

    @memset(&tcp_tx_buf, 0);

    const data_len: u16 = if (payload) |p| @intCast(p.len) else 0;
    const tcp_hdr_len: u16 = 20;
    const ip_total = 20 + tcp_hdr_len + data_len;

    // Ethernet
    @memcpy(tcp_tx_buf[0..6], &net.gateway_mac);
    @memcpy(tcp_tx_buf[6..12], &net.our_mac);
    tcp_tx_buf[12] = 0x08; tcp_tx_buf[13] = 0x00;

    // IP
    ip_mod.buildHeader(net.our_ip, dst_ip, 6, ip_total, tcp_tx_buf[14..34]);

    // TCP
    const tcp_off = 34;
    tcp_tx_buf[tcp_off + 0] = @intCast(local_port >> 8);
    tcp_tx_buf[tcp_off + 1] = @intCast(local_port & 0xFF);
    tcp_tx_buf[tcp_off + 2] = @intCast(dst_port_val >> 8);
    tcp_tx_buf[tcp_off + 3] = @intCast(dst_port_val & 0xFF);
    tcp_tx_buf[tcp_off + 4] = @intCast(seq_num >> 24);
    tcp_tx_buf[tcp_off + 5] = @intCast((seq_num >> 16) & 0xFF);
    tcp_tx_buf[tcp_off + 6] = @intCast((seq_num >> 8) & 0xFF);
    tcp_tx_buf[tcp_off + 7] = @intCast(seq_num & 0xFF);
    tcp_tx_buf[tcp_off + 8] = @intCast(ack_num >> 24);
    tcp_tx_buf[tcp_off + 9] = @intCast((ack_num >> 16) & 0xFF);
    tcp_tx_buf[tcp_off + 10] = @intCast((ack_num >> 8) & 0xFF);
    tcp_tx_buf[tcp_off + 11] = @intCast(ack_num & 0xFF);
    tcp_tx_buf[tcp_off + 12] = 0x50; // Data offset (5 * 4 = 20)
    tcp_tx_buf[tcp_off + 13] = flags_val;
    tcp_tx_buf[tcp_off + 14] = 0x00; tcp_tx_buf[tcp_off + 15] = 0x3C; // Window size

    // Copy payload
    if (payload) |p| {
        @memcpy(tcp_tx_buf[tcp_off + 20 ..][0..p.len], p);
    }

    // TCP checksum
    const cs = ip_mod.checksumPseudo(net.our_ip, dst_ip, 6, tcp_tx_buf[tcp_off..][0..20 + data_len]);
    tcp_tx_buf[tcp_off + 16] = @intCast(cs >> 8);
    tcp_tx_buf[tcp_off + 17] = @intCast(cs & 0xFF);

    e1000.transmit(tcp_tx_buf[0..tcp_off + 20 + data_len]);
}

pub fn connect(dst_ip: [4]u8, dst_port_val: u16) bool {
    state = .closed;
    remote_port = dst_port_val;
    remote_ip = dst_ip;
    seq_num = 0x1000;

    vga.write("[TCP] Connecting to ");
    net.printIp(dst_ip);
    vga.write(":");
    vga.writeDec(dst_port_val);
    vga.write("...\n");

    sendPacket(dst_ip, dst_port_val, 0x02, null); // SYN
    state = .syn_sent;

    var timeout: u32 = 0;
    while (timeout < 200 and state != .established) : (timeout += 1) {
        net.poll();
        var j: u32 = 0;
        while (j < 100000) : (j += 1) {
            asm volatile ("nop");
        }
    }

    return state == .established;
}

pub fn send(data: []const u8) void {
    if (state != .established) return;
    sendPacket(remote_ip, remote_port, 0x18, data); // PSH+ACK
    seq_num += @intCast(data.len);
}

pub fn close() void {
    if (state == .established) {
        sendPacket(remote_ip, remote_port, 0x11, null); // FIN+ACK
        state = .closed;
        vga.write("[TCP] Connection closed\n");
    }
}

pub fn resetState() void {
    state = .closed;
    rx_len = 0;
    rx_ready = false;
}
