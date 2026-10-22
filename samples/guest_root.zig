//! The root of the sample guest image.
//!
//! The guest itself is `guest_hello.S`: it is written in assembly on purpose,
//! because the interpreter has to implement a specific set of instructions and
//! a hand-written guest is a list of exactly those.  This file exists only so
//! the assembly has a module to be attached to.

extern fn guest_entry() callconv(.c) noreturn;

/// The entry point of the guest, referenced so the linker keeps it.
pub const entry = &guest_entry;
