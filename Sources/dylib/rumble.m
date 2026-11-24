// 震動輸出：把遊戲要的震動直接送給 Steam Controller 2（繞過 Steam）。
// Steam 在 Mac 上建立的虛擬 Xbox 手柄沒有輸出 report，遊戲的震動送不到手柄，所以由這裡代送。
//
// 協定參考 SDL3 src/joystick/hidapi/SDL_hidapi_steam_triton.c：
//   output report 0x80 = MsgHapticRumble { u8 type; u16 intensity; {u16 speed; i8 gain} left, right; }
//   手柄約 50ms 沒收到就停，所以震動期間每 40ms 重送一次。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import "rumble.h"

void fixLog(NSString *format, ...);

static dispatch_queue_t rumbleQueue;
static IOHIDManagerRef manager;
static NSMutableSet *outputDevices;   // 可接收 0x80 的 Steam Controller 介面
static dispatch_source_t resendTimer;
static uint16_t currentLeft, currentRight;

static int intProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &result);
    return result;
}

static void deviceAdded(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    // Puck 有一個只收 1 byte 的管理介面，排除
    if (intProperty(device, CFSTR(kIOHIDMaxOutputReportSizeKey)) < 10) return;
    [outputDevices addObject:(__bridge id)device];
    fixLog(@"震動：找到 Steam Controller 介面 28de:%04x", intProperty(device, CFSTR(kIOHIDProductIDKey)));
}

static void deviceRemoved(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [outputDevices removeObject:(__bridge id)device];
}

static void sendRumble(uint16_t left, uint16_t right) {
    uint8_t report[10] = {0x80, 0, 0, 0, left & 0xff, left >> 8, 0, right & 0xff, right >> 8, 0};
    static IOReturn lastError = kIOReturnSuccess;
    for (id device in outputDevices) {
        IOReturn rc = IOHIDDeviceSetReport((__bridge IOHIDDeviceRef)device, kIOHIDReportTypeOutput, 0x80, report, sizeof(report));
        if (rc != kIOReturnSuccess && rc != lastError) fixLog(@"震動：送出失敗 0x%x", rc);
        lastError = rc;
    }
}

static void setupOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rumbleQueue = dispatch_queue_create("steaminputmac.rumble", DISPATCH_QUEUE_SERIAL);
        outputDevices = [NSMutableSet set];
        manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        NSMutableArray *matching = [NSMutableArray array];
        for (NSNumber *pid in @[@0x1302, @0x1303, @0x1304, @0x1305]) {
            [matching addObject:@{@kIOHIDVendorIDKey: @0x28DE, @kIOHIDProductIDKey: pid}];
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matching);
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAdded, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemoved, NULL);
        IOHIDManagerSetDispatchQueue(manager, rumbleQueue);
        // 要開啟裝置才能 SetReport（不獨佔，Steam 仍可同時使用手柄）
        IOReturn rc = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
        if (rc != kIOReturnSuccess) fixLog(@"震動：無法開啟手柄 0x%x", rc);
        IOHIDManagerActivate(manager);

        resendTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, rumbleQueue);
        dispatch_source_set_timer(resendTimer, DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(resendTimer, ^{
            if (currentLeft || currentRight) sendRumble(currentLeft, currentRight);
        });
        dispatch_activate(resendTimer);
    });
}

void steamRumbleSet(uint16_t left, uint16_t right, const char *source) {
    setupOnce();
    dispatch_async(rumbleQueue, ^{
        if (left == currentLeft && right == currentRight) return;
        BOOL wasOn = currentLeft || currentRight;
        currentLeft = left;
        currentRight = right;
        sendRumble(left, right);  // 立即送一次；之後由計時器重送，歸零時送 0 讓手柄馬上停
        if (!wasOn || !(left || right)) fixLog(@"震動（%s）：左 %u 右 %u", source, left, right);
    });
}
