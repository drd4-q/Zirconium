const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const udp = @import("udp.zig");
const arp = @import("arp.zig");
const e1000 = @import("../drivers/e1000.zig");
const ip_mod = @import("ip.zig");

const DHCP_SERVER_PORT: u16 = 67;
const DHCP_CLIENT_PORT: u16 = 68;
const DHCP_MAGIC: u32 = 0x63825363;

// DHCP message types
const DHCP_DISCOVER: u8 = 1;
const DHCP_OFFER: u8 = 2;
const DHCP_REQUEST: u8 = 3;
const DHCP_ACK: u8 = 5;
const DHCP_NAK: u8 = 6;

// DHCP options
const OPT_MESSAGE_TYPE: u8 = 53;
const OPT_SUBNET_MASK: u8 = 1;
const OPT_ROUTER: u8 = 3;
const OPT_DNS_SERVER: u8 = 6;
const OPT_LEASE_TIME: u8 = 51;
const OPT_END: u8 = 255;

var dhcp_rx_buf: [548]u8 = undefined; // max DHCP message
var dhcp_rx_ready: bool = false;
var dhcp_xid: u32 = 0xDEADBEEF;

// Lease info from DHCP
pub var lease_ip: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_mask: [4]u8 = .{ 255, 255, 255, 0 };
pub var lease_router: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_dns: [4]u8 = .{ 0, 0, 0, 0 };
pub var lease_lease_sec: u32 = 0;
pub var lease_valid: bool = false;

fn buildDiscover(buf: []u8) usize {
    @memset(buf, 0);

    // BOOTP header
    buf[0] = 0x01; // BOOTREQUEST
    buf[1] = 0x01; // Ethernet
    buf[2] = 0x06; // Hardware address length
    buf[3] = 0x00; // Hops

    // Transaction ID
    buf[4] = @intCast(dhcp_xid >> 24);
    buf[5] = @intCast((dhcp_xid >> 16) & 0xFF);
    buf[6] = @intCast((dhcp_xid >> 8) & 0xFF);
    buf[7] = @intCast(dhcp_xid & 0xFF);

    // Seconds, Flags
    buf[8] = 0x00; buf[9] = 0x00;
    buf[10] = 0x80; buf[11] = 0x00; // Broadcast flag

    // Client IP (0.0.0.0 for discover)
    // Your IP, Server IP, Gateway IP - all zero

    // Client hardware address (our MAC) at offset 28
    @memcpy(buf[28..34], &net.our_mac);

    // Magic cookie at offset 236
    buf[236] = 0x63;
    buf[237] = 0x82;
    buf[238] = 0x53;
    buf[239] = 0x63;

    // Options start at 240
    var pos: usize = 240;

    // DHCP Message Type: DISCOVER
    buf[pos] = OPT_MESSAGE_TYPE;
    buf[pos + 1] = 1;
    buf[pos + 2] = DHCP_DISCOVER;
    pos += 3;

    // Requested IP (we'd like our_ip if re-requesting)
    buf[pos] = 50; // Requested IP option
    buf[pos + 1] = 4;
    buf[pos + 2] = net.our_ip[0];
    buf[pos + 3] = net.our_ip[1];
    buf[pos + 4] = net.our_ip[2];
    buf[pos + 5] = net.our_ip[3];
    pos += 6;

    // Hostname
    buf[pos] = 12; // Hostname
    const hostname = "zig-kernel";
    buf[pos + 1] = @intCast(hostname.len);
    for (hostname, 0..) |ch, i| {
        buf[pos + 2 + i] = ch;
    }
    pos += 2 + hostname.len;

    // End option
    buf[pos] = OPT_END;
    pos += 1;

    return pos;
}

fn buildRequest(offered_ip: [4]u8, server_ip: [4]u8) usize {
    @memset(request_buf[0..], 0);

    // BOOTP header
    request_buf[0] = 0x01; // BOOTREQUEST
    request_buf[1] = 0x01; // Ethernet
    request_buf[2] = 0x06; // Hardware address length
    request_buf[3] = 0x00; // Hops

    // Transaction ID
    request_buf[4] = @intCast(dhcp_xid >> 24);
    request_buf[5] = @intCast((dhcp_xid >> 16) & 0xFF);
    request_buf[6] = @intCast((dhcp_xid >> 8) & 0xFF);
    request_buf[7] = @intCast(dhcp_xid & 0xFF);

    // Seconds, Flags
    request_buf[8] = 0x00; request_buf[9] = 0x00;
    request_buf[10] = 0x80; request_buf[11] = 0x00; // Broadcast flag

    // Server IP at offset 20
    request_buf[20] = server_ip[0];
    request_buf[21] = server_ip[1];
    request_buf[22] = server_ip[2];
    request_buf[23] = server_ip[3];

    // Client hardware address at offset 28
    @memcpy(request_buf[28..34], &net.our_mac);

    // Magic cookie
    request_buf[236] = 0x63;
    request_buf[237] = 0x82;
    request_buf[238] = 0x53;
    request_buf[239] = 0x63;

    var pos: usize = 240;

    // DHCP Message Type: REQUEST
    request_buf[pos] = OPT_MESSAGE_TYPE;
    request_buf[pos + 1] = 1;
    request_buf[pos + 2] = DHCP_REQUEST;
    pos += 3;

    // Requested IP
    request_buf[pos] = 50;
    request_buf[pos + 1] = 4;
    request_buf[pos + 2] = offered_ip[0];
    request_buf[pos + 3] = offered_ip[1];
    request_buf[pos + 4] = offered_ip[2];
    request_buf[pos + 5] = offered_ip[3];
    pos += 6;

    // Server Identifier
    request_buf[pos] = 54;
    request_buf[pos + 1] = 4;
    request_buf[pos + 2] = server_ip[0];
    request_buf[pos + 3] = server_ip[1];
    request_buf[pos + 4] = server_ip[2];
    request_buf[pos + 5] = server_ip[3];
    pos += 6;

    // Hostname
    request_buf[pos] = 12;
    const hostname = "zig-kernel";
    request_buf[pos + 1] = @intCast(hostname.len);
    for (hostname, 0..) |ch, i| {
        request_buf[pos + 2 + i] = ch;
    }
    pos += 2 + hostname.len;

    // End option
    request_buf[pos] = OPT_END;
    pos += 1;

    return pos;
}

// Build DHCP packet as full Ethernet frame
fn buildDhcpFrame(dst_mac: [6]u8, src_port: u16, dst_port: u16, payload: []const u8, frame_buf: []u8) usize {
    const total_len = 14 + 20 + 8 + payload.len;

    // Ethernet header
    @memcpy(frame_buf[0..6], &dst_mac);
    @memcpy(frame_buf[6..12], &net.our_mac);
    frame_buf[12] = 0x08;
    frame_buf[13] = 0x00;

    // IP header
    const src_ip = net.our_ip;
    const dst_ip = [4]u8{ 255, 255, 255, 255 }; // broadcast
    ip_mod.buildHeader(src_ip, dst_ip, 17, @intCast(8 + payload.len), frame_buf[14..34]);

    // UDP header
    frame_buf[34] = @intCast(src_port >> 8);
    frame_buf[35] = @intCast(src_port & 0xFF);
    frame_buf[36] = @intCast(dst_port >> 8);
    frame_buf[37] = @intCast(dst_port & 0xFF);
    const udp_len: u16 = 8 + @as(u16, @intCast(payload.len));
    frame_buf[38] = @intCast(udp_len >> 8);
    frame_buf[39] = @intCast(udp_len & 0xFF);
    frame_buf[40] = 0x00; // checksum
    frame_buf[41] = 0x00;

    // Copy payload
    @memcpy(frame_buf[42..][0..payload.len], payload);

    return total_len;
}

var dhcp_tx_buf: [1514]u8 align(16) = undefined;
var request_buf: [548]u8 align(16) = undefined;
var discover_buf: [548]u8 align(16) = undefined;

pub fn sendDiscover() void {
    dhcp_xid +%= 0x12345678;

    vga.setColor(.light_cyan, .black);
    vga.write("[DHCP] Sending DISCOVER...\n");
    vga.setColor(.white, .black);

    const len = buildDiscover(&discover_buf);

    // Build full frame: broadcast MAC, our MAC, IP/UDP/DHCP
    const frame_len = buildDhcpFrame(
        [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
        DHCP_CLIENT_PORT,
        DHCP_SERVER_PORT,
        discover_buf[0..len],
        &dhcp_tx_buf,
    );

    e1000.transmit(dhcp_tx_buf[0..frame_len]);
}

pub fn sendRequest(offered_ip: [4]u8, server_ip: [4]u8) void {
    dhcp_xid +%= 0x12345678;

    vga.setColor(.light_cyan, .black);
    vga.write("[DHCP] Sending REQUEST for ");
    net.printIp(offered_ip);
    vga.write("...\n");
    vga.setColor(.white, .black);

    const len = buildRequest(offered_ip, server_ip);

    const frame_len = buildDhcpFrame(
        [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF },
        DHCP_CLIENT_PORT,
        DHCP_SERVER_PORT,
        request_buf[0..len],
        &dhcp_tx_buf,
    );

    e1000.transmit(dhcp_tx_buf[0..frame_len]);
}

fn parseOptions(data: []const u8) void {
    var pos: usize = 240;
    while (pos < data.len) {
        const opt = data[pos];
        if (opt == OPT_END) break;
        if (opt == 0xFF) break;
        if (pos + 1 >= data.len) break;

        const opt_len = data[pos + 1];
        if (pos + 2 + opt_len > data.len) break;

        switch (opt) {
            OPT_SUBNET_MASK => {
                if (opt_len == 4) {
                    lease_mask = .{ data[pos + 2], data[pos + 3], data[pos + 4], data[pos + 5] };
                }
            },
            OPT_ROUTER => {
                if (opt_len >= 4) {
                    lease_router = .{ data[pos + 2], data[pos + 3], data[pos + 4], data[pos + 5] };
                }
            },
            OPT_DNS_SERVER => {
                if (opt_len >= 4) {
                    lease_dns = .{ data[pos + 2], data[pos + 3], data[pos + 4], data[pos + 5] };
                }
            },
            OPT_LEASE_TIME => {
                if (opt_len == 4) {
                    lease_lease_sec = (@as(u32, data[pos + 2]) << 24) |
                        (@as(u32, data[pos + 3]) << 16) |
                        (@as(u32, data[pos + 4]) << 8) |
                        data[pos + 5];
                }
            },
            else => {},
        }

        pos += 2 + opt_len;
    }
}

pub fn handleResponse(frame: []const u8, ihl: usize, udp_hdr_len: usize) void {
    const payload_start = 14 + ihl + udp_hdr_len;
    if (payload_start >= frame.len) return;

    const data = frame[payload_start..];
    if (data.len < 240) return;

    // Check magic cookie
    if (data[236] != 0x63 or data[237] != 0x82 or data[238] != 0x53 or data[239] != 0x63) return;

    // Get message type from options
    var msg_type: u8 = 0;
    const offered_ip: [4]u8 = .{ data[16], data[17], data[18], data[19] }; // yiaddr
    const server_ip: [4]u8 = .{ data[20], data[21], data[22], data[23] }; // siaddr

    var opt_pos: usize = 240;
    while (opt_pos < data.len) {
        const opt = data[opt_pos];
        if (opt == OPT_END or opt == 0xFF) break;
        if (opt_pos + 1 >= data.len) break;
        const opt_len = data[opt_pos + 1];
        if (opt_pos + 2 + opt_len > data.len) break;

        if (opt == OPT_MESSAGE_TYPE and opt_len == 1) {
            msg_type = data[opt_pos + 2];
        }
        opt_pos += 2 + opt_len;
    }

    port.serialWrite("[DHCP] Received msg_type=");
    port.serialWriteDec(msg_type);
    port.serialWrite(" offered=");
    port.serialWriteDec(offered_ip[0]);
    port.serialWrite(".");
    port.serialWriteDec(offered_ip[1]);
    port.serialWrite(".");
    port.serialWriteDec(offered_ip[2]);
    port.serialWrite(".");
    port.serialWriteDec(offered_ip[3]);
    port.serialWrite("\n");

    switch (msg_type) {
        DHCP_OFFER => {
            vga.setColor(.light_green, .black);
            vga.write("[DHCP] OFFER received: ");
            net.printIp(offered_ip);
            vga.write("\n");
            vga.setColor(.white, .black);

            // Send REQUEST
            sendRequest(offered_ip, server_ip);
        },
        DHCP_ACK => {
            vga.setColor(.light_green, .black);
            vga.write("[DHCP] ACK received!\n");
            vga.setColor(.white, .black);

            // Parse options
            parseOptions(data);

            // Apply configuration
            lease_ip = offered_ip;
            lease_valid = true;

            net.our_ip = offered_ip;
            if (lease_router[0] != 0) {
                net.gateway_ip = lease_router;
            }
            if (lease_dns[0] != 0) {
                udp.dns_server = lease_dns;
            }

            vga.setColor(.light_green, .black);
            vga.write("[DHCP] Configuration applied:\n");
            vga.write("  IP:    ");
            net.printIp(net.our_ip);
            vga.write("\n  Mask:  ");
            net.printIp(lease_mask);
            vga.write("\n  Router: ");
            net.printIp(lease_router);
            vga.write("\n  DNS:   ");
            net.printIp(lease_dns);
            vga.write("\n  Lease: ");
            vga.writeDec(lease_lease_sec);
            vga.write("s\n");
            vga.setColor(.white, .black);

            // Resolve gateway MAC
            arp.resolve(net.gateway_ip);
        },
        DHCP_NAK => {
            vga.setColor(.light_red, .black);
            vga.write("[DHCP] NAK received - request rejected\n");
            vga.setColor(.white, .black);
        },
        else => {},
    }

    dhcp_rx_ready = true;
}

pub fn run() void {
    lease_valid = false;
    lease_ip = .{ 0, 0, 0, 0 };
    lease_mask = .{ 255, 255, 255, 0 };
    lease_router = .{ 0, 0, 0, 0 };
    lease_dns = .{ 0, 0, 0, 0 };
    lease_lease_sec = 0;

    // Temporarily set IP to 0.0.0.0 for DHCP
    const saved_ip = net.our_ip;
    net.our_ip = .{ 0, 0, 0, 0 };

    sendDiscover();

    // Wait for OFFER then ACK
    var timeout: u32 = 0;
    while (timeout < 500 and !lease_valid) : (timeout += 1) {
        net.poll();
        var j: u32 = 0;
        while (j < 100000) : (j += 1) {
            asm volatile ("nop");
        }
    }

    if (!lease_valid) {
        vga.setColor(.light_red, .black);
        vga.write("[DHCP] Failed to get lease, restoring static IP\n");
        vga.setColor(.white, .black);
        net.our_ip = saved_ip;
    }
}
