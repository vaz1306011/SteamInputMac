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
#import "rumble.h"

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

// 虛擬手柄沒有輸出 report，很多函式庫看到 MaxOutputReportSize=0 就不送震動；
// 報成 360Controller 驅動的 8 bytes，讓遊戲照常送出，再由 SetReport 攔下來轉給手柄。
static CFNumberRef spoofedOutputSize(void) {
    static CFNumberRef value;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ int size = 8; value = CFNumberCreate(NULL, kCFNumberIntType, &size); });
    return value;
}

static BOOL keyIs(CFStringRef key, const char *name) {
    return key && CFStringCompare(key, (__bridge CFStringRef)@(name), 0) == kCFCompareEqualTo;
}

static CFTypeRef fix_IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) {
    if (!isSteamClient && keyIs(key, kIOHIDProductKey) && isSteamVirtualGamepad(device)) {
        fixLog(@"Product：Steam 虛擬手柄 → %@", spoofedProductName);
        return spoofedProductName;
    }
    if (!isSteamClient && keyIs(key, kIOHIDMaxOutputReportSizeKey) && isSteamVirtualGamepad(device)) {
        return spoofedOutputSize();
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

// 遊戲送給 Steam 虛擬手柄的輸出（震動等）：虛擬手柄沒有輸出 report，攔下來轉給手柄
static NSString *hexString(const uint8_t *bytes, CFIndex length) {
    NSMutableString *hex = [NSMutableString string];
    for (CFIndex i = 0; i < length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

/// 解析 Xbox 360（360Controller 驅動格式）的震動 report：00 08 00 左 右 00 00 00。
/// hidapi（SDL 內建）在 report ID 為 0 時會拿掉第一個 byte，送出 08 00 左 右 00 00 00。
/// SDL 2.0.x 在 macOS 給 360Controller 驅動用的短格式：00 04 左 右（例：Celeste）。
/// 是震動就轉給 Steam Controller 並回傳 YES；LED 指令（01 03 xx）等直接吞掉。
static BOOL forwardXbox360Rumble(IOHIDReportType type, const uint8_t *report, CFIndex length) {
    if (type != kIOHIDReportTypeOutput || !report) return NO;
    if (length >= 5 && report[0] == 0x00 && report[1] == 0x08) {
        steamRumbleSet(report[3] * 257, report[4] * 257, "HID");
        return YES;
    }
    if (length >= 4 && report[0] == 0x08 && report[1] == 0x00) {
        steamRumbleSet(report[2] * 257, report[3] * 257, "HID");
        return YES;
    }
    if (length == 4 && report[0] == 0x00 && report[1] == 0x04) {
        steamRumbleSet(report[2] * 257, report[3] * 257, "HID");
        return YES;
    }
    // 360Controller 的 LED 指令：虛擬手柄沒有燈，回報成功即可
    if (length == 3 && report[0] == 0x01 && report[1] == 0x03) return YES;
    return NO;
}

static IOReturn fix_IOHIDDeviceSetReport(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                                         const uint8_t *report, CFIndex length) {
    if (!isSteamClient && isSteamVirtualGamepad(device)) {
        if (traceEnabled) fixLog(@"SetReport 虛擬手柄 type=%d id=%ld %@", type, (long)reportID, hexString(report, length));
        if (forwardXbox360Rumble(type, report, length)) return kIOReturnSuccess;
        fixLog(@"SetReport 虛擬手柄（未支援的格式）type=%d id=%ld %@", type, (long)reportID, hexString(report, length));
    }
    return IOHIDDeviceSetReport(device, type, reportID, report, length);
}

static IOReturn fix_IOHIDDeviceSetReportWithCallback(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                                                     const uint8_t *report, CFIndex length, CFTimeInterval timeout,
                                                     IOHIDReportCallback callback, void *context) {
    if (!isSteamClient && isSteamVirtualGamepad(device)) {
        if (traceEnabled) fixLog(@"SetReportWithCallback 虛擬手柄 type=%d id=%ld %@", type, (long)reportID, hexString(report, length));
        if (forwardXbox360Rumble(type, report, length)) {
            if (callback) callback(context, kIOReturnSuccess, device, type, (uint32_t)reportID, (uint8_t *)report, length);
            return kIOReturnSuccess;
        }
        fixLog(@"SetReportWithCallback 虛擬手柄（未支援的格式）type=%d id=%ld %@", type, (long)reportID, hexString(report, length));
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

// MARK: - SDL 的忽略清單
//
// Steam 會把 SDL_GAMECONTROLLER_IGNORE_DEVICES 設成實體手柄清單（讓遊戲只讀虛擬手柄），
// 裡面包含 045e:028e，而 Mac 上的虛擬手柄正好也是 045e:028e。
// 新版 SDL 會先認出 Steam 虛擬手柄再套用清單；SDL 2.0.14 等舊版只認 Linux/Windows 的 28de:11ff，
// 於是把虛擬手柄也忽略掉，遊戲完全讀不到手柄（例：Celeste）。
// → 沒有實體 045e:028e 時，把它從清單拿掉。

static BOOL hasPhysicalXbox360Controller(void) {
    NSDictionary *matching = @{ @kIOProviderClassKey: @kIOHIDDeviceKey,
                                @kIOHIDVendorIDKey: @0x045E, @kIOHIDProductIDKey: @0x028E };
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(MACH_PORT_NULL, (__bridge_retained CFDictionaryRef)matching, &iterator) != KERN_SUCCESS) {
        return NO;
    }
    BOOL found = NO;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef transport = IORegistryEntryCreateCFProperty(service, CFSTR(kIOHIDTransportKey), kCFAllocatorDefault, 0);
        BOOL isVirtual = transport && CFGetTypeID(transport) == CFStringGetTypeID()
            && CFStringCompare(transport, CFSTR("Virtual"), 0) == kCFCompareEqualTo;
        if (transport) CFRelease(transport);
        IOObjectRelease(service);
        if (!isVirtual) found = YES;
    }
    IOObjectRelease(iterator);
    return found;
}

static void allowSteamVirtualGamepadInSDL(void) {
    const char *allow = getenv("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD");
    const char *ignored = getenv("SDL_GAMECONTROLLER_IGNORE_DEVICES");
    if (!allow || strcmp(allow, "1") != 0 || !ignored) return;

    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    BOOL removed = NO;
    for (NSString *entry in [@(ignored) componentsSeparatedByString:@","]) {
        if ([entry caseInsensitiveCompare:@"0x045e/0x028e"] == NSOrderedSame) {
            removed = YES;
        } else {
            [kept addObject:entry];
        }
    }
    if (!removed) return;
    if (hasPhysicalXbox360Controller()) {
        fixLog(@"有實體 045e:028e 手柄，不更動 SDL 忽略清單");
        return;
    }
    setenv("SDL_GAMECONTROLLER_IGNORE_DEVICES", [kept componentsJoinedByString:@","].UTF8String, 1);
    fixLog(@"SDL 忽略清單：拿掉 045e:028e（Steam 虛擬手柄）");
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

    allowSteamVirtualGamepadInSDL();

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
