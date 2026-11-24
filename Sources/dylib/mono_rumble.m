// Mono（Unity）遊戲的震動轉接。兩種情況，震動都在遊戲內部就消失，系統層攔不到：
//
// 1. Unity Input System：Gamepad.SetMotorSpeeds 會送 'RMBL' IOCTL 給 UnityPlayer 原生層，
//    原生層不支援 Steam 的虛擬手柄，指令就消失了（例：Hollow Knight: Silksong，
//    經 InControl 的 NewUnityInputDevice）。
//    → UnityPlayer 用 dlsym 取得 mono_add_internal_call，攔截後把
//      NativeInputSystem::IOCTL 換成包裝函式；原生層回報失敗時才轉給 Steam Controller。
//
// 2. InControl + Unity 舊式搖桿輸入：InputDevice.Vibrate() 是空函式。
//    → 讓 Mono 載入我們的 profiler，JIT 編譯完 InputDevice.Vibrate 時確認它是空函式
//      （IL 只有 ret），把機器碼開頭換成跳到 hook；浮點參數照 managed 呼叫慣例放在
//      s0/s1（arm64）或 xmm0/xmm1（x86_64）。有自己實作震動的子類別不受影響。
//      （不用 profiler 的 call context 讀參數：Unity 在 arm64 的 Mono 讀浮點參數會當掉。）
//    profiler 要在 Mono 啟動時載入：攔截 mono_jit_init_version，在初始化前呼叫
//    mono_jit_parse_options("--profile=steaminputmac")。
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <pthread.h>
#import <libkern/OSCacheControl.h>
#import "rumble.h"

void fixLog(NSString *format, ...);
extern BOOL isSteamClient;

typedef void MonoMethod, MonoClass, MonoJitInfo, MonoMethodSignature, MonoMethodHeader, MonoType, *MonoProfilerHandle;
typedef struct _MonoProfiler { int unused; } MonoProfiler;

enum { MONO_TYPE_R4 = 0x0c, IL_NOP = 0x00, IL_RET = 0x2a };

static struct {
    MonoProfilerHandle (*profiler_create)(MonoProfiler *);
    void (*set_jit_done)(MonoProfilerHandle, void (*)(MonoProfiler *, MonoMethod *, MonoJitInfo *));
    void *(*jit_info_code_start)(MonoJitInfo *);
    int (*jit_info_code_size)(MonoJitInfo *);
    const char *(*method_get_name)(MonoMethod *);
    MonoClass *(*method_get_class)(MonoMethod *);
    MonoMethodSignature *(*method_signature)(MonoMethod *);
    MonoMethodHeader *(*method_get_header)(MonoMethod *);
    const uint8_t *(*header_get_code)(MonoMethodHeader *, uint32_t *, uint32_t *);
    void (*free_header)(MonoMethodHeader *);
    uint32_t (*signature_param_count)(MonoMethodSignature *);
    MonoType *(*signature_get_params)(MonoMethodSignature *, void **);
    int (*type_get_type)(MonoType *);
    const char *(*class_get_name)(MonoClass *);
    const char *(*class_get_namespace)(MonoClass *);
} mono;

static MonoProfiler profiler;

static BOOL loadMonoAPI(void) {
#define LOAD(field, name) if (!(*(void **)&mono.field = dlsym(RTLD_DEFAULT, name))) { fixLog(@"InControl 轉接：找不到 %s", name); return NO; }
    LOAD(profiler_create, "mono_profiler_create");
    LOAD(set_jit_done, "mono_profiler_set_jit_done_callback");
    LOAD(jit_info_code_start, "mono_jit_info_get_code_start");
    LOAD(jit_info_code_size, "mono_jit_info_get_code_size");
    LOAD(method_get_name, "mono_method_get_name");
    LOAD(method_get_class, "mono_method_get_class");
    LOAD(method_signature, "mono_method_signature");
    LOAD(method_get_header, "mono_method_get_header");
    LOAD(header_get_code, "mono_method_header_get_code");
    LOAD(free_header, "mono_metadata_free_mh");
    LOAD(signature_param_count, "mono_signature_get_param_count");
    LOAD(signature_get_params, "mono_signature_get_params");
    LOAD(type_get_type, "mono_type_get_type");
    LOAD(class_get_name, "mono_class_get_name");
    LOAD(class_get_namespace, "mono_class_get_namespace");
#undef LOAD
    return YES;
}

// MARK: - hook：取代 InputDevice.Vibrate 的空函式

static uint16_t motorSpeed(float strength) {
    if (!(strength > 0)) return 0;  // 也擋掉 NaN
    return strength >= 1 ? 65535 : (uint16_t)(strength * 65535);
}

static void hookVibrate2(void *self, float left, float right) {
    steamRumbleSet(motorSpeed(left), motorSpeed(right), "InControl");
}

static void hookVibrate1(void *self, float intensity) {
    hookVibrate2(self, intensity, intensity);
}

// MARK: - 改寫 JIT 機器碼

// Apple Silicon 的 JIT 記憶體每個執行緒各自切換可寫／可執行。Mono 直接呼叫
// pthread_jit_write_protect_np，這裡攔截以記錄目前狀態，改寫後還原，避免打亂 Mono。
static __thread int jitWritable;

static void fix_pthread_jit_write_protect_np(int enabled) {
    jitWritable = !enabled;
    pthread_jit_write_protect_np(enabled);
}

static size_t branchPatch(uint8_t *patch, const void *target) {
#if defined(__arm64__)
    const uint32_t code[] = {0x58000050, 0xd61f0200};  // ldr x16, #8 ; br x16
    memcpy(patch, code, sizeof(code));
    memcpy(patch + 8, &target, 8);
    return 16;
#elif defined(__x86_64__)
    patch[0] = 0x48; patch[1] = 0xb8;  // movabs rax, imm64
    memcpy(patch + 2, &target, 8);
    patch[10] = 0xff; patch[11] = 0xe0;  // jmp rax
    return 12;
#endif
}

static BOOL writeCode(uint8_t *code, const uint8_t *patch, size_t length) {
#if defined(__arm64__)
    int wasWritable = jitWritable;
    if (!wasWritable) pthread_jit_write_protect_np(0);
    memcpy(code, patch, length);
    if (!wasWritable) pthread_jit_write_protect_np(1);
#else
    memcpy(code, patch, length);
#endif
    sys_icache_invalidate(code, length);
    return YES;
}

// MARK: - 判斷要不要替換

/// IL 只有 nop + ret，也就是空函式
static BOOL isEmptyMethod(MonoMethod *method) {
    MonoMethodHeader *header = mono.method_get_header(method);
    if (!header) return NO;
    uint32_t size = 0, maxStack = 0;
    const uint8_t *il = mono.header_get_code(header, &size, &maxStack);
    BOOL empty = il && size > 0 && il[size - 1] == IL_RET;
    for (uint32_t i = 0; empty && i + 1 < size; i++) empty = il[i] == IL_NOP;
    mono.free_header(header);
    return empty;
}

static BOOL allFloatParams(MonoMethodSignature *signature) {
    void *iter = NULL;
    MonoType *type;
    while ((type = mono.signature_get_params(signature, &iter))) {
        if (mono.type_get_type(type) != MONO_TYPE_R4) return NO;
    }
    return YES;
}

static void jitDone(MonoProfiler *prof, MonoMethod *method, MonoJitInfo *jitInfo) {
    if (strcmp(mono.method_get_name(method), "Vibrate") != 0) return;
    MonoClass *klass = mono.method_get_class(method);
    if (strcmp(mono.class_get_name(klass), "InputDevice") != 0
        || strcmp(mono.class_get_namespace(klass), "InControl") != 0) return;

    MonoMethodSignature *signature = mono.method_signature(method);
    uint32_t params = mono.signature_param_count(signature);
    if ((params != 1 && params != 2) || !allFloatParams(signature)) return;
    if (!isEmptyMethod(method)) {
        fixLog(@"InControl 轉接：InputDevice.Vibrate（%u 個參數）不是空函式，不替換", params);
        return;
    }

    uint8_t patch[16];
    size_t length = branchPatch(patch, params == 2 ? (void *)hookVibrate2 : (void *)hookVibrate1);
    uint8_t *code = mono.jit_info_code_start(jitInfo);
    if (!code || mono.jit_info_code_size(jitInfo) < (int)length) {
        fixLog(@"InControl 轉接：InputDevice.Vibrate 機器碼太短，不替換");
        return;
    }
    writeCode(code, patch, length);
    fixLog(@"InControl 轉接：已替換 InputDevice.Vibrate（%u 個參數）", params);
}

// Mono 啟動時由 --profile=steaminputmac 呼叫（Mono 在主程式與已載入的函式庫裡找這個符號）
__attribute__((visibility("default")))
void mono_profiler_init_steaminputmac(const char *options) {
    if (!loadMonoAPI()) return;
    MonoProfilerHandle handle = mono.profiler_create(&profiler);
    mono.set_jit_done(handle, jitDone);
    fixLog(@"InControl 轉接：Mono profiler 已安裝");
}

// MARK: - Unity Input System：NativeInputSystem::IOCTL

// Input System 的 FourCC：'RMBL' = DualMotorRumbleCommand，payload 為 float low, float high
static const int kRumbleCommand = ('R' << 24) | ('M' << 16) | ('B' << 8) | 'L';

typedef int64_t (*IOCTLFn)(int deviceId, int code, void *data, int sizeInBytes);
static IOCTLFn originalIOCTL;

static int64_t wrappedIOCTL(int deviceId, int code, void *data, int sizeInBytes) {
    int64_t result = originalIOCTL(deviceId, code, data, sizeInBytes);
    if (code == kRumbleCommand && result < 0 && data && sizeInBytes >= 8) {
        // 原生層不支援這個裝置的震動（Steam 虛擬手柄）→ 改送給 Steam Controller
        const float *speeds = (const float *)((uint8_t *)data + (sizeInBytes >= 16 ? 8 : 0));
        steamRumbleSet(motorSpeed(speeds[0]), motorSpeed(speeds[1]), "Unity Input System");
        return 0;
    }
    return result;
}

static void (*originalAddInternalCall)(const char *, const void *);

static void wrappedAddInternalCall(const char *name, const void *function) {
    if (name && strcmp(name, "UnityEngineInternal.Input.NativeInputSystem::IOCTL") == 0) {
        originalIOCTL = (IOCTLFn)function;
        function = (const void *)wrappedIOCTL;
        fixLog(@"Unity Input System 轉接：已攔截 NativeInputSystem::IOCTL");
    }
    originalAddInternalCall(name, function);
}

// MARK: - 在 Mono 初始化前插入 --profile

static void *(*originalJitInitVersion)(const char *, const char *);
static void (*jitParseOptions)(int, char **);

static void *wrappedJitInitVersion(const char *domainName, const char *runtimeVersion) {
    if (jitParseOptions) {
        static char option[] = "--profile=steaminputmac";
        char *argv[] = {option, NULL};
        jitParseOptions(1, argv);
    }
    return originalJitInitVersion(domainName, runtimeVersion);
}

static void *fix_dlsym(void *handle, const char *symbol) {
    void *result = dlsym(handle, symbol);
    if (isSteamClient || !result || !symbol || strncmp(symbol, "mono_", 5) != 0) return result;
    if (strcmp(symbol, "mono_add_internal_call") == 0) {
        originalAddInternalCall = result;
        return (void *)wrappedAddInternalCall;
    }
    if (strcmp(symbol, "mono_jit_init_version") == 0) {
        originalJitInitVersion = result;
        jitParseOptions = dlsym(handle, "mono_jit_parse_options");
        fixLog(@"InControl 轉接：偵測到 Mono，將載入 profiler");
        return (void *)wrappedJitInitVersion;
    }
    return result;
}

typedef struct { const void *replacement; const void *original; } Interpose;
__attribute__((used, section("__DATA,__interpose")))
static const Interpose monoInterposers[] = {
    { (const void *)fix_dlsym, (const void *)dlsym },
    { (const void *)fix_pthread_jit_write_protect_np, (const void *)pthread_jit_write_protect_np },
};
