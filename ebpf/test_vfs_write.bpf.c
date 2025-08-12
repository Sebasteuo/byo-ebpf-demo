// SPDX-License-Identifier: GPL-2.0
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

SEC("kprobe/vfs_write")
int kprobe__vfs_write(struct pt_regs *ctx)
{
    char msg[] = "vfs_write hit\n";
    bpf_trace_printk(msg, sizeof(msg));
    return 0;
}
char _license[] SEC("license") = "GPL";
