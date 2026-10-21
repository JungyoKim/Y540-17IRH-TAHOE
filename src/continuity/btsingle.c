// btsingle.c -- force bluetoothd LeBroadcaster::stackDidStart to take the single-instance (legacy) advertising path
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static const unsigned char want[] = {0x31,0xd2,0xf7,0x83,0x90,0,0,0,0xfd,0xff,0xff,0xff,0x0f,0x94,0xc2};
__attribute__((constructor)) static void init(void) {
  FILE *L = fopen("/tmp/btsingle.log", "a");
  intptr_t slide = -1; uint32_t i, n = _dyld_image_count();
  for (i = 0; i < n; i++) { const struct mach_header *h = _dyld_get_image_header(i); if (h && h->filetype == MH_EXECUTE) { slide = (intptr_t)h - 0x100000000; break; } }
  if (slide == -1 || slide < 0) { if (L) { fprintf(L, "pid %d: no exe image\n", getpid()); fclose(L); } return; }
  unsigned char *p = (unsigned char *)(0x100698438 + slide);
  if (memcmp(p, want, sizeof want) != 0) { if (L) { fprintf(L, "pid %d: bytes mismatch, not patching\n", getpid()); fclose(L); } return; }
  vm_address_t pg = (vm_address_t)p & ~(vm_address_t)0xfff;
  kern_return_t kr = vm_protect(mach_task_self(), pg, 0x2000, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr == KERN_SUCCESS) { p[12] = 0x0f; p[13] = 0x1f; p[14] = 0x00; kr = vm_protect(mach_task_self(), pg, 0x2000, 0, VM_PROT_READ | VM_PROT_EXECUTE); }
  if (L) { fprintf(L, "pid %d: slide 0x%lx patch kr %d now %02x %02x %02x\n", getpid(), (long)slide, kr, p[12], p[13], p[14]); fclose(L); }
}
