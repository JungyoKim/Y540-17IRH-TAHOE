// btsingle.m -- bluetoothd (macOS 26.7.1 25G241) fixes for a BCM20702 that has one LE advertising instance.
// 1. LeBroadcaster::stackDidStart takes the single-instance (legacy) advertising path instead of Apple
//    multi-advertising (the chip rejects the Apple VSC and the whole advertising stack would stay off).
// 2. A start that fails with status 101 (it crossed a stop of the one shared instance) takes the path bluetoothd
//    already uses for status 0x76: "Resetting advertising internal states" and updateAdvertisement 200 ms later.
// 3. WirelessProximity priority: when the connectable set (NearbyInfo / NearbyAction, which carries the
//    same-account identity and the companion-link request) and a non-connectable set (AirDrop 0x05) are both
//    wanted, only the connectable set goes to the stack. Otherwise the two sessions replace each other on the
//    single slot and the iPhone loses the Mac. Kill switch: /Library/NullMoth/no-btprio (checked on every update).
// 4. LE connections use the legacy LE Create Connection command: the two setters of gEnableExtendedCreateConnectionCommand
//    (V1 and V2) store 0 instead of the platform value, so the BT 4.0 chip is never sent the BT 5 extended command.
//    Kill switch (at launch): /Library/NullMoth/no-btlegacyconn.
// 5. A failed Apple firmware-info probe (BD_VSC_READ_FW_INFO, unknown to this chip) no longer counts as "FW is in UHE Mode.
//    Firmware crashed" (restart reason 654), which restarted the whole Bluetooth stack on every failed LE connection.
//    Kill switch (at launch): /Library/NullMoth/no-btnouhe.
// 6. LE advertising/initiating arbiter on the USB transport: see btarb.c (built into the same dylib).
// Binary patches check the exact original bytes first. Log: /tmp/btsingle.log.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static const unsigned char want1[] = {0x31,0xd2,0xf7,0x83,0x90,0,0,0,0xfd,0xff,0xff,0xff,0x0f,0x94,0xc2};
static const unsigned char want2[] = {0x83,0xfb,0x76,0x0f,0x85,0x3c,0x01,0x00,0x00};
static FILE *L;

static void lg(const char *fmt, ...) {
  if (!L) return;
  struct timeval tv; gettimeofday(&tv, NULL);
  struct tm tm; localtime_r(&tv.tv_sec, &tm);
  fprintf(L, "%02d:%02d:%02d.%03d pid %d: ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000), getpid());
  va_list ap; va_start(ap, fmt); vfprintf(L, fmt, ap); va_end(ap);
  fputc('\n', L); fflush(L);
}

static kern_return_t poke(unsigned char *p, const unsigned char *b, size_t n) {
  vm_address_t pg = (vm_address_t)p & ~(vm_address_t)0xfff;
  kern_return_t kr = vm_protect(mach_task_self(), pg, 0x2000, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (kr != KERN_SUCCESS) return kr;
  memcpy(p, b, n);
  return vm_protect(mach_task_self(), pg, 0x2000, 0, VM_PROT_READ | VM_PROT_EXECUTE);
}

// a free page within +-2 GB of the executable: try fixed addresses above the image end, 1 MB apart
static mach_vm_address_t near_page(const struct mach_header_64 *h) {
  uintptr_t end = 0; const struct load_command *lc = (const struct load_command *)(h + 1);
  for (uint32_t i = 0; i < h->ncmds; i++, lc = (const struct load_command *)((const char *)lc + lc->cmdsize))
    if (lc->cmd == LC_SEGMENT_64) { const struct segment_command_64 *sg = (const void *)lc;
      if (strcmp(sg->segname, "__PAGEZERO") && sg->vmaddr + sg->vmsize > end) end = sg->vmaddr + sg->vmsize; }
  intptr_t slide = (intptr_t)h - 0x100000000;
  uintptr_t base = (end + slide + 0xfff) & ~(uintptr_t)0xfff;
  for (uintptr_t off = 0x100000; off < 0x40000000; off += 0x100000) {
    mach_vm_address_t a = base + off;
    if (mach_vm_allocate(mach_task_self(), &a, 0x1000, VM_FLAGS_FIXED) == KERN_SUCCESS) return a;
  }
  return 0;
}

static void patch_binary(void) {
  intptr_t slide = -1; uint32_t i, n = _dyld_image_count();
  for (i = 0; i < n; i++) { const struct mach_header *h = _dyld_get_image_header(i); if (h && h->filetype == MH_EXECUTE) { slide = (intptr_t)h - 0x100000000; break; } }
  if (slide == -1 || slide < 0) { lg("no exe image"); return; }
  unsigned char *p = (unsigned char *)(0x100698438 + slide);
  if (memcmp(p, want1, sizeof want1) != 0) { lg("single: bytes mismatch, not patching"); return; }
  static const unsigned char nop3[] = {0x0f, 0x1f, 0x00};
  kern_return_t kr = poke(p + 12, nop3, 3);
  lg("single: slide 0x%lx patch kr %d now %02x %02x %02x", (long)slide, kr, p[12], p[13], p[14]);
  unsigned char *q = (unsigned char *)(0x10069b09b + slide);
  if (memcmp(q, want2, sizeof want2) != 0) { lg("retry101: bytes mismatch, not patching"); return; }
  mach_vm_address_t t = near_page((const struct mach_header_64 *)(0x100000000 + slide));
  if (!t) { lg("retry101: no page near the image"); return; }
  uint64_t retry = 0x10069b0a4 + slide, giveup = 0x10069b1e0 + slide;
  // cmp ebx,0x65 ; jne giveup ; jmp retry   (ebx holds the start status)
  unsigned char tr[33] = {0x83,0xfb,0x65, 0x75,0x0e, 0xff,0x25,0,0,0,0, 0,0,0,0,0,0,0,0, 0xff,0x25,0,0,0,0, 0,0,0,0,0,0,0,0};
  memcpy(tr + 11, &retry, 8); memcpy(tr + 25, &giveup, 8);
  memcpy((void *)t, tr, sizeof tr);
  kr = mach_vm_protect(mach_task_self(), t, 0x1000, 0, VM_PROT_READ | VM_PROT_EXECUTE);
  int64_t rel = (int64_t)t - (int64_t)(q + 9);
  if (kr != KERN_SUCCESS || rel > 0x7fffffffLL || rel < -0x80000000LL) { lg("retry101: kr %d rel %lld, not patching", kr, (long long)rel); return; }
  int32_t r32 = (int32_t)rel;
  unsigned char jne[6] = {0x0f, 0x85, 0, 0, 0, 0}; memcpy(jne + 2, &r32, 4);
  kr = poke(q + 3, jne, 6);
  lg("retry101: tramp 0x%llx patch kr %d", (unsigned long long)t, kr);
}


static void patch_site(intptr_t slide, uint64_t vm, const unsigned char *want, size_t wn, size_t at, const unsigned char *nb, size_t nn, const char *name, const char *kill) {
  if (kill && access(kill, F_OK) == 0) { lg("%s: disabled by %s", name, kill); return; }
  unsigned char *p = (unsigned char *)(vm + slide);
  if (memcmp(p, want, wn) != 0) { lg("%s: bytes mismatch, not patching", name); return; }
  kern_return_t kr = poke(p + at, nb, nn);
  lg("%s: patch kr %d", name, kr);
}

static void patch_more(void) {
  intptr_t slide = -1; uint32_t i, n = _dyld_image_count();
  for (i = 0; i < n; i++) { const struct mach_header *h = _dyld_get_image_header(i); if (h && h->filetype == MH_EXECUTE) { slide = (intptr_t)h - 0x100000000; break; } }
  if (slide == -1 || slide < 0) return;
  // setEnableExtendedCreateConnectionCommand(bool): movb %dil, g(%rip) -> movb $0, g(%rip)
  static const unsigned char w1[] = {0x40,0x88,0x3d,0x4c,0x64,0x92,0x00}, n1[] = {0xc6,0x05,0x4c,0x64,0x92,0x00,0x00};
  static const unsigned char w2[] = {0x40,0x88,0x3d,0x37,0x64,0x92,0x00}, n2[] = {0xc6,0x05,0x37,0x64,0x92,0x00,0x00};
  patch_site(slide, 0x10020a8a7, w1, sizeof w1, 0, n1, sizeof n1, "legacyconn v1", "/Library/NullMoth/no-btlegacyconn");
  patch_site(slide, 0x10020a8b4, w2, sizeof w2, 0, n2, sizeof n2, "legacyconn v2", "/Library/NullMoth/no-btlegacyconn");
  // UHE check: cmpb $1,(%rbx); je restart -> cmpb; nop2
  static const unsigned char w3[] = {0x80,0x3b,0x01,0x74,0x09}, n3[] = {0x66,0x90};
  patch_site(slide, 0x10051c8af, w3, sizeof w3, 3, n3, sizeof n3, "nouhe", "/Library/NullMoth/no-btnouhe");
}

static IMP o_rules;
static int lastMode = -1;   // 0 passed through, 1 non-connectable dropped

static void typesOf(NSArray *a, char *out, size_t cap) {
  size_t k = 0; out[0] = 0;
  for (NSDictionary *d in a) {
    if (k + 8 >= cap) break;
    BOOL isD = [d isKindOfClass:[NSDictionary class]];
    NSData *m = isD ? d[@"kCBAdvDataAppleMfgData"] : nil;
    const uint8_t *b = [m isKindOfClass:[NSData class]] ? m.bytes : NULL;
    int t = (b && m.length >= 5) ? b[4] : 0xff;
    int c = isD && [d[@"kCBAdvDataIsConnectable"] boolValue];
    k += snprintf(out + k, cap - k, "%s%c%02x", k ? "," : "", c ? 'C' : 'N', t & 0xff);
  }
}

static id h_rules(id self, SEL _cmd) {
  NSArray *r = ((id(*)(id, SEL))o_rules)(self, _cmd);
  if (![r isKindOfClass:[NSArray class]] || r.count < 2 || access("/Library/NullMoth/no-btprio", F_OK) == 0) {
    if (lastMode != 0) { lastMode = 0; lg("prio: pass (%lu sets)", (unsigned long)([r isKindOfClass:[NSArray class]] ? r.count : 0)); }
    return r;
  }
  NSMutableArray *conn = [NSMutableArray array];
  NSUInteger non = 0;
  for (NSDictionary *d in r) {
    if (![d isKindOfClass:[NSDictionary class]]) return r;
    if ([d[@"kCBAdvDataIsConnectable"] boolValue]) [conn addObject:d]; else non++;
  }
  if (conn.count == 0 || non == 0) {
    if (lastMode != 0) { lastMode = 0; lg("prio: pass (%lu sets)", (unsigned long)r.count); }
    return r;
  }
  if (lastMode != 1) { char buf[96]; typesOf(r, buf, sizeof buf); lastMode = 1; lg("prio: keep connectable only [%s]", buf); }
  return conn;
}

__attribute__((constructor)) static void init(void) {
  L = fopen("/tmp/btsingle.log", "a");
  patch_binary();
  patch_more();
  Class C = objc_getClass("WPDAdvertisingManager");
  Method m = C ? class_getInstanceMethod(C, sel_registerName("advertisingRules")) : NULL;
  if (!m) { lg("prio: WPDAdvertisingManager advertisingRules missing"); return; }
  o_rules = method_setImplementation(m, (IMP)h_rules);
  lg("prio: hooked");
}



