//! The time stamp counter and the short delays built on it.
//!
//! The kernel's tick is 10 ms - far too coarse for the AP bring-up sequence,
//! which needs a 200 us gap between two SIPIs.  The TSC is a free-running
//! counter with (usually) nanosecond resolution, so a calibrated frequency
//! turns it into a precise busy-wait delay.
//!
//! The frequency is calibrated against the LAPIC timer, which `drivers/apic`
//! has already calibrated against the PIT - no extra hardware work, no second
//! time reference.

/// The calibrated TSC frequency in Hz.  Zero means "not calibrated yet".
pub var frequency: u64 = 0;

/// Read the time stamp counter.
///
/// The counter is not serialised against the loads around it, which does not
/// matter for a delay: we only ever measure a difference.
pub inline fn read() u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .memory = true }
    );
    return (@as(u64, hi) << 32) | lo;
}

/// Set the frequency the delay calculations assume.
pub fn setFrequency(hz: u64) void {
    frequency = hz;
}

/// Busy-wait for `us` microseconds.
///
/// Interrupts stay enabled: this runs before the scheduler exists and must
/// not disturb the interrupt state of its caller.
pub fn delayUs(us: u32) void {
    if (us == 0) return;

    if (frequency == 0) {
        // Not calibrated: a plain spin is the best we can do.  The count is
        // arbitrary but roughly proportional to a microsecond on any CPU we
        // care about, and it is only used before the calibration has run.
        var spins: u64 = 0;
        const limit: u64 = @as(u64, us) * 1000;
        while (spins < limit) : (spins += 1) {
            asm volatile ("pause" ::: .{ .memory = true });
        }
        return;
    }

    const cycles = frequency / 1_000_000 * us;
    const start = read();
    while (read() -% start < cycles) {
        asm volatile ("pause" ::: .{ .memory = true });
    }
}
