// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2022, Ivaylo Ivanov <ivo.ivanov.ivanov1@gmail.com>
 * Copyright (c) 2026, Igor Belwon <igor.belwon@mentallysanemainliners.org>
 */

#include <main/boot.h>
#include <string.h>
#ifdef CONFIG_EXYNOS_9810
#include <lib/libfdt/libfdt.h>
#include <lib/debug.h>

static void clean_range(void *start, unsigned long size)
{
	unsigned long ctr, line, address, end = (unsigned long)start + size;
	__asm__ volatile("mrs %0, ctr_el0" : "=r" (ctr));
	line = 4UL << ((ctr >> 16) & 15);
	address = (unsigned long)start & ~(line - 1);
	for (; address < end; address += line)
		__asm__ volatile("dc cvac, %0" : : "r" (address) : "memory");
	__asm__ volatile("dsb sy" : : : "memory");
}
#endif

void arch_load_kernel(void* kernel, void* dt, void* ramdisk)
{
	memcpy((void*)CONFIG_PAYLOAD_ENTRY, kernel, (unsigned long) &kernel_size);
#ifndef CONFIG_RAMDISK_NO_COPY
	__optimized_memcpy((void*)CONFIG_RAMDISK_ENTRY, ramdisk, (unsigned long) &ramdisk_size);
#endif
#ifdef CONFIG_EXYNOS_9810
	unsigned long el, sctlr;
	__asm__ volatile("mrs %0, CurrentEL" : "=r" (el));
	if (el == 8)
		__asm__ volatile("mrs %0, sctlr_el2" : "=r" (sctlr));
	else
		__asm__ volatile("mrs %0, sctlr_el1" : "=r" (sctlr));
	printk(KERN_INFO, "S9P handoff: EL%lu SCTLR=%lx kernel=%lx dt=%lx\n",
	       el >> 2, sctlr, (unsigned long)CONFIG_PAYLOAD_ENTRY, (unsigned long)dt);
	clean_range((void *)CONFIG_PAYLOAD_ENTRY, (unsigned long)&kernel_size);
	clean_range(dt, fdt_totalsize(dt));
#ifndef CONFIG_RAMDISK_NO_COPY
	clean_range((void *)CONFIG_RAMDISK_ENTRY, (unsigned long)&ramdisk_size);
#endif
#endif
	load_kernel_and_jump(dt, 0, 0, 0, (void*)CONFIG_PAYLOAD_ENTRY);
}
