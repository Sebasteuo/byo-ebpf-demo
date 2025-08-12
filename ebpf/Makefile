# Makefile — eBPF CO-RE en arm64
CLANG = clang

ARCH  := $(shell uname -m | sed 's/aarch64/arm64/')

CFLAGS = -O2 -g -target bpf \
         -I/usr/include/bpf \
         -I/usr/include/aarch64-linux-gnu \
         -I$(PWD) \
         -D__TARGET_ARCH_$(ARCH)

all: redact_vfs_write.bpf.o

redact_vfs_write.bpf.o: redact_vfs_write.bpf.c vmlinux.h
	$(CLANG) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o

