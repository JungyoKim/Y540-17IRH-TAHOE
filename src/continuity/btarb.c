// btarb.c -- LE advertising/initiating arbiter for a BT 4.0 controller (BCM20702) inside bluetoothd.
// The chip's LE Supported States (0x1fffffff = BT 4.0 bits 0-28) lack "connectable advertising + initiating" and
// "connectable advertising + master role" (BT 4.1 bits 32/35) but have "scannable advertising + initiating" and
// "scannable advertising + master role" (bits 17/19). macOS keeps connectable NearbyInfo advertising on, so every LE
// Create Connection is answered with Command Disallowed and bluetoothd retries about 1000 times a second until it
// restarts the stack. This shim sits on the USB transport (HCI commands = class control requests, events = interrupt
// pipe reads):
//  - on LE Create Connection while connectable advertising runs, it first sends LE Set Advertising Enable(0) itself;
//  - while initiating with connectable parameters, bluetoothd's own Advertising Enable(1) goes to the chip as (0);
//  - while a master-role link is up (a BLE mouse, for example), advertising keeps running as scannable undirected
//    advertising (ADV_SCAN_IND, interval at least 100 ms as BT 4.0 requires for that type): bluetoothd's LE Set
//    Advertising Parameters are rewritten, and before its Advertising Enable(1) the chip is reprogrammed if it still
//    holds connectable parameters. After the last master link is gone the original parameters go back;
//  - when an attempt ends (Command Status error, LE Connection Complete) it re-enables advertising at the next point
//    where the chip is idle (one HCI command at a time, see below);
//  - Command Complete events for its own commands become Command Complete for opcode 0x0000 (the HCI no-op),
//    rewritten in place; one interrupt read can carry several events and all of them are walked.
// Kill switches (at launch): /Library/NullMoth/no-btarb (whole shim), /Library/NullMoth/no-btarbscan (hold advertising
// during master links instead of switching to scannable). Log: /tmp/btarb.log
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <pthread.h>
#include <sys/time.h>
#include <time.h>

static FILE *L; static pthread_mutex_t LM = PTHREAD_MUTEX_INITIALIZER; static int NLOG, OFF, NOSCAN;
static void lg(const char *f, ...) {
  pthread_mutex_lock(&LM);
  if (!L) { L = fopen("/tmp/btarb.log", "a"); if (L) setvbuf(L, NULL, _IOLBF, 0); }
  if (L && NLOG < 20000) {
    NLOG++; struct timeval tv; gettimeofday(&tv, NULL); struct tm tm; localtime_r(&tv.tv_sec, &tm);
    fprintf(L, "%02d:%02d:%02d.%03d %d ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000), getpid());
    va_list a; va_start(a, f); vfprintf(L, f, a); va_end(a);
  }
  pthread_mutex_unlock(&LM);
}

// ---- arbiter state (all under AM) ----
// The chip takes one HCI command at a time (Num_HCI_Command_Packets = 1). Our own commands are only sent when no
// bluetoothd command is outstanding, and bluetoothd is kept from sending until ours have completed:
//  - before forwarding a bluetoothd command we may send ours and wait (up to 20 ms each) for its Command Complete;
//  - on a bluetoothd Command Complete/Status we may send ours and set that event's credit to 0; the Command Complete
//    of ours is delivered as an HCI no-op (opcode 0x0000) carrying the credit back;
//  - the idle timer may run a short sequence of ours; bluetoothd's next command waits for it (seqBusy).
static pthread_mutex_t AM = PTHREAD_MUTEX_INITIALIZER;
static int advDesired, advHw, advType = -1, initiating, ourOut, bdOut, restorePending, seqBusy;
static uint16_t masters[8]; static int nMasters;
static uint8_t parWant[15], parHw[15]; static int parWantSet, parHwSet;   // LE Set Advertising Parameters: bluetoothd's last, the chip's
static uint16_t ourOp; static int ourStatus; static unsigned nHold, nRepro, nBdPar;
static void *gDev; static IOReturn (*gReq)(void *, IOUSBDevRequest *);
static int connType(int t) { return t == 0x00 || t == 0x01 || t == 0x04; }
static int hwConn(void) { return parHwSet ? connType(parHw[4]) : connType(advType); }
static int blocked(void) { return hwConn() && (initiating || nMasters > 0); }
static int wantRestore(void) { return restorePending && !blocked() && advDesired && !advHw && !seqBusy; }
static int canScan(void) { return !NOSCAN && parWantSet && parWant[4] == 0x00; }
static void scannable(uint8_t *p) {   // 15 parameter bytes: ADV_IND -> ADV_SCAN_IND, interval at least 0x00A0
  if (p[4] != 0x00) return;
  unsigned mn = p[0] | (p[1] << 8), mx = p[2] | (p[3] << 8);
  if (mn < 0xa0) mn = 0xa0;
  if (mx < mn) mx = mn;
  p[0] = mn & 0xff; p[1] = mn >> 8; p[2] = mx & 0xff; p[3] = mx >> 8; p[4] = 0x02;
}

static int sendCmd(uint16_t op, const uint8_t *p, unsigned len, const char *why) {
  if (!gDev || !gReq) { lg("inject %04x (%s): no device\n", op, why); return 0; }
  if (len > 16) return 0;
  uint8_t cmd[3 + 16]; cmd[0] = op & 0xff; cmd[1] = op >> 8; cmd[2] = (uint8_t)len; memcpy(cmd + 3, p, len);
  IOUSBDevRequest q = {0x21, 0x00, 0, 0, (UInt16)(3 + len), cmd, 0};
  ourOut++; ourOp = op; ourStatus = -1;
  IOReturn r = gReq(gDev, &q);
  if (r) { ourOut--; lg("inject %04x (%s) failed 0x%x\n", op, why, r); return 0; }
  return 1;
}
static int sendAdvEnable(uint8_t on, const char *why) {
  if (!sendCmd(0x200a, &on, 1, why)) return 0;
  advHw = on;
  lg("inject adv %d (%s, bd out %d)\n", on, why, bdOut);
  return 1;
}
static pthread_t evThread; static int evThreadSet;
static void waitOurs(void) {   // AM held. If events are read on this very thread, waiting cannot see them: just give the chip 3 ms.
  if (evThreadSet && pthread_equal(evThread, pthread_self())) { pthread_mutex_unlock(&AM); usleep(3000); pthread_mutex_lock(&AM); return; }
  for (int i = 0; i < 20 && ourOut > 0; i++) { pthread_mutex_unlock(&AM); usleep(1000); pthread_mutex_lock(&AM); }
}
// AM held, chip idle. Puts bluetoothd's parameters (as scannable when sc) into the chip, switching advertising off first
// if it runs. Returns 1 when the chip accepted them.
static int reprogram(int sc, const char *why) {
  if (!parWantSet || ourOut > 0) return 0;
  if (advHw) { if (!sendAdvEnable(0, why)) return 0; waitOurs(); if (ourOut > 0) return 0; }
  uint8_t p[15]; memcpy(p, parWant, 15);
  if (sc) scannable(p);
  if (!sendCmd(0x2006, p, 15, why)) return 0;
  waitOurs();
  if (ourOut > 0 || ourStatus != 0) { lg("adv params (%s) failed: status %d out %d\n", why, ourStatus, ourOut); parHwSet = 0; return 0; }
  memcpy(parHw, p, 15); parHwSet = 1;
  nRepro++;
  if (nRepro <= 50 || nRepro % 500 == 0) lg("adv params %s: type %u interval %u-%u (masters %d) #%u\n", why, p[4], p[0] | (p[1] << 8), p[2] | (p[3] << 8), nMasters, nRepro);
  return 1;
}

// HCI command from bluetoothd (control transfer data). May rewrite the payload in place.
static void onCommand(uint8_t *d, unsigned n) {
  if (OFF || n < 3) return;
  uint16_t op = d[0] | (d[1] << 8);
  pthread_mutex_lock(&AM);
  static int thrLogged;
  if (!thrLogged && evThreadSet) { thrLogged = 1; lg("commands on %s thread as events\n", pthread_equal(evThread, pthread_self()) ? "the same" : "a different"); }
  for (int i = 0; i < 100 && seqBusy; i++) { pthread_mutex_unlock(&AM); usleep(1000); pthread_mutex_lock(&AM); }
  if (ourOut > 0) waitOurs();
  if (wantRestore() && op != 0x200a && op != 0x2006 && ourOut == 0) { if (sendAdvEnable(1, "restore before command")) waitOurs(); restorePending = 0; }
  switch (op) {
  case 0x2006: if (n >= 3 + 15) {                                            // LE Set Advertising Parameters
      memcpy(parWant, d + 3, 15); parWantSet = 1; advType = d[3 + 4];
      if (nMasters > 0 && canScan()) scannable(d + 3);
      memcpy(parHw, d + 3, 15); parHwSet = 1;
      nBdPar++;
      if (nBdPar <= 20 || nBdPar % 500 == 0) lg("bd adv params: type %u -> %u interval %u-%u (masters %d) #%u\n", parWant[4], parHw[4], parHw[0] | (parHw[1] << 8), parHw[2] | (parHw[3] << 8), nMasters, nBdPar);
    } break;
  case 0x200a: if (n >= 4) {                                                   // LE Set Advertising Enable
      advDesired = d[3]; restorePending = 0;
      if (d[3] == 1) {
        if (!initiating && nMasters > 0 && hwConn() && canScan()) reprogram(1, "scannable while master");
        else if (!initiating && nMasters == 0 && parWantSet && parHwSet && memcmp(parHw, parWant, 15)) reprogram(0, "restore after master");
        if (blocked()) {
          d[3] = 0; advHw = 0; restorePending = 1;
          nHold++;
          if (nHold <= 20 || nHold % 1000 == 0) lg("hold adv enable (initiating %d masters %d) #%u\n", initiating, nMasters, nHold);
        } else advHw = 1;
      } else advHw = 0;
    } break;
  case 0x200d: case 0x2043:                                                    // LE (Extended) Create Connection
    initiating = 1;
    if (advHw && hwConn() && ourOut == 0) { if (sendAdvEnable(0, "create connection")) waitOurs(); }
    break;
  }
  bdOut = 1;
  pthread_mutex_unlock(&AM);
}

// One HCI event (e = event code, e[1] = parameter length, elen = e[1] + 2 bytes available). Rewrites in place only.
static void onOneEvent(uint8_t *e, unsigned elen) {
  int cc = e[0] == 0x0e && elen >= 5, cs = e[0] == 0x0f && elen >= 6;
  if (cc && ourOut > 0 && (e[3] | (e[4] << 8)) == ourOp) {                     // Command Complete for our own command
    ourOut--; ourStatus = elen >= 6 ? e[5] : 255;
    if (ourOp == 0x200a || ourStatus != 0) lg("cc %04x status %d -> nop (bd out %d)\n", ourOp, ourStatus, bdOut);
    e[2] = bdOut ? 0 : 1; e[3] = 0; e[4] = 0;                                  // opcode 0x0000 = no-op; length unchanged
  } else if (cc || cs) {
    uint16_t op = cc ? (e[3] | (e[4] << 8)) : (e[4] | (e[5] << 8));
    uint8_t *credit = cc ? &e[2] : &e[3];
    if (op != 0 && *credit) bdOut = 0;
    if (cs && op == 0x200d && e[2] != 0) { initiating = 0; restorePending = 1; lg("create connection status 0x%02x\n", e[2]); }
    if (cc && op == 0x2006 && elen >= 6 && e[5] != 0) { parHwSet = 0; lg("bd adv params status 0x%02x\n", e[5]); }
    if (cc && op == 0x0c03) { advDesired = advHw = initiating = nMasters = ourOut = bdOut = restorePending = parWantSet = parHwSet = 0; advType = -1; lg("hci reset\n"); }
    else if (wantRestore() && bdOut == 0 && ourOut == 0 && *credit && sendAdvEnable(1, "restore at command end")) { restorePending = 0; *credit = 0; }
  } else if (e[0] == 0x3e && elen >= 7 && (e[2] == 0x01 || e[2] == 0x0a)) {        // LE (Enhanced) Connection Complete
    uint8_t st = e[3], role = e[6]; uint16_t h = (e[4] | (e[5] << 8)) & 0xfff;
    int wasInit = initiating;
    if (role == 0 || st != 0) initiating = 0;
    if (st == 0 && role == 0 && nMasters < 8) masters[nMasters++] = h;
    if (st == 0 && role == 1) advHw = 0;                                           // slave link stops advertising
    if (advDesired && !advHw) restorePending = 1;
    lg("le conn complete status 0x%02x handle 0x%x role %u (init %d -> %d, masters %d)\n", st, h, role, wasInit, initiating, nMasters);
  } else if (e[0] == 0x05 && elen >= 6) {                                           // Disconnection Complete
    uint16_t h = (e[3] | (e[4] << 8)) & 0xfff;
    for (int i = 0; i < nMasters; i++) if (masters[i] == h) { masters[i] = masters[--nMasters]; if (advDesired && !advHw) restorePending = 1; lg("master 0x%x disconnected (masters %d)\n", h, nMasters); break; }
  }
}

// A read from the interrupt pipe can carry more than one event. Walk them all; the length never changes.
static unsigned onEvent(uint8_t *b, unsigned n) {
  if (OFF || n < 2) return n;
  pthread_mutex_lock(&AM);
  if (!evThreadSet) { evThread = pthread_self(); evThreadSet = 1; }
  unsigned i = 0, cnt = 0;
  while (i + 2 <= n) {
    unsigned elen = b[i + 1] + 2u;
    if (i + elen > n) break;                       // partial event: leave it alone
    onOneEvent(b + i, elen);
    i += elen; cnt++;
  }
  if (cnt > 1) lg("read carried %u events (%u bytes)\n", cnt, n);
  pthread_mutex_unlock(&AM);
  return n;
}

// Fallback when nothing else gives us a turn: while the chip is idle for about 1 s, switch the parameters to match the
// link state (scannable during master links, bluetoothd's own afterwards) and restore advertising.
static void tick(void *unused) {
  (void)unused;
  pthread_mutex_lock(&AM);
  static int idleTicks;
  int idle = bdOut == 0 && ourOut == 0 && !seqBusy && !initiating && advDesired;
  int needScan = idle && nMasters > 0 && hwConn() && canScan();
  int needBack = idle && nMasters == 0 && parWantSet && parHwSet && memcmp(parHw, parWant, 15);
  if (needScan || needBack || (wantRestore() && bdOut == 0 && ourOut == 0)) {
    if (++idleTicks >= 2) {
      idleTicks = 0;
      seqBusy = 1;
      int ok = 1;
      if (needScan) ok = reprogram(1, "scannable when idle");
      else if (needBack) ok = reprogram(0, "restore when idle");
      if (ok && !advHw && advDesired && !blocked() && ourOut == 0) { if (sendAdvEnable(1, "restore when idle")) { waitOurs(); restorePending = 0; } }
      seqBusy = 0;
    }
  } else idleTicks = 0;
  pthread_mutex_unlock(&AM);
}

// ---- IOUSBLib hooks (same structure as btprobe2) ----
typedef struct { IOAsyncCallback1 cb; void *ref; void *buf; } Ctx;
static void rdone(void *r, IOReturn res, void *arg0) {
  Ctx *c = r; unsigned n = (unsigned)(uintptr_t)arg0;
  if (res == kIOReturnSuccess && c->buf && n) n = onEvent(c->buf, n);   // only interrupt-pipe reads get a context
  IOAsyncCallback1 cb = c->cb; void *ref = c->ref; free(c); if (cb) cb(ref, res, (void *)(uintptr_t)n);
}
static Ctx *mk(IOAsyncCallback1 cb, void *ref, void *buf) { Ctx *c = malloc(sizeof *c); c->cb = cb; c->ref = ref; c->buf = buf; return c; }

typedef IOUSBDeviceInterface942 DV; static DV odv, wdv; static int dvw;
static void cmdHook(void *s, UInt8 t, void *data, UInt16 len) {
  if ((t & 0x80) == 0 && (t & 0x60) == 0x20 && data && len >= 3) { if (!gDev) { gDev = s; gReq = (IOReturn (*)(void *, IOUSBDevRequest *))odv.DeviceRequest; } onCommand(data, len); }
}
static IOReturn dRq(void *s, IOUSBDevRequest *q) { cmdHook(s, q->bmRequestType, q->pData, q->wLength); return odv.DeviceRequest(s, q); }
static IOReturn dRqA(void *s, IOUSBDevRequest *q, IOAsyncCallback1 cb, void *rf) { cmdHook(s, q->bmRequestType, q->pData, q->wLength); return odv.DeviceRequestAsync(s, q, cb, rf); }
static IOReturn dRqT(void *s, IOUSBDevRequestTO *q) { cmdHook(s, q->bmRequestType, q->pData, q->wLength); return odv.DeviceRequestTO(s, q); }
static IOReturn dRqAT(void *s, IOUSBDevRequestTO *q, IOAsyncCallback1 cb, void *rf) { cmdHook(s, q->bmRequestType, q->pData, q->wLength); return odv.DeviceRequestAsyncTO(s, q, cb, rf); }
static void wrapdev(void **obj) { if (!dvw) { memcpy(&odv, *obj, sizeof odv); wdv = odv; wdv.DeviceRequest = dRq; wdv.DeviceRequestAsync = dRqA; wdv.DeviceRequestTO = dRqT; wdv.DeviceRequestAsyncTO = dRqAT; dvw = 1; } *obj = &wdv; }

typedef IOUSBInterfaceInterface942 IF; static IF oif, wif; static int ifw;
static signed char pipeKind[32];   // 0 unknown, 1 interrupt-in (HCI events), 2 other
static int isEventPipe(void *s, UInt8 p) {
  if (p >= 32) return 0;
  if (!pipeKind[p]) { UInt8 dir = 0, num = 0, tt = 0, iv = 0; UInt16 mps = 0;
    pipeKind[p] = (oif.GetPipeProperties(s, p, &dir, &num, &tt, &mps, &iv) == kIOReturnSuccess && tt == kUSBInterrupt && dir == kUSBIn) ? 1 : 2;
    lg("pipe %u kind %d (type %u dir %u)\n", p, pipeKind[p], tt, dir); }
  return pipeKind[p] == 1;
}
static IOReturn iRA(void *s, UInt8 p, void *b, UInt32 n, IOAsyncCallback1 cb, void *rf) {
  if (OFF || !isEventPipe(s, p)) return oif.ReadPipeAsync(s, p, b, n, cb, rf);
  return oif.ReadPipeAsync(s, p, b, n, rdone, mk(cb, rf, b)); }
static IOReturn iRAT(void *s, UInt8 p, void *b, UInt32 n, UInt32 t1, UInt32 t2, IOAsyncCallback1 cb, void *rf) {
  if (OFF || !isEventPipe(s, p)) return oif.ReadPipeAsyncTO(s, p, b, n, t1, t2, cb, rf);
  return oif.ReadPipeAsyncTO(s, p, b, n, t1, t2, rdone, mk(cb, rf, b)); }
static void wrapif(void **obj) { if (!ifw) { memcpy(&oif, *obj, sizeof oif); wif = oif; wif.ReadPipeAsync = iRA; wif.ReadPipeAsyncTO = iRAT; ifw = 1; } *obj = &wif; }

static IOCFPlugInInterface pvD, pvI; static HRESULT (*qD)(void *, REFIID, LPVOID *), (*qI)(void *, REFIID, LPVOID *);
static int isIID(REFIID iid, CFUUIDRef u) { CFUUIDRef x = CFUUIDCreateFromUUIDBytes(NULL, iid); int r = CFEqual(x, u); CFRelease(x); return r; }
static HRESULT myQD(void *s, REFIID iid, LPVOID *pp) { HRESULT r = qD(s, iid, pp);
  if (r == 0 && pp && *pp && isIID(iid, kIOUSBDeviceInterfaceID942)) wrapdev((void **)*pp); return r; }
static HRESULT myQI(void *s, REFIID iid, LPVOID *pp) { HRESULT r = qI(s, iid, pp);
  if (r == 0 && pp && *pp && (isIID(iid, kIOUSBInterfaceInterfaceID942) || isIID(iid, kIOUSBInterfaceInterfaceID800) || isIID(iid, kIOUSBInterfaceInterfaceID700) || isIID(iid, kIOUSBInterfaceInterfaceID650))) wrapif((void **)*pp);
  return r; }
kern_return_t btarbCreate(io_service_t sv, CFUUIDRef pt, CFUUIDRef it, IOCFPlugInInterface ***pi, SInt32 *sc) {
  kern_return_t r = IOCreatePlugInInterfaceForService(sv, pt, it, pi, sc);
  if (OFF || r != KERN_SUCCESS || !pi || !*pi) return r;
  IOCFPlugInInterface **p = *pi;
  if (CFEqual(pt, kIOUSBDeviceUserClientTypeID)) { if (!qD) { qD = (*p)->QueryInterface; memcpy(&pvD, *p, sizeof pvD); pvD.QueryInterface = myQD; } *p = &pvD; }
  else if (CFEqual(pt, kIOUSBInterfaceUserClientTypeID)) { if (!qI) { qI = (*p)->QueryInterface; memcpy(&pvI, *p, sizeof pvI); pvI.QueryInterface = myQI; } *p = &pvI; }
  return r;
}
__attribute__((used)) static struct { const void *n, *o; } ip[] __attribute__((section("__DATA,__interpose"))) = { { (const void *)btarbCreate, (const void *)IOCreatePlugInInterfaceForService } };
#include <dispatch/dispatch.h>
static dispatch_source_t gTick;
__attribute__((constructor)) static void init(void) {
  OFF = access("/Library/NullMoth/no-btarb", F_OK) == 0;
  NOSCAN = access("/Library/NullMoth/no-btarbscan", F_OK) == 0;
  if (!OFF) {
    gTick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gTick, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler_f(gTick, tick);
    dispatch_resume(gTick);
  }
  lg("btarb loaded%s%s\n", OFF ? " (disabled by /Library/NullMoth/no-btarb)" : "", NOSCAN ? " (scannable switch off)" : "");
}
