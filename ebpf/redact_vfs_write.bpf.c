#include "vmlinux.h"            /* BTF-generated, ya contiene structs y tipos */
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>
struct {              /* mapa clave: dev:inode  (64 + 64 → 64 comprimido) */
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 128);
    __type(key, unsigned long long);
    __type(value, __u8);      /* solo necesitamos marcar presencia (1) */
} log_map SEC(".maps");

/* mezcla sencilla dev << 32 ^ inode → clave 64 b */
static __always_inline unsigned long long make_key(dev_t dev,
                                                   unsigned long long ino)
{
    return ((unsigned long long)dev << 32) ^ ino;
}

SEC("kprobe/vfs_write")
int kprobe__vfs_write(struct pt_regs *ctx)
{
    struct file  *file  = (struct file *)PT_REGS_PARM1(ctx);
    struct inode *inode = BPF_CORE_READ(file, f_inode);
    dev_t dev           = BPF_CORE_READ(inode, i_sb, s_dev);
    unsigned long long ino = BPF_CORE_READ(inode, i_ino);

    unsigned long long key = make_key(dev, ino);
    if (!bpf_map_lookup_elem(&log_map, &key))
        return 0;           /* no filtramos → salir rápido */

    char msg[] = "eBPF intercept: protected file write\n";
    bpf_trace_printk(msg, sizeof(msg));
    return 0;
}

char _license[] SEC("license") = "GPL";
