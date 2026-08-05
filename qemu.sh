qemu-system-x86_64 \
    -cdrom kernel.iso \
    -m 128M \
    -device e1000,netdev=net0 \
    -netdev user,id=net0,hostfwd=tcp::8080-:80 \
    -display gtk \
    -serial stdio \
    -d int,cpu_reset \
    -D qemu.log \
    -no-reboot