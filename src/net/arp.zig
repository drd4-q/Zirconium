const root = @import("root");
const vga = root.vga;
const port = root.serial;
const net = @import("mod.zig");
const e1000 = @import("../drivers/e1000.zig");

pub fn handlePacket(frame: []const u8) void {
    if (frame.len < 42) return;
    const arp = frame[14..];

    const opcode = (@as(u16, arp[6]) << 8) | arp[7];
    const sender_ip = arp[14..18];
    const sender_mac = arp[8..14];

    if (opcode == 0x0002) { // ARP Reply
        if (sender_ip[0] == net.gateway_ip[0] and
            sender_ip[1] == net.gateway_ip[1] and
            sender_ip[2] == net.gateway_ip[2] and
            sender_ip[3] == net.gateway_ip[3])
        {
            @memcpy(&net.gateway_mac, sender_mac[0..6]);
            net.mac_known = true;
            port.serialWrite("[ARP] Gateway MAC resolved\n");
        }
    } else if (opcode == 0x0001) { // ARP Request
        const target_ip = arp[18..22];
        if (target_ip[0] == net.our_ip[0] and
            target_ip[1] == net.our_ip[1] and
            target_ip[2] == net.our_ip[2] and
            target_ip[3] == net.our_ip[3])
        {
            sendReply(sender_mac, sender_ip);
        }
    }
}

var arp_tx_buf: [42]u8 align(16) = undefined;

pub fn request(target_ip: [4]u8) void {
    const mac = net.our_mac;
    const ip = net.our_ip;

    // Ethernet header: broadcast
    arp_tx_buf[0] = 0xFF; arp_tx_buf[1] = 0xFF; arp_tx_buf[2] = 0xFF;
    arp_tx_buf[3] = 0xFF; arp_tx_buf[4] = 0xFF; arp_tx_buf[5] = 0xFF;
    arp_tx_buf[6] = mac[0]; arp_tx_buf[7] = mac[1];
    arp_tx_buf[8] = mac[2]; arp_tx_buf[9] = mac[3];
    arp_tx_buf[10] = mac[4]; arp_tx_buf[11] = mac[5];
    arp_tx_buf[12] = 0x08;
    arp_tx_buf[13] = 0x06;

    // ARP header
    arp_tx_buf[14] = 0x00; arp_tx_buf[15] = 0x01; // Hardware type: Ethernet
    arp_tx_buf[16] = 0x08; arp_tx_buf[17] = 0x00; // Protocol type: IPv4
    arp_tx_buf[18] = 0x06;                         // Hardware size
    arp_tx_buf[19] = 0x04;                         // Protocol size
    arp_tx_buf[20] = 0x00; arp_tx_buf[21] = 0x01; // Opcode: Request

    // Sender
    arp_tx_buf[22] = mac[0]; arp_tx_buf[23] = mac[1];
    arp_tx_buf[24] = mac[2]; arp_tx_buf[25] = mac[3];
    arp_tx_buf[26] = mac[4]; arp_tx_buf[27] = mac[5];
    arp_tx_buf[28] = ip[0]; arp_tx_buf[29] = ip[1];
    arp_tx_buf[30] = ip[2]; arp_tx_buf[31] = ip[3];

    // Target MAC zeroed
    arp_tx_buf[32] = 0; arp_tx_buf[33] = 0; arp_tx_buf[34] = 0;
    arp_tx_buf[35] = 0; arp_tx_buf[36] = 0; arp_tx_buf[37] = 0;

    // Target IP
    arp_tx_buf[38] = target_ip[0]; arp_tx_buf[39] = target_ip[1];
    arp_tx_buf[40] = target_ip[2]; arp_tx_buf[41] = target_ip[3];

    e1000.transmit(arp_tx_buf[0..42]);
}

var reply_tx_buf: [42]u8 align(16) = undefined;

fn sendReply(dst_mac: []const u8, target_ip: []const u8) void {
    @memcpy(reply_tx_buf[0..6], dst_mac);
    @memcpy(reply_tx_buf[6..12], &net.our_mac);
    reply_tx_buf[12] = 0x08;
    reply_tx_buf[13] = 0x06;

    var j: usize = 14;
    while (j < 42) : (j += 1) {
        reply_tx_buf[j] = 0;
    }

    reply_tx_buf[14] = 0x00; reply_tx_buf[15] = 0x01;
    reply_tx_buf[16] = 0x08; reply_tx_buf[17] = 0x00;
    reply_tx_buf[18] = 0x06;
    reply_tx_buf[19] = 0x04;
    reply_tx_buf[20] = 0x00; reply_tx_buf[21] = 0x02; // Reply

    @memcpy(reply_tx_buf[22..28], &net.our_mac);
    @memcpy(reply_tx_buf[28..32], &net.our_ip);
    @memcpy(reply_tx_buf[32..38], dst_mac);
    @memcpy(reply_tx_buf[38..42], target_ip);

    e1000.transmit(reply_tx_buf[0..42]);
}
