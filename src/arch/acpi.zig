// ACPI discovery: RSDP -> RSDT/XSDT -> MADT -> CPU count + local APIC IDs.
// Physical addresses are identity-mapped by the boot page tables, so the
// ACPI tables can be dereferenced directly at their physical addresses.

const serial = @import("../system/serial.zig");

pub const MAX_CPU: usize = 64;

pub var cpu_count: usize = 0;
pub var lapic_ids: [MAX_CPU]u32 = [_]u32{0} ** MAX_CPU;
pub var lapic_base: u64 = 0;
pub var rsdp_address: usize = 0;

const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32,
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32,
    creator_id: u32,
    creator_revision: u32,
};

fn readU8(addr: usize) u8 {
    const p: *const u8 = @ptrFromInt(addr);
    return p.*;
}

fn readU32(addr: usize) u32 {
    const p: *const u32 = @ptrFromInt(addr);
    return p.*;
}

fn readU64(addr: usize) u64 {
    const p: *const u64 = @ptrFromInt(addr);
    return p.*;
}

fn bytesAt(addr: usize) [*]const u8 {
    return @ptrFromInt(addr);
}

fn checksumOk(addr: usize, len: usize) bool {
    var sum: u8 = 0;
    const bytes = bytesAt(addr);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        sum = @as(u8, @intCast(sum +% bytes[i]));
    }
    return sum == 0;
}

fn hasSignature(addr: usize, sig: []const u8) bool {
    if (addr == 0) return false;
    const bytes = bytesAt(addr);
    var i: usize = 0;
    while (i < sig.len) : (i += 1) {
        if (bytes[i] != sig[i]) return false;
    }
    return true;
}

fn findRsdp() ?usize {
    // 1. Search the EBDA (1 KB starting at the EBDA segment from 0x40:0x0E)
    const ebda_seg: u32 = readU32(0x406) & 0xFFFF;
    if (ebda_seg >= 0x400 and ebda_seg < 0xA000) {
        var addr: usize = @as(usize, ebda_seg) * 16;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            if (hasSignature(addr, "RSD PTR ")) {
                if (checksumOk(addr, 20)) return addr;
            }
            addr += 16;
        }
    }

    // 2. Legacy memory range 0x0E0000 - 0x0FFFFF
    var addr: usize = 0x000E0000;
    while (addr < 0x00100000) : (addr += 16) {
        if (hasSignature(addr, "RSD PTR ")) {
            if (checksumOk(addr, 20)) return addr;
        }
    }
    return null;
}

const MADT_DATA_OFFSET: usize = 44; // header(36) + lapic(4) + flags(4)

fn parseMadt(table: usize) void {
    lapic_base = readU32(table + 36);
    const length = readU32(table + 4);
    if (length < MADT_DATA_OFFSET) return;
    const end = table + length;
    var pos: usize = table + MADT_DATA_OFFSET;

    while (pos < end) {
        const entry_type = readU8(pos);
        const entry_len = readU8(pos + 1);
        if (entry_len < 2) break;
        if (entry_type == 0) {
            const apic_id: u32 = readU8(pos + 3);
            const flags = readU32(pos + 4);
            if (flags & 1 != 0) {
                if (cpu_count < MAX_CPU) {
                    lapic_ids[cpu_count] = apic_id;
                    cpu_count += 1;
                }
            }
        }
        pos += entry_len;
    }
}

fn parseRsdt(rsdp: usize) void {
    const rsdt: usize = readU32(rsdp + 16);
    if (rsdt == 0) return;
    const length = readU32(rsdt + 4);
    if (length < 36) return;
    const count = (length - 36) / 4;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const tab: usize = readU32(rsdt + 36 + i * 4);
        if (hasSignature(tab, "APIC")) parseMadt(tab);
    }
}

fn parseXsdt(rsdp: usize) void {
    const xsdt = readU64(rsdp + 24);
    if (xsdt == 0) return;
    const length = readU32(xsdt + 4);
    if (length < 36) return;
    const count = (length - 36) / 8;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const tab: usize = @intCast(readU64(xsdt + 36 + i * 8));
        if (hasSignature(tab, "APIC")) parseMadt(tab);
    }
}

pub fn discover() bool {
    const rsdp = findRsdp() orelse {
        serial.serialWrite("[ACPI] No RSDP found (running single-CPU)\n");
        cpu_count = 1;
        return false;
    };
    rsdp_address = rsdp;

    const revision = readU8(rsdp + 15);
    if (revision == 0) {
        parseRsdt(rsdp);
    } else {
        parseXsdt(rsdp);
        if (cpu_count == 0) parseRsdt(rsdp);
    }
    if (cpu_count == 0) cpu_count = 1;

    serial.serialWrite("[ACPI] RSDP at 0x");
    serial.serialWriteHex(rsdp);
    serial.serialWrite(", revision ");
    serial.serialWriteDec(revision);
    serial.serialWrite(", LAPIC base 0x");
    serial.serialWriteHex(@intCast(lapic_base));
    serial.serialWrite("\n");
    serial.serialWrite("[ACPI] CPU ");
    serial.serialWriteDec(cpu_count);
    serial.serialWrite(" LAPIC ID: ");
    var i: usize = 0;
    while (i < cpu_count) : (i += 1) {
        serial.serialWriteDec(@intCast(lapic_ids[i]));
        if (i + 1 < cpu_count) serial.serialWrite(", ");
    }
    serial.serialWrite("\n");
    return cpu_count > 0;
}