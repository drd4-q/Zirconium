const std = @import("std");

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.c) ?*anyopaque;
extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) callconv(.c) i32;
extern "kernel32" fn ExitProcess(uExitCode: u32) callconv(.c) noreturn;

pub fn main() void {
    const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5; // -11
    const stdout = GetStdHandle(STD_OUTPUT_HANDLE);
    const msg = "Hello from Windows PE .EXE running in Zirconium!\r\n";
    var written: u32 = 0;
    _ = WriteFile(stdout, msg.ptr, @intCast(msg.len), &written, null);
    ExitProcess(0);
}
