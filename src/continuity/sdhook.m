// sdhook.m -- in sharingd: after -[SFDevice updateWithRPIdentity:], mark SameAccountDevice identities as MyiCloud (0x8),
// the same thing Sharing.framework does when SFDeviceIsVirtualMachine() is true.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/log.h>
typedef void (*UFn)(id, SEL, id);
static UFn gOrig; static int gN;
static void hook(id self, SEL _cmd, id ident) {
  gOrig(self, _cmd, ident);
  if (!ident || ![ident respondsToSelector:sel_registerName("type")]) return;
  int t = ((int (*)(id, SEL))objc_msgSend)(ident, sel_registerName("type"));
  if (t != 2) return;
  unsigned int f = ((unsigned int (*)(id, SEL))objc_msgSend)(self, sel_registerName("deviceFlags"));
  if (!(f & 0x8)) {
    ((void (*)(id, SEL, unsigned int))objc_msgSend)(self, sel_registerName("setDeviceFlags:"), f | 0x8);
    if (gN++ < 200) os_log(OS_LOG_DEFAULT, "SDHOOK MyiCloud set: DF 0x%x -> 0x%x", f, f | 0x8);
  }
}
__attribute__((constructor)) static void init(void) {
  Class C = NSClassFromString(@"SFDevice");
  Method m = C ? class_getInstanceMethod(C, sel_registerName("updateWithRPIdentity:")) : NULL;
  if (m) gOrig = (UFn)method_setImplementation(m, (IMP)hook);
  os_log(OS_LOG_DEFAULT, "SDHOOK loaded class=%p method=%p", C, m);
}
