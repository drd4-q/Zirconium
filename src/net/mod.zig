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
pub var our_mac: [6]u8 = undefined;
pub var gateway_mac: [6]u8 = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
pub var mac_known: bool = false;

pub var rx_buf: [2048]u8 = undefined;
pub var send_buf: [1514]u8 = undefined;

pub fn init() void {
    @memcpy(&our_mac, &e1000.mac);
    arp_cache.init();
    port.serialWrite("[NET] IP: ");
    port.serialWriteDec(our_ip[0]);
    port.serialWrite(".");
    port.serialWriteDec(our_ip[1]);
    port.serialWrite(".");
    port.serialWriteDec(our_ip[2]);
    port.serialWrite(".");
    port.serialWriteDec(our_ip[3]);
    port.serialWrite(" GW: ");
    port.serialWriteDec(gateway_ip[0]);
    port.serialWrite(".");
    port.serialWriteDec(gateway_ip[1]);
    port.serialWrite(".");
    port.serialWriteDec(gateway_ip[2]);
    port.serialWrite(".");
    port.serialWriteDec(gateway_ip[3]);
    port.serialWrite("\n");
}

pub fn tick() void {
    arp_cache.tick();
}

pub fn poll() void {
    if (e1000.receive(&rx_buf)) |len| {
        handleFrame(rx_buf[0..len]);
    }
}

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

pub fn ensureArp(target_ip: [4]u8) bool {
    if (arp_cache.lookup(target_ip)) |_| return true;

    arp.request(target_ip);

    var timeout: u32 = 0;
    while (timeout < 200) : (timeout += 1) {
        poll();
        if (arp_cache.lookup(target_ip)) |_| return true;
        var j: u32 = 0;
        while (j < 50000) : (j += 1) {
            asm volatile ("nop");
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
