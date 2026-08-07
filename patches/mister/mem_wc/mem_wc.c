// SPDX-License-Identifier: GPL-2.0
/*
 * mem_wc - a write-combining "/dev/mem".
 *
 * VENDORED, essentially unmodified, from skmp/minicast (mem_wc/mem_wc.c),
 * where it exists to give DreamSTer's Dreamcast VRAM window a write-combining
 * mapping. The analysis of why this project wants the same thing is in
 * docs/dreamster-ddr-channel-review.md; the short version:
 *
 *   ARM's phys_mem_access_prot() (arch/arm/mm/mmu.c) hands a /dev/mem mmap
 *   pgprot_noncached() -- L_PTE_MT_UNCACHED, Strongly-Ordered -- whenever
 *   pfn_valid(pfn) is false, and only reaches the O_SYNC test that would give
 *   pgprot_writecombine() when it is true. 0x3A000000 is in the 512 MB the
 *   DE10-Nano hands to the fabric, outside the kernel's memblock, so it always
 *   takes the first branch. Strongly-Ordered stores cannot merge: a 512x384
 *   RGB565 frame crosses at 89.5 MB/s (4.19 ms) against 540.5 MB/s cached.
 *
 * This driver never asks pfn_valid(). It sets pgprot_writecombine()
 * unconditionally -- L_PTE_MT_BUFFERABLE, Normal Non-Cacheable, which lets the
 * write buffer merge stores into full bursts -- and calls remap_pfn_range().
 *
 * Usage from userspace is identical to /dev/mem:
 *
 *     int fd = open("/dev/mem_wc", O_RDWR);
 *     void *p = mmap(NULL, len, PROT_READ|PROT_WRITE, MAP_SHARED, fd, phys_base);
 *
 * The physical base is taken from the mmap offset (vm_pgoff), so nothing is
 * hardcoded here - the caller decides which region and how much, exactly as
 * with /dev/mem.
 *
 * Write-combining posts and coalesces stores; ordering vs. other bus masters
 * (e.g. an FPGA reading the same DDR) is NOT implied. The userspace writer is
 * responsible for a barrier (dsb) before signalling the other master that data
 * is ready. nv_present.c's NV_FENCE() is that barrier for this project.
 *
 * Like /dev/mem this can map any physical address, so it is root-only by the
 * device node's permissions. Load with a restricted range if you want it
 * locked down (see phys_base / phys_size module params); games/MAMESTer/
 * _handler.sh loads it restricted to this core's own 4 MB window.
 */

#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/fs.h>
#include <linux/mm.h>
#include <linux/io.h>
#include <linux/uaccess.h>

#define DEVICE_NAME "mem_wc"

/*
 * Optional allowlist. If phys_size is non-zero, only [phys_base, phys_base+size)
 * may be mapped; any other offset/length is rejected. Left at 0 (default) the
 * device behaves like a fully-open write-combining /dev/mem.
 *
 *   insmod mem_wc.ko phys_base=0x3A000000 phys_size=0x00400000
 */
static unsigned long phys_base;
static unsigned long phys_size;
module_param(phys_base, ulong, 0444);
MODULE_PARM_DESC(phys_base, "if phys_size!=0, lowest physical address that may be mapped");
module_param(phys_size, ulong, 0444);
MODULE_PARM_DESC(phys_size, "if !=0, size of the single allowed physical window (bytes)");

static int mem_wc_mmap(struct file *file, struct vm_area_struct *vma)
{
	size_t size = vma->vm_end - vma->vm_start;
	phys_addr_t offset = (phys_addr_t)vma->vm_pgoff << PAGE_SHIFT;

	/* Disallow a mapping that wraps the physical address space. */
	if (offset + size < offset)
		return -EINVAL;

	/* Enforce the allowlist window, if one was configured. */
	if (phys_size) {
		if (offset < phys_base ||
		    offset + size > (phys_addr_t)phys_base + phys_size)
			return -EPERM;
	}

	/*
	 * The whole point of this driver: Normal Non-Cacheable (write-combining)
	 * instead of the Device/Strongly-Ordered attribute a /dev/mem mmap gets.
	 */
	vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);

	if (remap_pfn_range(vma, vma->vm_start, vma->vm_pgoff,
			    size, vma->vm_page_prot))
		return -EAGAIN;

	return 0;
}

static const struct file_operations mem_wc_fops = {
	.owner = THIS_MODULE,
	.mmap  = mem_wc_mmap,
	.llseek = noop_llseek,
};

static struct miscdevice mem_wc_dev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name  = DEVICE_NAME,
	.fops  = &mem_wc_fops,
	.mode  = 0600,   /* root only, like /dev/mem */
};

static int __init mem_wc_init(void)
{
	int ret = misc_register(&mem_wc_dev);

	if (ret) {
		pr_err("mem_wc: misc_register failed: %d\n", ret);
		return ret;
	}

	if (phys_size)
		pr_info("mem_wc: loaded, restricted to [0x%lx, 0x%lx)\n",
			phys_base, phys_base + phys_size);
	else
		pr_info("mem_wc: loaded, unrestricted (write-combining /dev/mem)\n");

	return 0;
}

static void __exit mem_wc_exit(void)
{
	misc_deregister(&mem_wc_dev);
	pr_info("mem_wc: unloaded\n");
}

module_init(mem_wc_init);
module_exit(mem_wc_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("dc-fpga");
MODULE_DESCRIPTION("Write-combining /dev/mem for FPGA-shared DDR");
