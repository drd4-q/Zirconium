//! A virtual CPU.
//!
//! The interpreter for the guest's instructions.  It is deliberately small:
//! it implements the set of opcodes a guest kernel actually uses while it
//! brings itself up, and it traps on anything else rather than guessing.
//!
//! Two rules keep it honest:
//!
//!   * **Every memory access goes through the guest's page tables.**  The
//!     host address is whatever the walk says, and a guest that touches a
//!     page it does not own faults, exactly as it would on real hardware.
//!   * **The flags are computed properly.**  A guest's boot path branches on
//!     them, and an emulator that gets `ZF` wrong does not fail loudly - it
//!     takes the wrong branch and hangs somewhere else.
//!
//! The device is not special-cased: the hypervisor maps the ZVP's registers
//! into the guest's address space as ordinary memory, so an access to it is
//! just a memory access.  The hypervisor notices the doorbell by polling the
//! same bytes.

const std = @import("std");
const root = @import("root");
const mmu_mod = @import("mmu.zig");
const identity_mod = @import("identity.zig");
const uart_mod = @import("uart.zig");
const pci_mod = @import("pci.zig");

/// The size of a guest page.
const PAGE_SIZE: u64 = 4096;

pub const Memory = mmu_mod.Memory;
pub const Identity = identity_mod.Identity;

/// The register indices, in the encoding order.
pub const RAX: usize = 0;
pub const RCX: usize = 1;
pub const RDX: usize = 2;
pub const RBX: usize = 3;
pub const RSP: usize = 4;
pub const RBP: usize = 5;
pub const RSI: usize = 6;
pub const RDI: usize = 7;

// ─── Flags ──────────────────────────────────────────────────────────

pub const FLAG_CF: u64 = 1 << 0;
pub const FLAG_PF: u64 = 1 << 2;
pub const FLAG_AF: u64 = 1 << 4;
pub const FLAG_ZF: u64 = 1 << 6;
pub const FLAG_SF: u64 = 1 << 7;
pub const FLAG_TF: u64 = 1 << 8;
pub const FLAG_IF: u64 = 1 << 9;
pub const FLAG_DF: u64 = 1 << 10;
pub const FLAG_OF: u64 = 1 << 11;

/// The condition codes of the conditional jumps.
const CC_O: u8 = 0;
const CC_NO: u8 = 1;
const CC_B: u8 = 2;
const CC_AE: u8 = 3;
const CC_E: u8 = 4;
const CC_NE: u8 = 5;
const CC_BE: u8 = 6;
const CC_A: u8 = 7;
const CC_S: u8 = 8;
const CC_NS: u8 = 9;
const CC_P: u8 = 10;
const CC_NP: u8 = 11;
const CC_L: u8 = 12;
const CC_GE: u8 = 13;
const CC_LE: u8 = 14;
const CC_G: u8 = 15;

/// A trap: the guest did something the emulator does not implement, or
/// something it is not allowed to do.
pub const Trap = error{
    /// The guest executed an opcode the interpreter does not implement.
    UnknownInstruction,
    /// The guest touched memory it does not own.
    MemoryFault,
    /// The guest executed `hlt`.
    Halted,
    /// The guest executed an instruction the emulator refuses to guess at.
    Unsupported,
};

pub const Cpu = struct {
    /// The general purpose registers, in the encoding order.
    regs: [16]u64 = @splat(0),
    rip: u64 = 0,
    rflags: u64 = FLAG_IF | 0x2,
    /// The guest's memory: its RAM and its page tables.
    ///
    /// A pointer, not a copy: the hypervisor moves a device when the guest
    /// programs its base address register, and a copy would not see it.
    memory: *Memory = undefined,
    /// The PCI bus the guest's port I/O reaches.
    pci: ?*pci_mod.Bus = null,
    /// The identity the guest is shown: what `cpuid` reports.
    identity: Identity = .{},
    /// The guest's own serial port.  It is not the host's: a guest that
    /// programmed the host's UART would change the host's baud rate.
    uart: uart_mod.Uart = .{},
    /// True once the guest has executed `hlt`.
    halted: bool = false,
    /// How many instructions have been executed.
    instructions: u64 = 0,
    /// Set when the guest trapped.  The reason is in `trap`.
    trapped: bool = false,
    trap: Trap = error.UnknownInstruction,
    /// Where the guest trapped, for the log.
    trap_rip: u64 = 0,
    /// A limit on how many instructions one run may execute, so a guest that
    /// spins cannot take the host's CPU away from the other machines.
    budget: u64 = 0,

    // ─── Register access ──────────────────────────────────────────

    pub inline fn getReg(self: *const Cpu, index: usize) u64 {
        return self.regs[index];
    }

    pub inline fn setReg(self: *Cpu, index: usize, value: u64) void {
        self.regs[index] = value;
    }

    pub inline fn flag(self: *const Cpu, mask: u64) bool {
        return (self.rflags & mask) != 0;
    }

    pub inline fn setFlag(self: *Cpu, mask: u64, on: bool) void {
        if (on) {
            self.rflags |= mask;
        } else {
            self.rflags &= ~mask;
        }
    }

    // ─── Memory ───────────────────────────────────────────────────

    /// Translate a guest virtual address into a host address.
    pub fn translate(self: *const Cpu, gva: u64) Trap!u64 {
        return self.memory.translate(gva) catch |err| switch (err) {
            error.NotPresent => error.MemoryFault,
            error.OutsideRam => error.MemoryFault,
            error.Malformed => error.MemoryFault,
        };
    }

    pub fn readByte(self: *Cpu, gva: u64) Trap!u8 {
        const host = try self.translate(gva);
        const p: [*]const volatile u8 = @ptrFromInt(host);
        return p[0];
    }

    pub fn writeByte(self: *Cpu, gva: u64, value: u8) Trap!void {
        const host = try self.translate(gva);
        const p: [*]volatile u8 = @ptrFromInt(host);
        p[0] = value;
    }

    /// Read `size` bytes (1, 2, 4 or 8), little endian.
    ///
    /// The page walk is the most expensive thing the emulator does, so an
    /// access that stays inside one page is translated **once** and the bytes
    /// are then read from the host address.  Reading byte by byte - and so
    /// walking the page tables once per byte - made an eight byte load cost
    /// thirty two table reads.
    pub fn read(self: *Cpu, gva: u64, size: u8) Trap!u64 {
        const host = try self.translate(gva);
        const offset = gva & (PAGE_SIZE - 1);
        if (offset + size <= PAGE_SIZE) {
            const p: [*]const volatile u8 = @ptrFromInt(host);
            var value: u64 = 0;
            var i: u8 = 0;
            while (i < size) : (i += 1) {
                value |= @as(u64, p[i]) << @intCast(i * 8);
            }
            return value;
        }

        // The access crosses a page: every byte needs its own translation.
        var value: u64 = 0;
        var i: u8 = 0;
        while (i < size) : (i += 1) {
            const b = try self.readByte(gva + i);
            value |= @as(u64, b) << @intCast(i * 8);
        }
        return value;
    }

    /// Write `size` bytes (1, 2, 4 or 8), little endian.
    ///
    /// One translation for an access that stays inside one page, the same
    /// reason as in `read()`.
    pub fn write(self: *Cpu, gva: u64, size: u8, value: u64) Trap!void {
        const host = try self.translate(gva);
        const offset = gva & (PAGE_SIZE - 1);
        if (offset + size <= PAGE_SIZE) {
            const p: [*]volatile u8 = @ptrFromInt(host);
            var i: u8 = 0;
            while (i < size) : (i += 1) {
                p[i] = @truncate(value >> @intCast(i * 8));
            }
            return;
        }

        var i: u8 = 0;
        while (i < size) : (i += 1) {
            try self.writeByte(gva + i, @truncate(value >> @intCast(i * 8)));
        }
    }

    // ─── Flags ────────────────────────────────────────────────────

    fn maskFor(size: u8) u64 {
        return switch (size) {
            1 => 0xFF,
            2 => 0xFFFF,
            4 => 0xFFFF_FFFF,
            else => 0xFFFF_FFFF_FFFF_FFFF,
        };
    }

    fn signBit(size: u8) u64 {
        return @as(u64, 1) << @intCast(size * 8 - 1);
    }

    /// The flags a logical operation sets: SF, ZF and PF.  It never touches
    /// CF or OF, which a logical operation leaves alone.
    fn setLogicFlags(self: *Cpu, result: u64, size: u8) void {
        const m = maskFor(size);
        const r = result & m;
        self.setFlag(FLAG_ZF, r == 0);
        self.setFlag(FLAG_SF, (r & signBit(size)) != 0);
        self.setFlag(FLAG_PF, parity(r & 0xFF));
    }

    /// The flags an addition sets.
    fn setAddFlags(self: *Cpu, a: u64, b: u64, carry_in: u64, result: u64, size: u8) void {
        const m = maskFor(size);
        const r = result & m;
        const sign = signBit(size);

        self.setFlag(FLAG_ZF, r == 0);
        self.setFlag(FLAG_SF, (r & sign) != 0);
        self.setFlag(FLAG_PF, parity(r & 0xFF));

        // The carry out of the top bit.
        const full = (@as(u64, a & m) + (b & m) + carry_in);
        self.setFlag(FLAG_CF, (full & ~m) != 0 or (full > m));

        // Overflow: the operands had the same sign and the result does not.
        const a_sign = (a & sign) != 0;
        const b_sign = (b & sign) != 0;
        const r_sign = (r & sign) != 0;
        self.setFlag(FLAG_OF, a_sign == b_sign and r_sign != a_sign);

        // The auxiliary carry, from bit 4.
        self.setFlag(FLAG_AF, ((a ^ b ^ r) & 0x10) != 0);
    }

    /// The flags a subtraction sets.
    fn setSubFlags(self: *Cpu, a: u64, b: u64, borrow_in: u64, result: u64, size: u8) void {
        const m = maskFor(size);
        const r = result & m;
        const sign = signBit(size);

        self.setFlag(FLAG_ZF, r == 0);
        self.setFlag(FLAG_SF, (r & sign) != 0);
        self.setFlag(FLAG_PF, parity(r & 0xFF));

        // The borrow out: the subtraction went below zero.
        const full = (@as(u64, a & m) - (b & m) - borrow_in);
        self.setFlag(FLAG_CF, (full & ~m) != 0 or ((a & m) < (b & m) + borrow_in));

        // Overflow: the operands had different signs and the result's sign
        // differs from the first operand's.
        const a_sign = (a & sign) != 0;
        const b_sign = (b & sign) != 0;
        const r_sign = (r & sign) != 0;
        self.setFlag(FLAG_OF, a_sign != b_sign and r_sign != a_sign);

        self.setFlag(FLAG_AF, ((a ^ b ^ r) & 0x10) != 0);
    }

    /// Is the condition of a conditional jump satisfied?
    fn condition(self: *const Cpu, cc: u8) bool {
        const cf = self.flag(FLAG_CF);
        const zf = self.flag(FLAG_ZF);
        const sf = self.flag(FLAG_SF);
        const of = self.flag(FLAG_OF);
        const pf = self.flag(FLAG_PF);
        return switch (cc) {
            CC_O => of,
            CC_NO => !of,
            CC_B => cf,
            CC_AE => !cf,
            CC_E => zf,
            CC_NE => !zf,
            CC_BE => cf or zf,
            CC_A => !cf and !zf,
            CC_S => sf,
            CC_NS => !sf,
            CC_P => pf,
            CC_NP => !pf,
            CC_L => sf != of,
            CC_GE => sf == of,
            CC_LE => zf or (sf != of),
            CC_G => !zf and (sf == of),
            else => false,
        };
    }

    // ─── Fetch and decode ─────────────────────────────────────────

    fn fetchByte(self: *Cpu) Trap!u8 {
        const b = try self.readByte(self.rip);
        self.rip +%= 1;
        return b;
    }

    fn fetchImm(self: *Cpu, size: u8) Trap!u64 {
        const v = try self.read(self.rip, size);
        self.rip +%= size;
        return v;
    }

    /// The decoded ModRM byte and its effective address.
    const ModRm = struct {
        mod: u8,
        reg: u8,
        rm: u8,
        /// True when the r/m operand is memory.
        is_mem: bool,
        /// The effective address, when it is memory and not RIP-relative.
        addr: u64,
        /// True when the address is relative to the end of the instruction.
        /// The displacement is in `addr` until the address is computed.
        rip_relative: bool,
    };

    /// Decode the ModRM byte (and the SIB and displacement that follow it).
    ///
    /// A RIP-relative address is the awkward one: the displacement is
    /// relative to the *end* of the instruction, and the instruction is not
    /// finished yet - the immediate of `mov rm, imm` comes after the
    /// displacement.  So the displacement is kept and the address is computed
    /// later, when the instruction is done.
    fn decodeModRm(self: *Cpu, rex: u8) Trap!ModRm {
        const modrm = try self.fetchByte();
        const mod = (modrm >> 6) & 3;
        const reg = ((modrm >> 3) & 7) | (if ((rex & 0x04) != 0) @as(u8, 8) else @as(u8, 0));
        const rm = (modrm & 7) | (if ((rex & 0x01) != 0) @as(u8, 8) else 0);

        if (mod == 3) {
            return .{ .mod = mod, .reg = reg, .rm = rm, .is_mem = false, .addr = 0, .rip_relative = false };
        }

        var base: u64 = 0;
        var index: u64 = 0;
        var scale: u6 = 0;
        var rip_relative = false;
        // The displacement is **signed**: a RIP-relative one is usually
        // negative, and taking it as unsigned puts the effective address
        // millions of bytes off - which looks like the guest jumping into
        // nowhere.
        var disp: i64 = 0;

        if ((rm & 7) == 4) {
            // A SIB byte follows.
            const sib = try self.fetchByte();
            scale = @truncate(sib >> 6);
            const idx = ((sib >> 3) & 7) | (if ((rex & 0x02) != 0) @as(u8, 8) else 0);
            const bs = (sib & 7) | (if ((rex & 0x01) != 0) @as(u8, 8) else 0);
            if (idx != 4) {
                index = self.regs[idx] << scale;
            }
            if ((bs & 7) == 5 and mod == 0) {
                // No base register: the displacement is the whole address.
                disp = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
                return .{
                    .mod = mod,
                    .reg = reg,
                    .rm = rm,
                    .is_mem = true,
                    .addr = @as(u64, @bitCast(disp)),
                    .rip_relative = false,
                };
            }
            base = self.regs[bs];
        } else if ((rm & 7) == 5 and mod == 0) {
            // RIP-relative.
            disp = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
            rip_relative = true;
        } else {
            base = self.regs[rm];
        }

        if (!rip_relative) {
            if (mod == 1) {
                disp = @as(i8, @bitCast(@as(u8, @truncate(try self.fetchImm(1)))));
            } else if (mod == 2) {
                disp = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
            }
        }

        return .{
            .mod = mod,
            .reg = reg,
            .rm = rm,
            .is_mem = true,
            .addr = base +% index +% @as(u64, @bitCast(disp)),
            .rip_relative = rip_relative,
        };
    }

    /// The effective address of a memory operand.
    ///
    /// For a RIP-relative operand this is the displacement plus the address
    /// of the *next* instruction, which is where `self.rip` points by the
    /// time the operand is used.
    fn effectiveAddr(self: *Cpu, m: ModRm) u64 {
        if (m.rip_relative) return m.addr +% self.rip;
        return m.addr;
    }

    /// Read the r/m operand.
    fn readRm(self: *Cpu, m: ModRm, size: u8) Trap!u64 {
        if (!m.is_mem) return self.regs[m.rm];
        return self.read(self.effectiveAddr(m), size);
    }

    /// Write the r/m operand.
    fn writeRm(self: *Cpu, m: ModRm, size: u8, value: u64) Trap!void {
        if (!m.is_mem) {
            self.regs[m.rm] = value;
            return;
        }
        try self.write(self.effectiveAddr(m), size, value);
    }

    // ─── Execution ────────────────────────────────────────────────

    /// Execute one instruction.
    pub fn step(self: *Cpu) Trap!void {
        var rex: u8 = 0;
        var operand_size: u8 = 4;
        var prefix: u8 = 0;
        var opcode: u8 = 0;

        // Prefixes.  A REX prefix may follow another prefix, and the last
        // one before the opcode wins.
        while (true) {
            const b = try self.fetchByte();
            if ((b & 0xF0) == 0x40) {
                rex = b;
                if ((b & 0x08) != 0) operand_size = 8;
                continue;
            }
            switch (b) {
                0x66 => {
                    operand_size = 2;
                    continue;
                },
                0x67, 0xF0, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65 => continue,
                0xF2, 0xF3 => {
                    prefix = b;
                    continue;
                },
                else => {
                    opcode = b;
                    break;
                },
            }
        }

        self.instructions += 1;
        try self.execute(opcode, rex, operand_size, prefix);
    }

    /// Execute instructions until the budget runs out, the guest halts or it
    /// traps.
    pub fn run(self: *Cpu, budget: u64) void {
        // A guest that has halted stays halted.  Without this check the
        // emulator would keep executing whatever follows the `hlt` - the
        // guest's memory past the end of its code - and the shell's input
        // loop pays for it on every poll.
        if (self.halted) return;

        self.trapped = false;
        var n: u64 = 0;
        while (n < budget) : (n += 1) {
            self.trap_rip = self.rip;
            self.step() catch |err| {
                if (err == error.Halted) {
                    self.halted = true;
                    return;
                }
                self.trapped = true;
                self.trap = err;
                return;
            };
            if (self.halted) return;
        }
    }

    fn execute(self: *Cpu, opcode: u8, rex: u8, operand_size: u8, prefix: u8) Trap!void {
        const sz = operand_size;

        // ── The two-byte opcodes ──────────────────────────────────
        if (opcode == 0x0F) {
            const op2 = try self.fetchByte();
            return self.execute0F(op2, rex, operand_size, prefix);
        }

        // ── The arithmetic and logic groups ───────────────────────
        // 00..3D are eight groups of six: the pattern is
        //   base+0: rm8, reg8     base+1: rm8, imm8
        //   base+2: rm, reg       base+3: rm, imm
        // and the groups are add, or, adc, sbb, and, sub, xor, cmp.
        if (opcode < 0x40 and (opcode & 7) < 6) {
            const group: u8 = (opcode >> 3) & 7;
            const form: u8 = opcode & 7;
            return self.executeGroup(group, form, rex, sz);
        }

        switch (opcode) {
            0x50...0x57 => {
                // push a register
                const index: usize = @as(usize, opcode & 7) | (if ((rex & 0x01) != 0) @as(usize, 8) else 0);
                return self.push(self.regs[index]);
            },
            0x58...0x5F => {
                // pop a register
                const index: usize = @as(usize, opcode & 7) | (if ((rex & 0x01) != 0) @as(usize, 8) else 0);
                self.regs[index] = try self.pop();
                return;
            },
            0x63 => {
                // movsxd
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, 4);
                const sign = @as(i32, @bitCast(@as(u32, @truncate(value))));
                try self.writeRm(m, sz, @as(u64, @bitCast(@as(i64, sign))));
                return;
            },
            0x68 => {
                const imm = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
                return self.push(@as(u64, @bitCast(@as(i64, imm))));
            },
            0x6A => {
                const imm = @as(i8, @bitCast(@as(u8, @truncate(try self.fetchImm(1)))));
                return self.push(@as(u64, @bitCast(@as(i64, imm))));
            },
            0x69 => {
                // imul r, rm, imm32
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, sz);
                const imm = @as(i64, @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4))))));
                const product: i64 = @as(i64, @bitCast(value)) *% imm;
                try self.writeRm(m, sz, @as(u64, @bitCast(product)));
                return;
            },
            0x6B => {
                // imul r, rm, imm8
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, sz);
                const imm = @as(i64, @as(i8, @bitCast(@as(u8, @truncate(try self.fetchImm(1))))));
                const product: i64 = @as(i64, @bitCast(value)) *% imm;
                try self.writeRm(m, sz, @as(u64, @bitCast(product)));
                return;
            },
            0x70...0x7F => {
                // jcc rel8
                const cc: u8 = opcode & 0x0F;
                const disp = @as(i8, @bitCast(@as(u8, @truncate(try self.fetchImm(1)))));
                if (self.condition(cc)) {
                    self.rip +%= @as(u64, @bitCast(@as(i64, disp)));
                }
                return;
            },
            0x80, 0x81, 0x83 => {
                // The group-1 opcodes with an immediate.
                const m = try self.decodeModRm(rex);
                const width: u8 = if (opcode == 0x80) 1 else sz;
                const imm: u64 = switch (opcode) {
                    0x80 => try self.fetchImm(1),
                    0x81 => try self.fetchImm(width),
                    else => blk: {
                        const v = @as(i8, @bitCast(@as(u8, @truncate(try self.fetchImm(1)))));
                        break :blk @as(u64, @bitCast(@as(i64, v)));
                    },
                };
                const value = try self.readRm(m, width);
                const op = m.reg & 7;
                const result = try self.groupOp(op, value, imm, width);
                // `cmp` (group 7) computes the flags and leaves the operand.
                if (op != 7) try self.writeRm(m, width, result);
                return;
            },
            0x84 => {
                const m = try self.decodeModRm(rex);
                const a = try self.readRm(m, 1);
                const b = self.regs[m.reg];
                self.setLogicFlags(a & b, 1);
                return;
            },
            0x85 => {
                const m = try self.decodeModRm(rex);
                const a = try self.readRm(m, sz);
                const b = self.regs[m.reg];
                self.setLogicFlags(a & b, sz);
                return;
            },
            0x86 => {
                const m = try self.decodeModRm(rex);
                const a = try self.readRm(m, 1);
                try self.writeRm(m, 1, self.regs[m.reg]);
                self.regs[m.reg] = a;
                return;
            },
            0x87 => {
                const m = try self.decodeModRm(rex);
                const a = try self.readRm(m, sz);
                try self.writeRm(m, sz, self.regs[m.reg]);
                self.regs[m.reg] = a;
                return;
            },
            0x88 => {
                const m = try self.decodeModRm(rex);
                try self.writeRm(m, 1, self.regs[m.reg]);
                return;
            },
            0x89 => {
                const m = try self.decodeModRm(rex);
                try self.writeRm(m, sz, self.regs[m.reg]);
                return;
            },
            0x8A => {
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, 1);
                self.regs[m.reg] = value;
                return;
            },
            0x8B => {
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, sz);
                self.regs[m.reg] = value;
                return;
            },
            0x8D => {
                // lea: the effective address as a value
                const m = try self.decodeModRm(rex);
                if (!m.is_mem) return error.Unsupported;
                self.regs[m.reg] = self.effectiveAddr(m);
                return;
            },
            0x8F => {
                // pop rm
                const m = try self.decodeModRm(rex);
                const value = try self.pop();
                try self.writeRm(m, sz, value);
                return;
            },
            0x90...0x97 => {
                // xchg rax, reg
                const index: usize = @as(usize, opcode & 7) | (if ((rex & 0x01) != 0) @as(usize, 8) else 0);
                const temp = self.regs[RAX];
                self.regs[RAX] = self.regs[index];
                self.regs[index] = temp;
                return;
            },
            0x98 => {
                // cbw / cwde / cdqe
                if (sz == 8) {
                    const v = @as(i32, @bitCast(@as(u32, @truncate(self.regs[RAX]))));
                    self.regs[RAX] = @as(u64, @bitCast(@as(i64, v)));
                } else {
                    self.regs[RAX] = @as(u64, @as(u16, @truncate(self.regs[RAX])));
                }
                return;
            },
            0x99 => {
                // cwd / cdq / cqo
                if (sz == 8) {
                    const sign: i64 = @bitCast(self.regs[RAX]);
                    self.regs[RDX] = if (sign < 0) ~@as(u64, 0) else 0;
                } else {
                    const sign: i32 = @bitCast(@as(u32, @truncate(self.regs[RAX])));
                    self.regs[RDX] = if (sign < 0) 0xFFFF_FFFF else 0;
                }
                return;
            },
            0x9C => {
                // pushf
                return self.push(self.rflags | 0x2);
            },
            0x9D => {
                // popf
                self.rflags = (try self.pop()) | 0x2;
                return;
            },
            0xA8 => {
                const imm = try self.fetchImm(1);
                self.setLogicFlags(self.regs[RAX] & imm, 1);
                return;
            },
            0xA9 => {
                const imm = try self.fetchImm(sz);
                self.setLogicFlags(self.regs[RAX] & imm, sz);
                return;
            },
            0xB0...0xB7 => {
                // mov r8, imm8
                const index: usize = @as(usize, opcode & 7) | (if ((rex & 0x01) != 0) @as(usize, 8) else 0);
                self.regs[index] = try self.fetchImm(1);
                return;
            },
            0xB8...0xBF => {
                // mov reg, imm
                //
                // The immediate follows the *operand* size: `movw $imm16, %dx`
                // carries a two-byte immediate, and reading four desynchronises
                // the instruction stream - which looks like the guest jumping
                // off into nowhere a few instructions later.
                const index: usize = @as(usize, opcode & 7) | (if ((rex & 0x01) != 0) @as(usize, 8) else 0);
                const imm = if (sz == 8)
                    try self.fetchImm(8)
                else if (sz == 2)
                    try self.fetchImm(2)
                else
                    try self.fetchImm(4);
                self.regs[index] = if (sz == 8) imm else (imm & maskFor(sz));
                return;
            },
            0xC0, 0xC1, 0xD0, 0xD1, 0xD2, 0xD3 => {
                // The shift group.
                const m = try self.decodeModRm(rex);
                const width: u8 = if (opcode == 0xC0 or opcode == 0xD0 or opcode == 0xD2) 1 else sz;
                const count: u8 = switch (opcode) {
                    0xC0, 0xC1 => @intCast(try self.fetchImm(1)),
                    0xD0, 0xD1 => 1,
                    else => blk: {
                        const v = @as(u8, @truncate(self.regs[RCX]));
                        break :blk if (v > 63) 64 else v;
                    },
                };
                const value = try self.readRm(m, width);
                const shifted = self.shift(m.reg & 7, value, count, width);
                try self.writeRm(m, width, shifted);
                return;
            },
            0xC2 => {
                const imm = try self.fetchImm(2);
                const target = try self.pop();
                self.rip = target;
                self.regs[RSP] +%= imm;
                return;
            },
            0xC3 => {
                self.rip = try self.pop();
                return;
            },
            0xC6 => {
                // mov rm8, imm8
                const m = try self.decodeModRm(rex);
                const imm = try self.fetchImm(1);
                try self.writeRm(m, 1, imm);
                return;
            },
            0xC7 => {
                // mov rm, imm
                const m = try self.decodeModRm(rex);
                const imm = try self.fetchImm(sz);
                try self.writeRm(m, sz, imm);
                return;
            },
            0xC9 => {
                // leave: mov rsp, rbp; pop rbp
                self.regs[RSP] = self.regs[RBP];
                self.regs[RBP] = try self.pop();
                return;
            },
            0xE4 => {
                // in al, imm8
                const port: u16 = @truncate(try self.fetchImm(1));
                self.regs[RAX] = (self.regs[RAX] & ~@as(u64, 0xFF)) | @as(u64, self.portIn(port));
                return;
            },
            0xE5 => {
                // in eax, imm8
                const port: u16 = @truncate(try self.fetchImm(1));
                self.regs[RAX] = self.portIn32(port);
                return;
            },
            0xE6 => {
                // out imm8, al
                const port: u16 = @truncate(try self.fetchImm(1));
                self.portOut(port, @truncate(self.regs[RAX]));
                return;
            },
            0xE7 => {
                // out imm8, eax
                const port: u16 = @truncate(try self.fetchImm(1));
                self.portOut32(port, @truncate(self.regs[RAX]));
                return;
            },
            0xE8 => {
                // call rel32
                const disp = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
                const target = self.rip +% @as(u64, @bitCast(@as(i64, disp)));
                try self.push(self.rip);
                self.rip = target;
                return;
            },
            0xE9 => {
                // jmp rel32
                const disp = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
                self.rip +%= @as(u64, @bitCast(@as(i64, disp)));
                return;
            },
            0xEB => {
                // jmp rel8
                const disp = @as(i8, @bitCast(@as(u8, @truncate(try self.fetchImm(1)))));
                self.rip +%= @as(u64, @bitCast(@as(i64, disp)));
                return;
            },
            0xEC => {
                // in al, dx
                //
                // The value goes into AL and the rest of RAX is left alone.
                // Putting it anywhere else - a guest that polls a status
                // register then tests a *different* bit spins forever.
                const port: u16 = @truncate(self.regs[RDX]);
                self.regs[RAX] = (self.regs[RAX] & ~@as(u64, 0xFF)) | @as(u64, self.portIn(port));
                return;
            },
            0xED => {
                // in eax, dx
                const port: u16 = @truncate(self.regs[RDX]);
                self.regs[RAX] = self.portIn32(port);
                return;
            },
            0xEE => {
                // out dx, al
                const port: u16 = @truncate(self.regs[RDX]);
                self.portOut(port, @truncate(self.regs[RAX]));
                return;
            },
            0xEF => {
                // out dx, eax
                const port: u16 = @truncate(self.regs[RDX]);
                self.portOut32(port, @truncate(self.regs[RAX]));
                return;
            },
            0xF4 => {
                // hlt
                self.halted = true;
                return error.Halted;
            },
            0xF5 => {
                // cmc
                self.setFlag(FLAG_CF, !self.flag(FLAG_CF));
                return;
            },
            0xF6, 0xF7 => {
                // The group-3 opcodes.  Only `test`, `not` and `neg` are
                // implemented; the rest trap rather than guess.
                const m = try self.decodeModRm(rex);
                const width: u8 = if (opcode == 0xF6) 1 else sz;
                switch (m.reg & 7) {
                    0 => {
                        const imm = if (opcode == 0xF6) try self.fetchImm(1) else try self.fetchImm(width);
                        const value = try self.readRm(m, width);
                        self.setLogicFlags(value & imm, width);
                        return;
                    },
                    2 => {
                        const value = try self.readRm(m, width);
                        try self.writeRm(m, width, ~value & maskFor(width));
                        return;
                    },
                    3 => {
                        const value = try self.readRm(m, width);
                        const result = 0 -% value;
                        self.setSubFlags(0, value, 0, result, width);
                        try self.writeRm(m, width, result);
                        return;
                    },
                    else => return error.Unsupported,
                }
            },
            0xF8 => {
                self.setFlag(FLAG_CF, false);
                return;
            },
            0xF9 => {
                self.setFlag(FLAG_CF, true);
                return;
            },
            0xFA => {
                self.setFlag(FLAG_IF, false);
                return;
            },
            0xFB => {
                self.setFlag(FLAG_IF, true);
                return;
            },
            0xFC => {
                self.setFlag(FLAG_DF, false);
                return;
            },
            0xFD => {
                self.setFlag(FLAG_DF, true);
                return;
            },
            0xFE => {
                // inc rm8 / dec rm8
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, 1);
                const result: u64 = if ((m.reg & 7) == 0) value +% 1 else value -% 1;
                if ((m.reg & 7) == 0) {
                    self.setAddFlags(value, 1, 0, result, 1);
                } else {
                    self.setSubFlags(value, 1, 0, result, 1);
                }
                try self.writeRm(m, 1, result);
                return;
            },
            0xFF => {
                const m = try self.decodeModRm(rex);
                switch (m.reg & 7) {
                    0 => {
                        // inc rm
                        const value = try self.readRm(m, sz);
                        const result = value +% 1;
                        self.setAddFlags(value, 1, 0, result, sz);
                        try self.writeRm(m, sz, result);
                        return;
                    },
                    1 => {
                        // dec rm
                        const value = try self.readRm(m, sz);
                        const result = value -% 1;
                        self.setSubFlags(value, 1, 0, result, sz);
                        try self.writeRm(m, sz, result);
                        return;
                    },
                    2 => {
                        // call rm
                        const target = try self.readRm(m, sz);
                        try self.push(self.rip);
                        self.rip = target;
                        return;
                    },
                    4 => {
                        // jmp rm
                        const target = try self.readRm(m, sz);
                        self.rip = target;
                        return;
                    },
                    6 => {
                        // push rm
                        const value = try self.readRm(m, sz);
                        return self.push(value);
                    },
                    else => return error.Unsupported,
                }
            },
            else => return error.UnknownInstruction,
        }
    }

    /// The eight arithmetic and logic groups, in their six forms.
    ///
    /// The groups are add, or, adc, sbb, and, sub, xor and cmp.  `cmp` is
    /// `sub` that throws the result away - the flags are the point.
    ///
    /// **Every group lays its forms out the same way**, and the layout is
    /// the one that catches people out:
    ///
    ///     /0  r/m8, r8        /1  r/m, r
    ///     /2  r/m8, imm8     /3  r/m, imm
    ///     /4  AL, imm8       /5  eAX, imm
    ///
    /// The obvious reading - "the odd forms take an immediate" - is wrong:
    /// /1 is the register form and /2 is the *byte* immediate form.  Reading
    /// them the other way eats a byte that is not an immediate, which
    /// desynchronises the instruction stream - and that looks like the guest
    /// jumping off into nowhere a few instructions later, with no hint of
    /// what went wrong.
    ///
    /// **`cmp` is `sub` without the store.**  Group 7 computes the flags and
    /// leaves the operand alone; writing the difference back looks harmless
    /// but silently corrupts the guest's registers (`cmp $32, %r13d` turning
    /// the loop counter into -32), which the guest then uses as an address.
    fn executeGroup(self: *Cpu, group: u8, form: u8, rex: u8, sz: u8) Trap!void {
        // `cmp` throws the result away; every other group stores it.
        const stores = group != 7;
        switch (form) {
            0 => {
                // r/m8, r8
                const m = try self.decodeModRm(rex);
                const a = try self.readRm(m, 1);
                const b = self.regs[m.reg];
                const result = try self.groupOp(group, a, b, 1);
                if (stores) try self.writeRm(m, 1, result);
                return;
            },
            1 => {
                // r/m, r
                const m = try self.decodeModRm(rex);
                const a = try self.readRm(m, sz);
                const b = self.regs[m.reg];
                const result = try self.groupOp(group, a, b, sz);
                if (stores) try self.writeRm(m, sz, result);
                return;
            },
            2 => {
                // r/m8, imm8
                const m = try self.decodeModRm(rex);
                const imm = try self.fetchImm(1);
                const a = try self.readRm(m, 1);
                const result = try self.groupOp(group, a, imm, 1);
                if (stores) try self.writeRm(m, 1, result);
                return;
            },
            3 => {
                // r/m, imm
                const m = try self.decodeModRm(rex);
                const imm = try self.fetchImm(sz);
                const a = try self.readRm(m, sz);
                const result = try self.groupOp(group, a, imm, sz);
                if (stores) try self.writeRm(m, sz, result);
                return;
            },
            4 => {
                // AL, imm8
                const imm = try self.fetchImm(1);
                const result = try self.groupOp(group, self.regs[RAX] & 0xFF, imm, 1);
                if (stores) self.regs[RAX] = (self.regs[RAX] & ~@as(u64, 0xFF)) | (result & 0xFF);
                return;
            },
            5 => {
                // eAX, imm
                const imm = try self.fetchImm(sz);
                const result = try self.groupOp(group, self.regs[RAX], imm, sz);
                if (stores) self.regs[RAX] = result;
                return;
            },
            else => return error.Unsupported,
        }
    }

    /// One operation of the arithmetic and logic groups.
    fn groupOp(self: *Cpu, group: u8, a: u64, b: u64, size: u8) Trap!u64 {
        switch (group) {
            0 => { // add
                const result = a +% b;
                self.setAddFlags(a, b, 0, result, size);
                return result;
            },
            1 => { // or
                const result = a | b;
                self.setLogicFlags(result, size);
                return result;
            },
            2 => { // adc
                const carry: u64 = if (self.flag(FLAG_CF)) 1 else 0;
                const result = a +% b +% carry;
                self.setAddFlags(a, b, carry, result, size);
                return result;
            },
            3 => { // sbb
                const borrow: u64 = if (self.flag(FLAG_CF)) 1 else 0;
                const result = a -% b -% borrow;
                self.setSubFlags(a, b, borrow, result, size);
                return result;
            },
            4 => { // and
                const result = a & b;
                self.setLogicFlags(result, size);
                return result;
            },
            5 => { // sub
                const result = a -% b;
                self.setSubFlags(a, b, 0, result, size);
                return result;
            },
            6 => { // xor
                const result = a ^ b;
                self.setLogicFlags(result, size);
                return result;
            },
            7 => { // cmp
                const result = a -% b;
                self.setSubFlags(a, b, 0, result, size);
                return result;
            },
            else => return error.Unsupported,
        }
    }

    /// The two-byte (0x0F) opcodes.
    fn execute0F(self: *Cpu, op2: u8, rex: u8, operand_size: u8, prefix: u8) Trap!void {
        const sz = operand_size;
        switch (op2) {
            0x0B => return error.UnknownInstruction, // ud2
            0x31 => {
                // rdtsc
                const now = @import("../drivers/timer.zig").tickCount();
                self.regs[RAX] = now;
                self.regs[RDX] = now >> 32;
                return;
            },
            0xA2 => return self.cpuid(),
            0x80...0x8F => {
                // jcc rel32
                const cc: u8 = op2 & 0x0F;
                const disp = @as(i32, @bitCast(@as(u32, @truncate(try self.fetchImm(4)))));
                if (self.condition(cc)) {
                    self.rip +%= @as(u64, @bitCast(@as(i64, disp)));
                }
                return;
            },
            0xAF => {
                // imul r, rm
                const m = try self.decodeModRm(rex);
                const a = @as(i64, @bitCast(self.regs[m.reg]));
                const b = @as(i64, @bitCast(try self.readRm(m, sz)));
                const product: i64 = a *% b;
                self.setAddFlags(@bitCast(a), @bitCast(b), 0, @bitCast(product), sz);
                self.regs[m.reg] = @bitCast(product);
                return;
            },
            0xB6 => {
                // movzx r, rm8
                const m = try self.decodeModRm(rex);
                self.regs[m.reg] = try self.readRm(m, 1);
                return;
            },
            0xB7 => {
                // movzx r, rm16
                const m = try self.decodeModRm(rex);
                self.regs[m.reg] = try self.readRm(m, 2);
                return;
            },
            0xBE => {
                // movsx r, rm8
                const m = try self.decodeModRm(rex);
                const value = @as(i8, @bitCast(@as(u8, @truncate(try self.readRm(m, 1)))));
                self.regs[m.reg] = @as(u64, @bitCast(@as(i64, value)));
                return;
            },
            0xBF => {
                // movsx r, rm16
                const m = try self.decodeModRm(rex);
                const value = @as(i16, @bitCast(@as(u16, @truncate(try self.readRm(m, 2)))));
                self.regs[m.reg] = @as(u64, @bitCast(@as(i64, value)));
                return;
            },
            0xB0 => {
                // cmpxchg r/m8, reg
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, 1);
                const reg = self.regs[RAX];
                if (value == reg) {
                    self.setFlag(FLAG_ZF, true);
                    try self.writeRm(m, 1, self.regs[m.reg]);
                } else {
                    self.setFlag(FLAG_ZF, false);
                    self.regs[RAX] = value;
                }
                return;
            },
            0xC0 => {
                // xadd r/m8, reg
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, 1);
                const reg = self.regs[m.reg];
                const result = value +% reg;
                self.setAddFlags(value, reg, 0, result, 1);
                try self.writeRm(m, 1, reg);
                self.regs[m.reg] = result;
                return;
            },
            0xC1 => {
                // xadd r/m, reg
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, sz);
                const reg = self.regs[m.reg];
                const result = value +% reg;
                self.setAddFlags(value, reg, 0, result, sz);
                try self.writeRm(m, sz, reg);
                self.regs[m.reg] = result;
                return;
            },
            0xC7 => {
                // cmpxchg r/m, reg
                const m = try self.decodeModRm(rex);
                const value = try self.readRm(m, sz);
                if (value == self.regs[RAX]) {
                    self.setFlag(FLAG_ZF, true);
                    try self.writeRm(m, sz, self.regs[m.reg]);
                } else {
                    self.setFlag(FLAG_ZF, false);
                    self.regs[RAX] = value;
                }
                return;
            },
            0xA3, 0xAB, 0xB3, 0xBB => {
                // bt / bts / btr / btc
                const m = try self.decodeModRm(rex);
                const bit: u6 = @intCast(self.regs[m.reg] & 0x3F);
                const value = try self.readRm(m, sz);
                const mask = @as(u64, 1) << bit;
                self.setFlag(FLAG_CF, (value & mask) != 0);
                var result = value;
                switch (op2) {
                    0xAB => result |= mask, // bts
                    0xB3 => result &= ~mask, // btr
                    0xBB => result ^= mask, // btc
                    else => {}, // bt
                }
                try self.writeRm(m, sz, result);
                return;
            },
            else => {
                _ = prefix;
                return error.UnknownInstruction;
            },
        }
    }

    /// cpuid, with the leaves the hypervisor's identity describes.
    fn cpuid(self: *Cpu) Trap!void {
        const leaf = self.regs[RAX];
        const identity = self.identity;

        switch (leaf) {
            0 => {
                // The highest leaf and the vendor string.
                self.regs[RAX] = identity.max_leaf;
                self.regs[RBX] = 0x756E6547; // "Genu"
                self.regs[RDX] = 0x49656E69; // "ineI"
                self.regs[RCX] = 0x6C65746E; // "ntel"
            },
            1 => {
                self.regs[RAX] = (identity.family << 8) | (identity.model << 4) | identity.stepping;
                self.regs[RBX] = 0;
                self.regs[RCX] = identity.feature_ecx;
                self.regs[RDX] = identity.feature_edx;
            },
            0x80000000 => {
                self.regs[RAX] = identity.max_extended_leaf;
                self.regs[RBX] = 0x68747541; // "Auth"
                self.regs[RDX] = 0x69746E65; // "enti"
                self.regs[RCX] = 0x63416D65; // "eAmc"
            },
            0x80000002...0x80000004 => {
                // The CPU brand string, sixteen bytes at a time.
                const brand = identity.cpuBrand();
                var buf: [16]u8 = undefined;
                const offset = (leaf - 0x80000002) * 16;
                for (&buf, 0..) |*b, i| {
                    b.* = if (offset + i < brand.len) brand[offset + i] else 0;
                }
                self.regs[RAX] = @as(u64, buf[0]) |
                    (@as(u64, buf[1]) << 8) |
                    (@as(u64, buf[2]) << 16) |
                    (@as(u64, buf[3]) << 24) |
                    (@as(u64, buf[4]) << 32) |
                    (@as(u64, buf[5]) << 40) |
                    (@as(u64, buf[6]) << 48) |
                    (@as(u64, buf[7]) << 56);
                self.regs[RBX] = @as(u64, buf[8]) |
                    (@as(u64, buf[9]) << 8) |
                    (@as(u64, buf[10]) << 16) |
                    (@as(u64, buf[11]) << 24) |
                    (@as(u64, buf[12]) << 32) |
                    (@as(u64, buf[13]) << 40) |
                    (@as(u64, buf[14]) << 48) |
                    (@as(u64, buf[15]) << 56);
                self.regs[RCX] = 0;
                self.regs[RDX] = 0;
            },
            else => {
                self.regs[RAX] = 0;
                self.regs[RBX] = 0;
                self.regs[RCX] = 0;
                self.regs[RDX] = 0;
            },
        }
        return;
    }

    /// The shift group: rol, ror, rcl, rcr, shl, shr, sal, sar.
    fn shift(self: *Cpu, op: u8, value: u64, count: u8, size: u8) u64 {
        const m = maskFor(size);
        var v = value & m;
        const bits = size * 8;
        if (count == 0 or count > 63) return v;

        switch (op) {
            4, 6 => {
                // shl / sal
                const n = count;
                if (n >= bits) {
                    self.setFlag(FLAG_CF, false);
                    v = 0;
                } else {
                    self.setFlag(FLAG_CF, (v & (@as(u64, 1) << @intCast(bits - n))) != 0);
                    v = (v << @intCast(n)) & m;
                }
            },
            5 => {
                // shr
                const n = count;
                if (n >= bits) {
                    self.setFlag(FLAG_CF, (v & 1) != 0);
                    v = 0;
                } else {
                    self.setFlag(FLAG_CF, (v & (@as(u64, 1) << @intCast(n - 1))) != 0);
                    v = (v & m) >> @intCast(n);
                }
            },
            7 => {
                // sar
                const n = count;
                const sign = signBit(size);
                const negative = (v & sign) != 0;
                if (n >= bits) {
                    self.setFlag(FLAG_CF, negative);
                    v = if (negative) sign else 0;
                } else {
                    self.setFlag(FLAG_CF, (v & (@as(u64, 1) << @intCast(n - 1))) != 0);
                    var shifted = (v & m) >> @intCast(n);
                    if (negative) {
                        shifted |= (~@as(u64, 0)) << @intCast(bits - n);
                    }
                    v = shifted & m;
                }
            },
            0 => {
                // rol
                var n: u8 = count % bits;
                if (n == 0) n = bits;
                v = ((v << @intCast(n)) | (v >> @intCast(bits - n))) & m;
            },
            1 => {
                // ror
                var n: u8 = count % bits;
                if (n == 0) n = bits;
                v = ((v >> @intCast(n)) | (v << @intCast(bits - n))) & m;
            },
            else => {},
        }
        return v;
    }

    // ─── The stack ────────────────────────────────────────────────

    fn push(self: *Cpu, value: u64) Trap!void {
        self.regs[RSP] -%= 8;
        try self.write(self.regs[RSP], 8, value);
    }

    fn pop(self: *Cpu) Trap!u64 {
        const value = try self.read(self.regs[RSP], 8);
        self.regs[RSP] +%= 8;
        return value;
    }

    // ─── Port I/O ─────────────────────────────────────────────────

    /// A port the guest wants to read.
    fn portIn(self: *Cpu, port: u16) u8 {
        if (port >= uart_mod.COM1 and port < uart_mod.COM1 + 8) {
            return self.uart.read(port);
        }
        // The PCI configuration space: the address register and the data
        // port.  This is how a guest finds its devices.
        if (self.pci) |bus| {
            if (port >= pci_mod.CONFIG_ADDRESS and port < pci_mod.CONFIG_ADDRESS + 4) {
                return bus.portIn(port);
            }
            if (port >= pci_mod.CONFIG_DATA and port < pci_mod.CONFIG_DATA + 4) {
                return bus.portIn(port);
            }
        }
        // A port the guest has no business touching.  Reading the host's
        // hardware on the guest's behalf would let a guest read the host's
        // devices, so it gets zeroes.
        return 0;
    }

    /// A dword the guest wants to read.
    ///
    /// The PCI configuration data port is a dword, and a guest that reads it
    /// with `in eax, dx` expects all four bytes at once.
    fn portIn32(self: *Cpu, port: u16) u32 {
        var value: u32 = 0;
        var i: u5 = 0;
        while (i < 4) : (i += 1) {
            value |= @as(u32, self.portIn(port + i)) << @intCast(i * 8);
        }
        return value;
    }

    /// A dword the guest wants to write.
    fn portOut32(self: *Cpu, port: u16, value: u32) void {
        var i: u5 = 0;
        while (i < 4) : (i += 1) {
            self.portOut(port + i, @truncate(value >> @intCast(i * 8)));
        }
    }

    /// A port the guest wants to write.
    fn portOut(self: *Cpu, port: u16, value: u8) void {
        if (port >= uart_mod.COM1 and port < uart_mod.COM1 + 8) {
            self.uart.write(port, value);
            return;
        }
        if (self.pci) |bus| {
            if (port >= pci_mod.CONFIG_ADDRESS and port < pci_mod.CONFIG_ADDRESS + 4) {
                bus.portOut(port, value);
                return;
            }
            if (port >= pci_mod.CONFIG_DATA and port < pci_mod.CONFIG_DATA + 4) {
                bus.portOut(port, value);
                return;
            }
        }
        // Everything else is dropped: the guest's writes must not reach the
        // host's hardware.
    }
};

/// The parity flag: one when the low byte has an even number of set bits.
fn parity(value: u64) bool {
    var v = value & 0xFF;
    var count: u32 = 0;
    while (v != 0) : (v &= v - 1) {
        count += 1;
    }
    return (count & 1) == 0;
}
