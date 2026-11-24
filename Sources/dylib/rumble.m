// 震動輸出：把遊戲要的震動直接送給實體手柄（繞過 Steam）。
// Steam 在 Mac 上建立的虛擬 Xbox 手柄沒有輸出 report，遊戲的震動送不到手柄，所以由這裡代送。
//
// Steam Controller 2（28de:1302–1305），協定參考 SDL3 src/joystick/hidapi/SDL_hidapi_steam_triton.c：
//   output report 0x80 = MsgHapticRumble { u8 type; u16 intensity; {u16 speed; i8 gain} left, right; }
//   手柄約 50ms 沒收到就停，所以震動期間每 40ms 重送一次。
//
// 藍牙 Xbox 手柄（045e），協定參考 SDL src/joystick/hidapi/SDL_hidapi_xboxone.c：
//   output report 0x03 = { u8 enable(0x0F); u8 左扳機, 右扳機, 左馬達, 右馬達（0–100）; u8 持續(10ms); u8 延遲; u8 重複 }
//   持續時間設 0.5 秒、震動期間每 0.28 秒重送：停止指令在藍牙上掉了也只會多震一下。
//
// 藍牙的 SetReport 是同步的且慢（數 ms 到數十 ms），遊戲又常每幀改震動值；
// 若每次改動都排一個送出工作，佇列會越積越多，停止指令被延後、舊的震動延遲播放。
// 所以只記下最新的值，佇列裡最多一個待送工作。停止時再補送幾次 0，避免停止指令遺失。
#import <Foundation/Foundation.h>
#import <os/lock.h>
#import <IOKit/hid/IOHIDLib.h>
#import "rumble.h"

void fixLog(NSString *format, ...);

typedef NS_ENUM(NSInteger, RumbleKind) { RumbleKindSteam, RumbleKindXbox };

static dispatch_queue_t rumbleQueue;
static IOHIDManagerRef manager;
static NSMutableDictionary<NSValue *, NSNumber *> *outputDevices;   // 裝置 → RumbleKind
static dispatch_source_t resendTimer;
static uint16_t currentLeft, currentRight;
static unsigned resendTick;
static unsigned stopRepeats;   // 停止後還要補送幾次 0

static os_unfair_lock pendingLock = OS_UNFAIR_LOCK_INIT;
static uint16_t pendingLeft, pendingRight;
static const char *pendingSource;
static BOOL applyScheduled;

static const uint64_t kResendIntervalMs = 40;
static const unsigned kXboxResendTicks = 7;    // 40ms × 7 = 280ms
static const uint8_t kXboxDuration = 50;       // 單位 10ms = 500ms
static const unsigned kStopRepeats = 3;

static int intProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &result);
    return result;
}

static BOOL isBluetooth(IOHIDDeviceRef device) {
    CFTypeRef transport = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    return transport && CFGetTypeID(transport) == CFStringGetTypeID()
        && CFStringFind(transport, CFSTR("Bluetooth"), 0).location != kCFNotFound;
}

static void deviceAdded(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    int vendor = intProperty(device, CFSTR(kIOHIDVendorIDKey));
    int product = intProperty(device, CFSTR(kIOHIDProductIDKey));
    int outputSize = intProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey));
    RumbleKind kind;
    if (vendor == 0x28DE) {
        // Puck 有一個只收 1 byte 的管理介面，排除
        if (outputSize < 10) return;
        kind = RumbleKindSteam;
        fixLog(@"震動：找到 Steam Controller 介面 28de:%04x", product);
    } else {
        // 只接藍牙的實體 Xbox 手柄；Steam 虛擬手柄（Transport=Virtual）沒有輸出 report
        if (!isBluetooth(device) || outputSize < 9) return;
        kind = RumbleKindXbox;
        fixLog(@"震動：找到藍牙 Xbox 手柄 045e:%04x", product);
    }
    outputDevices[[NSValue valueWithPointer:CFRetain(device)]] = @(kind);
}

static void deviceRemoved(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    NSValue *key = [NSValue valueWithPointer:device];
    if (!outputDevices[key]) return;
    [outputDevices removeObjectForKey:key];
    CFRelease(device);
}

static IOReturn sendSteam(IOHIDDeviceRef device, uint16_t left, uint16_t right) {
    uint8_t report[10] = {0x80, 0, 0, 0, left & 0xff, left >> 8, 0, right & 0xff, right >> 8, 0};
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80, report, sizeof(report));
}

static IOReturn sendXbox(IOHIDDeviceRef device, uint16_t left, uint16_t right) {
    uint8_t low = (left * 100 + 65534) / 65535, high = (right * 100 + 65534) / 65535;  // 無條件進位，微弱震動不會變 0
    uint8_t report[9] = {0x03, 0x0F, 0, 0, low, high, (left || right) ? kXboxDuration : 0, 0, 0};
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x03, report, sizeof(report));
}

/// includeXbox：Xbox 手柄只在震動改變或每 280ms 重送時送，避免塞爆藍牙
static void sendRumble(uint16_t left, uint16_t right, BOOL includeXbox) {
    static IOReturn lastError = kIOReturnSuccess;
    [outputDevices enumerateKeysAndObjectsUsingBlock:^(NSValue *key, NSNumber *kind, BOOL *stop) {
        IOHIDDeviceRef device = key.pointerValue;
        IOReturn rc;
        if (kind.integerValue == RumbleKindSteam) rc = sendSteam(device, left, right);
        else if (includeXbox) rc = sendXbox(device, left, right);
        else return;
        if (rc != kIOReturnSuccess && rc != lastError) fixLog(@"震動：送出失敗 0x%x", rc);
        lastError = rc;
    }];
}

static void setupOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rumbleQueue = dispatch_queue_create("steaminputmac.rumble", DISPATCH_QUEUE_SERIAL);
        outputDevices = [NSMutableDictionary dictionary];
        manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSMutableArray *matching = [NSMutableArray array];
        for (NSNumber *pid in @[@0x1302, @0x1303, @0x1304, @0x1305]) {
            [matching addObject:@{@kIOHIDVendorIDKey: @0x28DE, @kIOHIDProductIDKey: pid}];
        }
        [matching addObject:@{@kIOHIDVendorIDKey: @0x045E,
                              @kIOHIDPrimaryUsagePageKey: @(kHIDPage_GenericDesktop),
                              @kIOHIDPrimaryUsageKey: @(kHIDUsage_GD_GamePad)}];
        IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matching);
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAdded, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, NULL);
        IOHIDManagerSetDispatchQueue(manager, rumbleQueue);
        // 要開啟裝置才能 SetReport（不獨佔，Steam 仍可同時使用手柄）
        IOReturn rc = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        if (rc != kIOReturnSuccess) fixLog(@"震動：無法開啟手柄 0x%x", rc);
        IOHIDManagerActivate(manager);

        resendTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, rumbleQueue);
        dispatch_source_set_timer(resendTimer, DISPATCH_TIME_NOW, kResendIntervalMs * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(resendTimer, ^{
            if (currentLeft || currentRight) {
                sendRumble(currentLeft, currentRight, ++resendTick % kXboxResendTicks == 0);
            } else if (stopRepeats) {
                stopRepeats--;
                sendRumble(0, 0, YES);
            }
        });
        dispatch_activate(resendTimer);
    });
}

/// 在 rumbleQueue 上套用最新的震動值（中間被蓋掉的值直接略過）
static void applyPending(void) {
    os_unfair_lock_lock(&pendingLock);
    uint16_t left = pendingLeft, right = pendingRight;
    const char *source = pendingSource;
    applyScheduled = NO;
    os_unfair_lock_unlock(&pendingLock);

    if (left == currentLeft && right == currentRight) return;
    BOOL wasOn = currentLeft || currentRight;
    currentLeft = left;
    currentRight = right;
    resendTick = 0;
    stopRepeats = (left || right) ? 0 : kStopRepeats;
    sendRumble(left, right, YES);  // 立即送一次；之後由計時器重送，歸零時送 0 讓手柄馬上停
    if (!wasOn || !(left || right)) fixLog(@"震動（%s）：左 %u 右 %u", source, left, right);
}

void steamRumbleSet(uint16_t left, uint16_t right, const char *source) {
    setupOnce();
    os_unfair_lock_lock(&pendingLock);
    pendingLeft = left;
    pendingRight = right;
    pendingSource = source;
    BOOL schedule = !applyScheduled;
    applyScheduled = YES;
    os_unfair_lock_unlock(&pendingLock);
    if (schedule) dispatch_async(rumbleQueue, ^{ applyPending(); });
}
