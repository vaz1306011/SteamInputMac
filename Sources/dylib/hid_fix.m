// SteamInputMac：注入遊戲的 dylib，讓遊戲讀得到 Steam Input 建立的虛擬 Xbox 360 手柄。
//
// Steam 在 macOS 上用虛擬 HID 裝置 GamePad-1（045e:028e，Transport=Virtual）輸出手柄訊號，
// 回報格式與 360Controller 驅動相同，但遊戲常常認不得它：
//
// 1. 名稱：Unity 用「Manufacturer Product」當搖桿名稱 → "Microsoft GamePad-1"，
//    InControl 等函式庫靠名稱比對設定檔，對不上就忽略。→ 把 Product 改報成 Xbox 360 有線手柄。
//    （Hollow Knight: Silksong 就是這種情況。）
// 2. GameController：+[GCController supportsHIDDevice:] 對它回傳 YES，用這個 API 分流的函式庫會跳過它，
//    但 macOS 的 Xbox 360 personality 沒有 GCIOMatchVirtual，GameController 不會接手。→ 改回傳 NO。
//
// 設 STEAMINPUTMAC_TRACE=1 可把遊戲對 IOHID 的呼叫記到 ~/Library/Logs/SteamInputMac.log。
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>
#import <objc/runtime.h>
#import <dlfcn.h>

void installSpawnInjection(void);
extern BOOL isSteamClient;  // 在 Steam 用戶端裡只負責把修正帶給遊戲，不改 HID

static BOOL (*originalSupportsHIDDevice)(id, SEL, IOHIDDeviceRef);
static FILE *logFile;

void fixLog(NSString *format, ...) {
    if (!logFile) return;
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(logFile, "[%s] %s\n", getprogname(), message.UTF8String);
    fflush(logFile);
}

static int intProperty(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    int result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberIntType, &result);
    }
    return result;
}

static BOOL isSteamVirtualGamepad(IOHIDDeviceRef device) {
    CFTypeRef transport = IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    BOOL isVirtual = transport && CFGetTypeID(transport) == CFStringGetTypeID()
        && CFStringCompare(transport, CFSTR("Virtual"), 0) == kCFCompareEqualTo;
    return isVirtual
        && intProperty(device, CFSTR(kIOHIDVendorIDKey)) == 0x045E
        && intProperty(device, CFSTR(kIOHIDProductIDKey)) == 0x028E;
}

// MARK: - 追蹤遊戲對 IOHID 的呼叫（設 STEAMINPUTMAC_TRACE=1 開啟）

static BOOL traceEnabled;

static NSString *describeDevice(IOHIDDeviceRef device) {
    return [NSString stringWithFormat:@"%04x:%04x",
            intProperty(device, CFSTR(kIOHIDVendorIDKey)), intProperty(device, CFSTR(kIOHIDProductIDKey))];
}

// Unity 用「Manufacturer Product」當搖桿名稱，InControl 再用名稱比對設定檔。
// Steam 給的是 "Microsoft GamePad-1"，沒有任何設定檔認得；改報成 Xbox 360 有線手柄的名稱。
static CFStringRef const spoofedProductName = CFSTR("Xbox 360 Wired Controller");

static CFTypeRef fix_IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
    if (!isSteamClient && key && CFStringCompare(key, CFSTR(kIOHIDProductKey), 0) == kCFCompareEqualTo
        && isSteamVirtualGamepad(device)) {
        fixLog(@"Product：Steam 虛擬手柄 → %@", spoofedProductName);
        return spoofedProductName;
    }
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (traceEnabled) fixLog(@"GetProperty %@ %@ = %@", describeDevice(device), key, value);
    return value;
}

static CFArrayRef fix_IOHIDDeviceCopyMatchingElements(IOHIDDeviceRef device, CFDictionaryRef matching, IOOptionBits options) {
    if (traceEnabled) fixLog(@"CopyMatchingElements %@（遊戲接受了這個裝置）", describeDevice(device));
    return IOHIDDeviceCopyMatchingElements(device, matching, options);
}

static void fix_IOHIDManagerSetDeviceMatchingMultiple(IOHIDManagerRef manager, CFArrayRef multiple) {
    if (traceEnabled) fixLog(@"SetDeviceMatchingMultiple %@", multiple);
    IOHIDManagerSetDeviceMatchingMultiple(manager, multiple);
}

// 遊戲送給 Steam 虛擬手柄的輸出（震動等）：虛擬手柄沒有輸出 report，這裡先記錄下來
static NSString *hexString(const uint8_t *bytes, CFIndex length) {
    NSMutableString *hex = [NSMutableString string];
    for (CFIndex i = 0; i < length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static IOReturn fix_IOHIDDeviceSetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                                         const uint8_t *report, CFIndex length) {
    if (isSteamVirtualGamepad(device)) {
        fixLog(@"SetReport 虛擬手柄 type=%d id=%ld %@", type, (long)reportID, hexString(report, length));
    }
    return IOHIDDeviceSetReport(device, type, reportID, report, length);
}

static IOReturn fix_IOHIDDeviceSetReportWithCallback(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                                                     const uint8_t *report, CFIndex length, CFTimeInterval timeout,
                                                     IOHIDReportCallback callback, void *context) {
    if (isSteamVirtualGamepad(device)) {
        fixLog(@"SetReportWithCallback 虛擬手柄 type=%d id=%ld %@", type, (long)reportID, hexString(report, length));
    }
    return IOHIDDeviceSetReportWithCallback(device, type, reportID, report, length, timeout, callback, context);
}

static IOReturn fix_IOHIDDeviceSetValue(IOHIDDeviceRef device, IOHIDElementRef element, IOHIDValueRef value) {
    if (isSteamVirtualGamepad(device)) {
        fixLog(@"SetValue 虛擬手柄 usage=%x:%x value=%ld", IOHIDElementGetUsagePage(element),
               IOHIDElementGetUsage(element), (long)IOHIDValueGetIntegerValue(value));
    }
    return IOHIDDeviceSetValue(device, element, value);
}

typedef struct { const void *replacement; const void *original; } Interpose;
__attribute__((used, section("__DATA,__interpose")))
static const Interpose interposers[] = {
    { (const void *)fix_IOHIDDeviceGetProperty, (const void *)IOHIDDeviceGetProperty },
    { (const void *)fix_IOHIDDeviceCopyMatchingElements, (const void *)IOHIDDeviceCopyMatchingElements },
    { (const void *)fix_IOHIDManagerSetDeviceMatchingMultiple, (const void *)IOHIDManagerSetDeviceMatchingMultiple },
    { (const void *)fix_IOHIDDeviceSetReport, (const void *)IOHIDDeviceSetReport },
    { (const void *)fix_IOHIDDeviceSetReportWithCallback, (const void *)IOHIDDeviceSetReportWithCallback },
    { (const void *)fix_IOHIDDeviceSetValue, (const void *)IOHIDDeviceSetValue },
};

static BOOL hookedSupportsHIDDevice(id self, SEL _cmd, IOHIDDeviceRef device) {
    if (traceEnabled) fixLog(@"supportsHIDDevice %@", describeDevice(device));
    if (device && isSteamVirtualGamepad(device)) {
        fixLog(@"supportsHIDDevice: Steam 虛擬手柄 → NO（交給遊戲自己讀）");
        return NO;
    }
    return originalSupportsHIDDevice(self, _cmd, device);
}

__attribute__((constructor))
static void installHook(void) {
    NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/SteamInputMac.log"];
    logFile = fopen(logPath.fileSystemRepresentation, "a");
    // 環境變數或開關檔案都能開追蹤（從 Steam 開的遊戲不方便設環境變數）
    NSString *traceFlag = [NSHomeDirectory() stringByAppendingPathComponent:@".local/share/steaminputmac/trace"];
    traceEnabled = getenv("STEAMINPUTMAC_TRACE") != NULL
        || [[NSFileManager defaultManager] fileExistsAtPath:traceFlag];
    installSpawnInjection();
    if (isSteamClient) return;

    // 遊戲的輸入外掛可能比我們晚載入 GameController，先主動載入以便 hook。
    dlopen("/System/Library/Frameworks/GameController.framework/GameController", RTLD_LAZY);
    Class gcController = NSClassFromString(@"GCController");
    Method method = gcController ? class_getClassMethod(gcController, @selector(supportsHIDDevice:)) : NULL;
    if (!method) {
        fixLog(@"找不到 +[GCController supportsHIDDevice:]，未安裝 hook");
        return;
    }
    originalSupportsHIDDevice = (BOOL (*)(id, SEL, IOHIDDeviceRef))method_setImplementation(method, (IMP)hookedSupportsHIDDevice);
    fixLog(@"hook 已安裝");
}
