const root = @import("root");
const vga = root.vga;
const port = root.serial;
const e1000 = @import("../drivers/e1000.zig");
const arp = @import("arp.zig");
const arp_cache = @import("arp_cache.zig");
const ip_mod = @import("ip.zig");
const dhcp_mod = @import("dhcp.zig");

pub var gateway_ip: [4]u8 = .{ 10, 0, 2, 2 };
pub var our_ip: [4]u8 = .{ 10, 0, 2, 15 };
pub var netmask: [4]u8 = .{ 255, 255, 255, 0 };
pub var our_mac: [6]u8 = undefined;
pub var gateway_mac: [6]u8 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub var mac_known: bool = false;

pub var rx_buf: [2048]u8 = undefined;
pub var send_buf: [1514]u8 = undefined;

pub fn init() void {
    @memcpy(&our_mac, &e1000.mac);
    arp_cache.init();
    port.serialWrite("[NET] IP: ");
    printIpSerial(our_ip);
    port.serialWrite(" GW: ");
    printIpSerial(gateway_ip);
    port.serialWrite("\n");

    // Resolve the gateway once at init: every off-subnet packet needs its MAC,
    // and doing it lazily meant the first SYN/DNS query went to the broadcast
    // address (which QEMU's slirp silently drops).
    if (resolveGateway()) {
        port.serialWrite("[NET] Gateway MAC resolved\n");
    } else {
        port.serialWrite("[NET] Gateway ARP failed (will retry on demand)\n");
    }
}

pub fn tick() void {
    arp_cache.tick();
    @import("tcp.zig").retxTick();
}

pub fn poll() void {
    // Re-entrancy guard: packet handlers transmit (ACKs, ICMP replies) and the
    // transmit path may want to ARP, which would call back into poll() and
    // overwrite `rx_buf` while the outer handler is still parsing it.
    if (polling) return;
    polling = true;
    defer polling = false;

    // Drain the whole RX ring, not just one descriptor. With a single packet
    // per poll the ring backed up under bursts (SYN-ACK + data in the same
    // batch) and the handshake appeared to time out.
    var drained: usize = 0;
    while (drained < 32) : (drained += 1) {
        const len = e1000.receive(&rx_buf) orelse return;
        handleFrame(rx_buf[0..len]);
    }
}

var polling: bool = false;

fn handleFrame(frame: []const u8) void {
    if (frame.len < 14) return;
    const eth_type = (@as(u16, frame[12]) << 8) | frame[13];

    if (eth_type == 0x0806) {
        arp.handlePacket(frame);
    } else if (eth_type == 0x0800) {
        ip_mod.handlePacket(frame);
    }
}

pub fn resolveMac(ip: [4]u8) ?[6]u8 {
    return arp_cache.lookup(ip);
}

/// True when `ip` is reachable directly on our link (same subnet).
pub fn onLink(ip: [4]u8) bool {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if ((ip[i] & netmask[i]) != (our_ip[i] & netmask[i])) return false;
    }
    return true;
}

/// The IP whose MAC we must put in the Ethernet header to reach `dst`:
/// `dst` itself when on-link, otherwise the gateway.
pub fn nextHop(dst: [4]u8) [4]u8 {
    if (dst[0] == 255 and dst[1] == 255 and dst[2] == 255 and dst[3] == 255) return dst;
    if (onLink(dst)) return dst;
    return gateway_ip;
}

/// Resolve the Ethernet destination for an IP packet, following the routing
/// rule above and ARPing if needed. Returns null when it cannot be resolved —
/// callers must drop the packet instead of sending it to the broadcast address,
/// which is what the old `orelse net.gateway_mac` fallback effectively did
/// (gateway_mac starts out as ff:ff:ff:ff:ff:ff).
pub fn nextHopMac(dst: [4]u8) ?[6]u8 {
    if (dst[0] == 255 and dst[1] == 255 and dst[2] == 255 and dst[3] == 255) {
        return [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    }

    const hop = nextHop(dst);
    if (arp_cache.lookup(hop)) |mac| return mac;

    // Called from inside a packet handler (e.g. sending an ACK): we cannot
    // re-enter poll() to wait for the reply, so only kick off the request and
    // let the caller retransmit.
    if (polling) {
        arp.request(hop);
        return null;
    }

    if (!ensureArp(hop)) return null;
    return arp_cache.lookup(hop);
}

pub fn ensureArp(target_ip: [4]u8) bool {
    if (arp_cache.lookup(target_ip)) |_| return true;

    const timer = @import("../drivers/timer.zig");

    // Retry the request: a single ARP request that is lost (or answered after
    // the deadline) used to fail the whole connect.
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        arp.request(target_ip);
        const deadline = timer.ticks +% 50; // 500ms per attempt
        while (timer.ticks < deadline) {
            poll();
            if (arp_cache.lookup(target_ip)) |_| return true;
        }
    }
    return false;
}

pub fn resolveGateway() bool {
    return ensureArp(gateway_ip);
}

pub fn sendFrame(dst: [6]u8, eth_type_val: u16, payload: []const u8) void {
    const total = 14 + payload.len;

    send_buf[0] = dst[0]; send_buf[1] = dst[1]; send_buf[2] = dst[2];
    send_buf[3] = dst[3]; send_buf[4] = dst[4]; send_buf[5] = dst[5];
    send_buf[6] = our_mac[0]; send_buf[7] = our_mac[1];
    send_buf[8] = our_mac[2]; send_buf[9] = our_mac[3];
    send_buf[10] = our_mac[4]; send_buf[11] = our_mac[5];
    send_buf[12] = @intCast(eth_type_val >> 8);
    send_buf[13] = @intCast(eth_type_val & 0xFF);
    var i: usize = 0;
    while (i < payload.len) : (i += 1) {
        send_buf[14 + i] = payload[i];
    }

    e1000.transmit(send_buf[0..total]);
}

pub fn printIp(ip: [4]u8) void {
    vga.writeDec(ip[0]);
    vga.putChar('.');
    vga.writeDec(ip[1]);
    vga.putChar('.');
    vga.writeDec(ip[2]);
    vga.putChar('.');
    vga.writeDec(ip[3]);
}

pub fn printIpSerial(ip: [4]u8) void {
    port.serialWriteDec(ip[0]);
    port.serialWrite(".");
    port.serialWriteDec(ip[1]);
    port.serialWrite(".");
    port.serialWriteDec(ip[2]);
    port.serialWrite(".");
    port.serialWriteDec(ip[3]);
}
