// btarb.c -- LE advertising/initiating arbiter for a BT 4.0 controller (BCM20702) inside bluetoothd.
// The chip's LE Supported States (0x1fffffff = BT 4.0 bits 0-28) lack "connectable advertising + initiating" and
// "connectable advertising + master role" (BT 4.1 bits 32/35) but have "scannable advertising + initiating" and
// "scannable advertising + master role" (bits 17/19). macOS keeps connectable NearbyInfo advertising on, so every LE
// Create Connection is answered with Command Disallowed and bluetoothd retries about 1000 times a second until it
// restarts the stack. This shim sits on the USB transport (HCI commands = class control requests, events = interrupt
// pipe reads):
//  - while the Mac initiates an LE connection (macOS also does this in the background, for minutes, to reconnect a
//    paired LE device that is off or away) or holds a master-role link (a BLE mouse), advertising keeps running as
//    scannable undirected advertising (ADV_SCAN_IND, interval at least 100 ms as BT 4.0 requires for that type):
//    on LE Create Connection it switches running connectable advertising off, reprograms and switches it back on;
//    bluetoothd's LE Set Advertising Parameters are rewritten, and before its Advertising Enable(1) the chip is
//    reprogrammed if it still holds connectable parameters. Afterwards the original parameters go back;
//  - if reprogramming is not possible (directed advertising, a failed command), it falls back to holding: on LE Create
//    Connection it sends Advertising Enable(0) itself, and bluetoothd's own Enable(1) goes to the chip as (0);
//  - when an attempt ends (Command Status error, LE Connection Complete) it re-enables advertising at the next point
//    where the chip is idle (one HCI command at a time, see below);
//  - Command Complete events for its own commands become Command Complete for opcode 0x0000 (the HCI no-op),
//    rewritten in place; one interrupt read can carry several events and all of them are walked.
// Kill switches (at launch): /Library/NullMoth/no-btarb (whole shim), /Library/NullMoth/no-btarbscan (hold advertising
// during master links instead of switching to scannable). Log: /tmp/btarb.log
// Multi-advertising: bluetoothd's own Apple/Broadcom multi-advertising path (VSC 0xfd48-0xfd4e: create, remove,
// parameters, data, scan response, enable, address per instance) is answered here instead of by the chip, and the
// enabled instances take turns on the chip's one legacy advertising set, each with its own address. So NearbyInfo /
// NearbyAction (connectable) and AirDrop (non-connectable) go out side by side as on a Mac with Apple Bluetooth.
// Kill switch (at launch, together with btsingle.m): /Library/NullMoth/no-btmulti goes back to the single-instance path.
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

static FILE *L; static pthread_mutex_t LM = PTHREAD_MUTEX_INITIALIZER; static int NLOG, OFF, NOSCAN, MULTI;
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
//    those Command Completes carry a credit of 0, because bluetoothd's own command is about to use the slot;
//  - on a bluetoothd Command Complete/Status we may send ours and set that event's credit to 0; the Command Complete
//    of ours is delivered as an HCI no-op (opcode 0x0000) carrying the credit back;
//  - the idle timer may run a short sequence of ours; bluetoothd's next command waits for it (seqBusy).
static pthread_mutex_t AM = PTHREAD_MUTEX_INITIALIZER;
static int advDesired, advHw, advType = -1, initiating, ourOut, bdOut, restorePending, seqBusy, inCmd;
static uint16_t masters[8]; static int nMasters;
static uint8_t parWant[15], parHw[15]; static int parWantSet, parHwSet;   // LE Set Advertising Parameters: bluetoothd's last, the chip's
static uint16_t ourOp; static int ourStatus; static unsigned nHold, nRepro, nBdPar;
static void *gDev; static IOReturn (*gReq)(void *, IOUSBDevRequest *);
// ---- multi-advertising (MULTI unless /Library/NullMoth/no-btmulti exists at launch) ----
// bluetoothd's Broadcom multi-advertising VSCs (OGF 0x3f, OCF 0x148-0x14e) never reach the chip: each goes out as HCI
// Read Local Version Information, and that Command Complete comes back rewritten to the VSC opcode with status 0 (plus
// an instance handle for 0xfd48, Create).
static uint8_t subCmd[3] = {0x01, 0x10, 0x00};
static int fakeOp, fakeRetLen; static uint8_t fakeRet[2];
static int connType(int t) { return t == 0x00 || t == 0x01 || t == 0x04; }
static int hwConn(void) { return parHwSet ? connType(parHw[4]) : connType(advType); }
static int constrained(void) { return initiating || nMasters > 0; }
static int blocked(void) { return hwConn() && constrained(); }
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
  if (len > 32) return 0;
  uint8_t cmd[3 + 32]; cmd[0] = op & 0xff; cmd[1] = op >> 8; cmd[2] = (uint8_t)len; memcpy(cmd + 3, p, len);
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

// ---- multi-advertising emulation (MULTI) ----
// bluetoothd keeps up to MAXI advertising instances through the VSCs above and then never touches legacy advertising.
// Each instance's parameters, data, scan response and address are kept here, and the chip's single legacy advertising
// set carries the enabled instances in turn (a slot of about two advertising intervals each), with the scannable rule
// above while the Mac initiates or holds a master link. An all-zero instance address gets a non-resolvable private one.
#define MAXI 8
typedef struct { int used, en, parSet; uint8_t atype, addr[6], par[7], adv[31], advLen, rsp[31], rspLen; uint32_t dur; } Inst;
static Inst I[MAXI + 1];
static int cur, dirty, noAddr, hwAddrSet; static uint64_t curT; static uint8_t hwAddr[6]; static unsigned nSw, nVsc;
static const uint8_t zero6[6];
static uint64_t nowMs(void) { struct timeval tv; gettimeofday(&tv, NULL); return (uint64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000; }
static void hexs(const uint8_t *p, unsigned n, char *o, size_t cap) { size_t k = 0; o[0] = 0; for (unsigned j = 0; j < n && k + 3 < cap; j++) k += snprintf(o + k, cap - k, "%02x", p[j]); }
static void nrpa(uint8_t *a) { arc4random_buf(a, 6); a[5] &= 0x3f; }      // HCI byte order: a[5] is the most significant
static int run(uint16_t op, const uint8_t *p, unsigned len, const char *why) {   // AM held, chip idle; status or -1
  if (ourOut > 0 || !sendCmd(op, p, len, why)) return -1;
  waitOurs();
  if (ourOut > 0) { lg("multi: %04x (%s) no answer in time\n", op, why); return -1; }
  if (ourStatus != 0) lg("multi: %04x (%s) status %d\n", op, why, ourStatus);
  return ourStatus;
}
static void multiReset(void) { memset(I, 0, sizeof I); cur = dirty = noAddr = hwAddrSet = 0; }
// bluetoothd's multi-advertising VSC (payload p, pl bytes): update the table and fill the faked return. AM held.
static void multiCmd(uint16_t op, const uint8_t *p, unsigned pl) {
  fakeRet[0] = 0; fakeRetLen = 1;
  char hx[80]; hexs(p, pl < 38 ? pl : 38, hx, sizeof hx);
  if (++nVsc <= 300 || nVsc % 200 == 0) lg("vsc %04x %s #%u\n", op, hx, nVsc);
  int k = pl ? p[0] : 0; Inst *x = (k >= 1 && k <= MAXI && I[k].used) ? &I[k] : NULL;
  switch (op) {
  case 0xfd48:                                                     // Create(address type, address) -> handle
    for (k = 1; k <= MAXI && I[k].used; k++) ;
    if (k > MAXI || pl < 7) { fakeRet[0] = 0x07; break; }          // Memory Capacity Exceeded
    memset(&I[k], 0, sizeof I[k]); I[k].used = 1; I[k].atype = p[0]; memcpy(I[k].addr, p + 1, 6);
    if (!memcmp(I[k].addr, zero6, 6)) { nrpa(I[k].addr); I[k].atype = 1; }
    fakeRet[1] = (uint8_t)k; fakeRetLen = 2;
    break;
  case 0xfd49: if (x) { x->used = x->en = 0; if (cur == k) dirty = 1; } break;                       // Remove
  case 0xfd4a: if (x && pl >= 8) { memcpy(x->par, p + 1, 7); x->parSet = 1; if (cur == k) dirty = 1; } break;   // Params
  case 0xfd4b: case 0xfd4c: if (x && pl >= 2) {                                                         // Data / Scan response
      unsigned n = p[1] > 31 ? 31 : p[1]; if (n > pl - 2) n = pl - 2;
      uint8_t *dst = op == 0xfd4b ? x->adv : x->rsp; memset(dst, 0, 31); memcpy(dst, p + 2, n);
      if (op == 0xfd4b) x->advLen = (uint8_t)n; else x->rspLen = (uint8_t)n;
      if (cur == k) dirty = 1;
    } break;
  case 0xfd4d: if (x && pl >= 2) {                                                                      // Enable
      x->en = p[1] != 0; x->dur = pl >= 6 ? (uint32_t)(p[2] | p[3] << 8 | p[4] << 16 | (uint32_t)p[5] << 24) : 0;
      if (cur == k) dirty = 1;
    } break;
  case 0xfd4e: if (x && pl >= 8) {                                                                      // Address
      x->atype = p[1]; memcpy(x->addr, p + 2, 6);
      if (!memcmp(x->addr, zero6, 6)) { nrpa(x->addr); x->atype = 1; }
      if (cur == k) dirty = 1;
    } break;
  }
}
static int slotMs(const Inst *x) {
  unsigned iv = x->parSet ? (unsigned)(x->par[0] | x->par[1] << 8) : 0x100, ms = iv * 5 / 8 * 2 + 20;
  return ms < 150 ? 150 : ms > 700 ? 700 : (int)ms;
}
// Puts instance k (0 = none) on the air. AM held, chip idle, seqBusy set.
static void putOnAir(int k) {
  if (advHw) { if (!sendAdvEnable(0, "multi switch")) return; waitOurs(); if (ourOut > 0) return; }
  advDesired = 0; restorePending = 0;
  cur = k; curT = nowMs(); dirty = 0;
  if (!k) { if (++nSw <= 60) lg("multi: nothing to advertise\n"); return; }
  Inst *x = &I[k];
  if (x->atype && !noAddr && (!hwAddrSet || memcmp(hwAddr, x->addr, 6))) {
    int st = run(0x2005, x->addr, 6, "multi address");
    if (st == 0) { memcpy(hwAddr, x->addr, 6); hwAddrSet = 1; }
    else if (st > 0) { noAddr = 1; lg("multi: chip refuses address changes (status %d), keeping one address\n", st); }
    else { dirty = 1; return; }
  }
  uint8_t lp[15] = {0};
  memcpy(lp, x->par, 5); lp[5] = x->atype ? 1 : 0; lp[13] = x->par[5] ? x->par[5] : 7; lp[14] = x->par[6];
  if (lp[4] == 0x02 || lp[4] == 0x03) {                          // BT 4.0: at least 100 ms for these types
    unsigned mn = lp[0] | lp[1] << 8, mx = lp[2] | lp[3] << 8;
    if (mn < 0xa0) mn = 0xa0;
    if (mx < mn) mx = mn;
    lp[0] = mn & 0xff; lp[1] = mn >> 8; lp[2] = mx & 0xff; lp[3] = mx >> 8;
  }
  memcpy(parWant, lp, 15); parWantSet = 1; advType = lp[4];
  if (!reprogram(constrained() && canScan(), "multi params")) { dirty = 1; return; }
  uint8_t dd[32]; dd[0] = x->advLen; memcpy(dd + 1, x->adv, 31);
  if (run(0x2008, dd, 32, "multi data") < 0) { dirty = 1; return; }
  dd[0] = x->rspLen; memcpy(dd + 1, x->rsp, 31);
  if (run(0x2009, dd, 32, "multi scan response") < 0) { dirty = 1; return; }
  advDesired = 1;
  if (blocked()) { restorePending = 1; return; }                  // connectable, and the chip cannot advertise it now
  if (sendAdvEnable(1, "multi on")) waitOurs();
  nSw++;
  if (nSw <= 60 || nSw % 200 == 0) {
    char hx[70]; hexs(x->adv, x->advLen, hx, sizeof hx);
    lg("multi: on air inst %d type %u -> %u interval %u slot %d addr %02x:%02x:%02x:%02x:%02x:%02x data %s #%u\n", k, x->par[4], parHw[4],
       parHw[0] | parHw[1] << 8, slotMs(x), hwAddr[5], hwAddr[4], hwAddr[3], hwAddr[2], hwAddr[1], hwAddr[0], hx, nSw);
  }
}
static void multiTick(void *unused) {
  (void)unused;
  pthread_mutex_lock(&AM);
  if (MULTI && !OFF && gDev && bdOut == 0 && ourOut == 0 && !seqBusy) {
    int act[MAXI], na = 0, curOk = 0, next = -1;
    for (int k = 1; k <= MAXI; k++) if (I[k].used && I[k].en && I[k].parSet) { act[na++] = k; if (k == cur) curOk = 1; }
    if (!na) { if (cur || advHw) next = 0; }
    else if (!curOk) next = act[0];
    else if (dirty) next = cur;
    else if (na > 1 && nowMs() - curT >= (uint64_t)slotMs(&I[cur])) { int j = 0; while (act[j] != cur) j++; next = act[(j + 1) % na]; }
    if (next >= 0) { seqBusy = 1; putOnAir(next); seqBusy = 0; }
  }
  pthread_mutex_unlock(&AM);
}

// HCI command from bluetoothd (control transfer data). May rewrite the payload in place. Returns 1 when the command
// must go to the chip as subCmd instead.
static int onCommand(uint8_t *d, unsigned n) {
  if (OFF || n < 3) return 0;
  uint16_t op = d[0] | (d[1] << 8);
  pthread_mutex_lock(&AM);
  static int thrLogged;
  if (!thrLogged && evThreadSet) { thrLogged = 1; lg("commands on %s thread as events\n", pthread_equal(evThread, pthread_self()) ? "the same" : "a different"); }
  for (int i = 0; i < 300 && seqBusy; i++) { pthread_mutex_unlock(&AM); usleep(1000); pthread_mutex_lock(&AM); }
  if (ourOut > 0) waitOurs();
  if (MULTI && op >= 0xfd48 && op <= 0xfd4e) {
    fakeOp = op; multiCmd(op, d + 3, n - 3);
    bdOut = 1;
    pthread_mutex_unlock(&AM);
    return 1;
  }
  inCmd = 1;
  if (wantRestore() && op != 0x200a && op != 0x2006 && ourOut == 0) { if (sendAdvEnable(1, "restore before command")) waitOurs(); restorePending = 0; }
  switch (op) {
  case 0x2006: if (n >= 3 + 15) {                                            // LE Set Advertising Parameters
      memcpy(parWant, d + 3, 15); parWantSet = 1; advType = d[3 + 4];
      if (constrained() && canScan()) scannable(d + 3);
      memcpy(parHw, d + 3, 15); parHwSet = 1;
      nBdPar++;
      if (nBdPar <= 20 || nBdPar % 500 == 0) lg("bd adv params: type %u -> %u interval %u-%u (masters %d) #%u\n", parWant[4], parHw[4], parHw[0] | (parHw[1] << 8), parHw[2] | (parHw[3] << 8), nMasters, nBdPar);
    } break;
  case 0x200a: if (n >= 4) {                                                   // LE Set Advertising Enable
      advDesired = d[3]; restorePending = 0;
      if (d[3] == 1) {
        if (constrained() && hwConn() && canScan()) reprogram(1, nMasters > 0 ? "scannable while master" : "scannable while initiating");
        else if (!constrained() && parWantSet && parHwSet && memcmp(parHw, parWant, 15)) reprogram(0, "restore after link");
        if (blocked()) {
          d[3] = 0; advHw = 0; restorePending = 1;
          nHold++;
          if (nHold <= 20 || nHold % 1000 == 0) lg("hold adv enable (initiating %d masters %d) #%u\n", initiating, nMasters, nHold);
        } else advHw = 1;
      } else advHw = 0;
    } break;
  case 0x200d: case 0x2043:                                                    // LE (Extended) Create Connection
    initiating = 1;
    if (advHw && hwConn() && ourOut == 0) {
      if (canScan() && reprogram(1, "scannable for create connection")) { if (ourOut == 0 && sendAdvEnable(1, "scannable during create connection")) waitOurs(); }
      else if (advHw && ourOut == 0) { if (sendAdvEnable(0, "create connection")) waitOurs(); }
    }
    break;
  }
  bdOut = 1;
  inCmd = 0;
  pthread_mutex_unlock(&AM);
  return 0;
}

// One HCI event (e = event code, e[1] = parameter length, elen = e[1] + 2 bytes available). Rewrites in place; returns
// the event's new length (shorter only for a faked multi-advertising Command Complete).
static unsigned onOneEvent(uint8_t *e, unsigned elen) {
  if (fakeOp && e[0] == 0x0e && elen >= 6 && e[3] == 0x01 && e[4] == 0x10) {    // Read Local Version -> the VSC
    e[1] = (uint8_t)(3 + fakeRetLen); e[3] = fakeOp & 0xff; e[4] = fakeOp >> 8; memcpy(e + 5, fakeRet, fakeRetLen);
    if (fakeOp == 0xfd48 || fakeRet[0]) lg("fake cc %04x ret %02x%s%02x\n", fakeOp, fakeRet[0], fakeRetLen > 1 ? " inst " : " ", fakeRetLen > 1 ? fakeRet[1] : 0);
    fakeOp = 0; elen = 5u + fakeRetLen;
  }
  int cc = e[0] == 0x0e && elen >= 5, cs = e[0] == 0x0f && elen >= 6;
  if (cc && ourOut > 0 && (e[3] | (e[4] << 8)) == ourOp) {                     // Command Complete for our own command
    ourOut--; ourStatus = elen >= 6 ? e[5] : 255;
    if (ourOp == 0x200a || ourStatus != 0) lg("cc %04x status %d -> nop (bd out %d)\n", ourOp, ourStatus, bdOut);
    e[2] = (bdOut || inCmd) ? 0 : 1; e[3] = 0; e[4] = 0;                       // opcode 0x0000 = no-op; length unchanged
  } else if (cc || cs) {
    uint16_t op = cc ? (e[3] | (e[4] << 8)) : (e[4] | (e[5] << 8));
    uint8_t *credit = cc ? &e[2] : &e[3];
    if (op != 0 && *credit) bdOut = 0;
    if (cs && op == 0x200d && e[2] != 0) { initiating = 0; restorePending = 1; lg("create connection status 0x%02x\n", e[2]); }
    if (cc && op == 0x2006 && elen >= 6 && e[5] != 0) { parHwSet = 0; lg("bd adv params status 0x%02x\n", e[5]); }
    if (cc && op == 0x0c03) { advDesired = advHw = initiating = nMasters = ourOut = bdOut = restorePending = parWantSet = parHwSet = 0; advType = -1; multiReset(); lg("hci reset\n"); }
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
  return elen;
}

// A read from the interrupt pipe can carry more than one event. Walk them all; the length only shrinks.
static unsigned onEvent(uint8_t *b, unsigned n) {
  if (OFF || n < 2) return n;
  pthread_mutex_lock(&AM);
  if (!evThreadSet) { evThread = pthread_self(); evThreadSet = 1; }
  unsigned i = 0, cnt = 0;
  while (i + 2 <= n) {
    unsigned elen = b[i + 1] + 2u;
    if (i + elen > n) break;                       // partial event: leave it alone
    unsigned nl = onOneEvent(b + i, elen);
    if (nl < elen) { memmove(b + i + nl, b + i + elen, n - (i + elen)); n -= elen - nl; elen = nl; }
    i += elen; cnt++;
  }
  if (cnt > 1) lg("read carried %u events (%u bytes)\n", cnt, n);
  pthread_mutex_unlock(&AM);
  return n;
}

// Fallback when nothing else gives us a turn: while the chip is idle for about 1 s, switch the parameters to match the
// link state (scannable while initiating or during master links, bluetoothd's own afterwards) and restore advertising.
static void tick(void *unused) {
  (void)unused;
  pthread_mutex_lock(&AM);
  static int idleTicks;
  int idle = bdOut == 0 && ourOut == 0 && !seqBusy && advDesired;
  int needScan = idle && constrained() && hwConn() && canScan();
  int needBack = idle && !constrained() && parWantSet && parHwSet && memcmp(parHw, parWant, 15);
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
// 1 when the command must go to the chip as subCmd (3 bytes) instead of bluetoothd's bytes
static int cmdHook(void *s, UInt8 t, void *data, UInt16 len) {
  if ((t & 0x80) == 0 && (t & 0x60) == 0x20 && data && len >= 3) { if (!gDev) { gDev = s; gReq = (IOReturn (*)(void *, IOUSBDevRequest *))odv.DeviceRequest; } return onCommand(data, len); }
  return 0;
}
typedef struct { IOAsyncCallback1 cb; void *ref; UInt32 len; } SubCtx;
static void subDone(void *r, IOReturn res, void *arg0) {   // report bluetoothd's own length for a substituted command
  SubCtx *c = r; IOAsyncCallback1 cb = c->cb; void *ref = c->ref; UInt32 len = c->len; free(c);
  if (cb) cb(ref, res, res == kIOReturnSuccess ? (void *)(uintptr_t)len : arg0);
}
static IOUSBDevRequest subQ; static IOUSBDevRequestTO subQT;
static IOReturn dRq(void *s, IOUSBDevRequest *q) {
  if (!cmdHook(s, q->bmRequestType, q->pData, q->wLength)) return odv.DeviceRequest(s, q);
  IOUSBDevRequest q2 = *q; q2.pData = subCmd; q2.wLength = 3; q2.wLenDone = 0;
  IOReturn r = odv.DeviceRequest(s, &q2); q->wLenDone = r ? q2.wLenDone : q->wLength; return r;
}
static IOReturn dRqA(void *s, IOUSBDevRequest *q, IOAsyncCallback1 cb, void *rf) {
  if (!cmdHook(s, q->bmRequestType, q->pData, q->wLength)) return odv.DeviceRequestAsync(s, q, cb, rf);
  subQ = *q; subQ.pData = subCmd; subQ.wLength = 3; subQ.wLenDone = 0;
  SubCtx *c = malloc(sizeof *c); c->cb = cb; c->ref = rf; c->len = q->wLength;
  IOReturn r = odv.DeviceRequestAsync(s, &subQ, subDone, c); if (r) free(c); else q->wLenDone = q->wLength; return r;
}
static IOReturn dRqT(void *s, IOUSBDevRequestTO *q) {
  if (!cmdHook(s, q->bmRequestType, q->pData, q->wLength)) return odv.DeviceRequestTO(s, q);
  IOUSBDevRequestTO q2 = *q; q2.pData = subCmd; q2.wLength = 3; q2.wLenDone = 0;
  IOReturn r = odv.DeviceRequestTO(s, &q2); q->wLenDone = r ? q2.wLenDone : q->wLength; return r;
}
static IOReturn dRqAT(void *s, IOUSBDevRequestTO *q, IOAsyncCallback1 cb, void *rf) {
  if (!cmdHook(s, q->bmRequestType, q->pData, q->wLength)) return odv.DeviceRequestAsyncTO(s, q, cb, rf);
  subQT = *q; subQT.pData = subCmd; subQT.wLength = 3; subQT.wLenDone = 0;
  SubCtx *c = malloc(sizeof *c); c->cb = cb; c->ref = rf; c->len = q->wLength;
  IOReturn r = odv.DeviceRequestAsyncTO(s, &subQT, subDone, c); if (r) free(c); else q->wLenDone = q->wLength; return r;
}
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
static dispatch_source_t gTick, gMulti;
__attribute__((constructor)) static void init(void) {
  OFF = access("/Library/NullMoth/no-btarb", F_OK) == 0;
  NOSCAN = access("/Library/NullMoth/no-btarbscan", F_OK) == 0;
  MULTI = access("/Library/NullMoth/no-btmulti", F_OK) != 0;
  if (!OFF) {
    gTick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gTick, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 500 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler_f(gTick, tick);
    dispatch_resume(gTick);
  }
  if (!OFF && MULTI) {   // the multi-advertising scheduler runs on its own serial queue every 40 ms
    gMulti = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_queue_create("nullmoth.btmulti", NULL));
    dispatch_source_set_timer(gMulti, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 40 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler_f(gMulti, multiTick);
    dispatch_resume(gMulti);
  }
  lg("btarb loaded%s%s%s\n", OFF ? " (disabled by /Library/NullMoth/no-btarb)" : "", NOSCAN ? " (scannable switch off)" : "", MULTI ? " (multi)" : " (single)");
}
