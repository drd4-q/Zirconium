const std = @import("std");
const root = @import("root");
const serial = root.serial;
const vga = root.vga;
const keyboard = @import("keyboard.zig");
const mouse = @import("mouse.zig");
const usb = @import("usb.zig");

// Unified input subsystem providing transparent access to:
// - USB HID keyboards & mice (wired USB 2.0 / Low-Speed / Full-Speed & 2.4GHz wireless dongles)
// - Legacy PS/2 keyboard (8042 IRQ 1)
// - Legacy PS/2 mouse (8042 IRQ 12)

pub const KEY_UP: u8 = keyboard.KEY_UP;
pub const KEY_DOWN: u8 = keyboard.KEY_DOWN;
pub const KEY_LEFT: u8 = keyboard.KEY_LEFT;
pub const KEY_RIGHT: u8 = keyboard.KEY_RIGHT;
pub const KEY_TAB: u8 = keyboard.KEY_TAB;
pub const KEY_PAGE_UP: u8 = keyboard.KEY_PAGE_UP;
pub const KEY_PAGE_DOWN: u8 = keyboard.KEY_PAGE_DOWN;
pub const KEY_HOME: u8 = keyboard.KEY_HOME;
pub const KEY_END: u8 = keyboard.KEY_END;
pub const KEY_DELETE: u8 = keyboard.KEY_DELETE;
pub const KEY_INSERT: u8 = keyboard.KEY_INSERT;

pub var num_lock: bool = true;
pub var caps_lock: bool = false;
pub var scroll_lock: bool = false;

pub fn init() void {
    keyboard.init();
    mouse.init();
    syncLeds(num_lock, caps_lock, scroll_lock);
}

/// Polls for the next available key event across all input devices (USB HID + PS/2).
/// Non-blocking: returns null if no key is ready.
pub fn pollKey() ?u8 {
    // 1. Always poll USB controllers (non-blocking)
    usb.poll();

    // 2. Check for keys queued by USB HID or PS/2 ring
    return keyboard.pollKey();
}

/// Checks if a key is available to read without consuming it.
pub fn hasKey() bool {
    usb.poll();
    return keyboard.hasKey();
}

/// Blocks until a key is pressed, ensuring CPU halts with interrupts enabled.
pub fn getKey() u8 {
    while (true) {
        if (pollKey()) |k| return k;
        asm volatile ("sti\nhlt");
    }
}

/// Pushes a character or keycode into the unified input buffer.
pub fn pushKey(ch: u8) void {
    keyboard.pushKey(ch);
}

/// Synchronizes keyboard LED indicators (NumLock, CapsLock, ScrollLock)
/// across both USB keyboards and PS/2 keyboards.
pub fn syncLeds(nl: bool, cl: bool, sl: bool) void {
    num_lock = nl;
    caps_lock = cl;
    scroll_lock = sl;

    // 1. Update USB keyboards
    usb.mod.hid_core.setLedsGlobal(nl, cl, sl);

    // 2. Update PS/2 keyboard if present
    keyboard.setLeds(nl, cl, sl);
}

/// Toggle NumLock state and broadcast LED update to all keyboards.
pub fn toggleNumLock() void {
    num_lock = !num_lock;
    syncLeds(num_lock, caps_lock, scroll_lock);
}

/// Toggle CapsLock state and broadcast LED update to all keyboards.
pub fn toggleCapsLock() void {
    caps_lock = !caps_lock;
    syncLeds(num_lock, caps_lock, scroll_lock);
}

/// Toggle ScrollLock state and broadcast LED update to all keyboards.
pub fn toggleScrollLock() void {
    scroll_lock = !scroll_lock;
    syncLeds(num_lock, caps_lock, scroll_lock);
}

/// Unified Mouse State
pub const MouseState = struct {
    x: i32,
    y: i32,
    left: bool,
    right: bool,
    middle: bool,
};

pub fn getMouseState() MouseState {
    return MouseState{
        .x = mouse.mx,
        .y = mouse.my,
        .left = mouse.left_button,
        .right = mouse.right_button,
        .middle = mouse.middle_button,
    };
}
