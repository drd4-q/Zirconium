const std = @import("std");
const root = @import("root");
const vga = root.vga;
const port = root.serial;

const CACHE_SIZE: usize = 32;
const ENTRY_TTL: u32 = 300; // ticks (~5 minutes at 100Hz)

pub const CacheEntry = struct {
    ip: [4]u8,
    mac: [6]u8,
    valid: bool = false,
    ttl: u32 = 0,
};

var cache: [CACHE_SIZE]CacheEntry = undefined;
var cache_count: usize = 0;

pub fn init() void {
    cache_count = 0;
    var i: usize = 0;
    while (i < CACHE_SIZE) : (i += 1) {
        cache[i].valid = false;
    }
}

pub fn lookup(ip: [4]u8) ?[6]u8 {
    var i: usize = 0;
    while (i < cache_count) : (i += 1) {
        if (cache[i].valid and
            cache[i].ip[0] == ip[0] and
            cache[i].ip[1] == ip[1] and
            cache[i].ip[2] == ip[2] and
            cache[i].ip[3] == ip[3])
        {
            cache[i].ttl = ENTRY_TTL; // refresh TTL
            return cache[i].mac;
        }
    }
    return null;
}

pub fn insert(ip: [4]u8, mac: [6]u8) void {
    // Check if already exists, update
    var i: usize = 0;
    while (i < cache_count) : (i += 1) {
        if (cache[i].valid and
            cache[i].ip[0] == ip[0] and
            cache[i].ip[1] == ip[1] and
            cache[i].ip[2] == ip[2] and
            cache[i].ip[3] == ip[3])
        {
            @memcpy(&cache[i].mac, &mac);
            cache[i].ttl = ENTRY_TTL;
            return;
        }
    }

    // Find empty slot
    i = 0;
    while (i < cache_count) : (i += 1) {
        if (!cache[i].valid) {
            cache[i].ip = ip;
            cache[i].mac = mac;
            cache[i].valid = true;
            cache[i].ttl = ENTRY_TTL;
            return;
        }
    }

    // Evict oldest entry if full
    if (cache_count < CACHE_SIZE) {
        cache[cache_count].ip = ip;
        cache[cache_count].mac = mac;
        cache[cache_count].valid = true;
        cache[cache_count].ttl = ENTRY_TTL;
        cache_count += 1;
    } else {
        // Find entry with smallest TTL
        var min_ttl: u32 = cache[0].ttl;
        var min_idx: usize = 0;
        i = 1;
        while (i < CACHE_SIZE) : (i += 1) {
            if (cache[i].ttl < min_ttl) {
                min_ttl = cache[i].ttl;
                min_idx = i;
            }
        }
        cache[min_idx].ip = ip;
        cache[min_idx].mac = mac;
        cache[min_idx].valid = true;
        cache[min_idx].ttl = ENTRY_TTL;
    }
}

pub fn remove(ip: [4]u8) void {
    var i: usize = 0;
    while (i < cache_count) : (i += 1) {
        if (cache[i].valid and
            cache[i].ip[0] == ip[0] and
            cache[i].ip[1] == ip[1] and
            cache[i].ip[2] == ip[2] and
            cache[i].ip[3] == ip[3])
        {
            cache[i].valid = false;
            return;
        }
    }
}

pub fn tick() void {
    var i: usize = 0;
    while (i < cache_count) : (i += 1) {
        if (cache[i].valid) {
            if (cache[i].ttl > 0) {
                cache[i] .ttl -= 1;
            } else {
                cache[i].valid = false;
            }
        }
    }
}

pub fn printCache() void {
    vga.setColor(.cyan, .black);
    vga.write("\n=== ARP Cache ===\n\n");
    vga.setColor(.white, .black);

    var found: bool = false;
    var i: usize = 0;
    while (i < cache_count) : (i += 1) {
        if (cache[i].valid) {
            found = true;
            vga.write("  ");
            printIpVga(cache[i].ip);
            vga.write("  ->  ");
            printMacVga(cache[i].mac);
            vga.write("  TTL=");
            vga.writeDec(cache[i].ttl);
            vga.write("\n");
        }
    }

    if (!found) {
        vga.setColor(.light_gray, .black);
        vga.write("  (empty)\n");
    }
    vga.setColor(.white, .black);
}

pub fn printCacheSerial() void {
    port.serialWrite("[ARP CACHE] entries=");
    var buf: [8]u8 = undefined;
    const len = std.fmt.bufPrint(&buf, "{d}", .{cache_count}) catch "??";
    port.serialWrite(len);
    port.serialWrite("\n");

    var i: usize = 0;
    while (i < cache_count) : (i += 1) {
        if (cache[i].valid) {
            port.serialWrite("  ");
            printIpSerial(cache[i].ip);
            port.serialWrite(" -> ");
            printMacSerial(cache[i].mac);
            port.serialWrite("\n");
        }
    }
}

fn printIpVga(ip: [4]u8) void {
    vga.writeDec(ip[0]);
    vga.putChar('.');
    vga.writeDec(ip[1]);
    vga.putChar('.');
    vga.writeDec(ip[2]);
    vga.putChar('.');
    vga.writeDec(ip[3]);
}

fn printMacVga(mac: [6]u8) void {
    const h = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (i > 0) vga.putChar(':');
        vga.putChar(h[mac[i] >> 4]);
        vga.putChar(h[mac[i] & 0xF]);
    }
}

fn printIpSerial(ip: [4]u8) void {
    port.serialWriteDec(ip[0]);
    port.serialWrite(".");
    port.serialWriteDec(ip[1]);
    port.serialWrite(".");
    port.serialWriteDec(ip[2]);
    port.serialWrite(".");
    port.serialWriteDec(ip[3]);
}

fn printMacSerial(mac: [6]u8) void {
    const h = "0123456789ABCDEF";
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        if (i > 0) port.serialWrite(":");
        var buf: [2]u8 = .{ h[mac[i] >> 4], h[mac[i] & 0xF] };
        port.serialWrite(&buf);
    }
}
