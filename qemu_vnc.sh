qemu-system-x86_64 \
    -cdrom kernel.iso \
    -m 128M \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -vnc 0.0.0.0:1 \
    -serial stdio \
    -d int,cpu_reset \
    -D qemu.log \
    -no-reboot
