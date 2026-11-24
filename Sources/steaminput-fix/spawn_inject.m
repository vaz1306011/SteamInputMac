// 在 Steam 用戶端（steam_osx）裡攔截啟動遊戲的呼叫，自動把 steaminput-fix 加進遊戲的
// DYLD_INSERT_LIBRARIES（與 Steam 自己的內嵌介面 gameoverlayrenderer.dylib 並存）。
// 這樣所有 Steam 遊戲都不用個別設啟動選項。
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>

void fixLog(NSString *format, ...);

static const char *const kInsertKey = "DYLD_INSERT_LIBRARIES=";
static char fixDylibPath[PATH_MAX];

static BOOL envHas(char *const envp[], const char *prefix) {
    for (size_t i = 0; envp && envp[i]; i++) {
        if (strncmp(envp[i], prefix, strlen(prefix)) == 0) return YES;
    }
    return NO;
}

/// 判斷這次 spawn 是不是 Steam 在啟動遊戲：Steam 會帶 SteamGameId / SteamAppId，
/// 或在 DYLD_INSERT_LIBRARIES 放內嵌介面。
static BOOL isGameLaunch(char *const envp[]) {
    if (envHas(envp, "SteamGameId=") || envHas(envp, "SteamAppId=")) return YES;
    for (size_t i = 0; envp && envp[i]; i++) {
        if (strncmp(envp[i], kInsertKey, strlen(kInsertKey)) == 0
            && strstr(envp[i], "gameoverlayrenderer")) return YES;
    }
    return NO;
}

/// dylib 還在才注入：解除安裝後若 Steam 仍在修正模式執行，DYLD_INSERT_LIBRARIES 指向不存在的檔案會讓遊戲無法啟動。
static BOOL fixAvailable(void) {
    return fixDylibPath[0] && access(fixDylibPath, R_OK) == 0;
}

/// 回傳加上 steaminput-fix 的新 envp（呼叫端負責 free），不需要時回傳 NULL。
static char **envWithFix(const char *path, char *const envp[]) {
    if (!envp || !isGameLaunch(envp) || !fixAvailable()) return NULL;

    size_t count = 0;
    while (envp[count]) count++;
    char **result = calloc(count + 2, sizeof(char *));
    BOOL found = NO;
    for (size_t i = 0; i < count; i++) {
        if (strncmp(envp[i], kInsertKey, strlen(kInsertKey)) == 0) {
            found = YES;
            if (strstr(envp[i], fixDylibPath)) {
                result[i] = strdup(envp[i]);
            } else {
                asprintf(&result[i], "%s:%s", envp[i], fixDylibPath);
            }
        } else {
            result[i] = strdup(envp[i]);
        }
    }
    if (!found) asprintf(&result[count], "%s%s", kInsertKey, fixDylibPath);
    fixLog(@"Steam 啟動遊戲：%s，已加入 steaminput-fix", path);
    return result;
}

static void freeEnv(char **env) {
    if (!env) return;
    for (size_t i = 0; env[i]; i++) free(env[i]);
    free(env);
}

static int fix_posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                           const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char **env = envWithFix(path, envp);
    int result = posix_spawn(pid, path, actions, attr, argv, env ? env : envp);
    freeEnv(env);
    return result;
}

static int fix_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                            const posix_spawnattr_t *attr, char *const argv[], char *const envp[]) {
    char **env = envWithFix(file, envp);
    int result = posix_spawnp(pid, file, actions, attr, argv, env ? env : envp);
    freeEnv(env);
    return result;
}

static int fix_execve(const char *path, char *const argv[], char *const envp[]) {
    char **env = envWithFix(path, envp);
    int result = execve(path, argv, env ? env : envp);
    freeEnv(env);  // 只有 execve 失敗才會走到這裡
    return result;
}

typedef struct { const void *replacement; const void *original; } Interpose;
__attribute__((used, section("__DATA,__interpose")))
static const Interpose spawnInterposers[] = {
    { (const void *)fix_posix_spawn, (const void *)posix_spawn },
    { (const void *)fix_posix_spawnp, (const void *)posix_spawnp },
    { (const void *)fix_execve, (const void *)execve },
};

// Steam 開 .app 遊戲是透過 NSWorkspace（LaunchServices），環境變數放在 configuration 裡。

/// 遊戲的環境變數補上 steaminput-fix；不是遊戲就回傳 nil。
static NSDictionary *gameEnvWithFix(NSDictionary *env, NSURL *url) {
    if (!(env[@"SteamGameId"] || env[@"SteamAppId"]) || !fixAvailable()) return nil;
    NSString *fix = @(fixDylibPath);
    NSString *existing = env[@"DYLD_INSERT_LIBRARIES"];
    if ([existing containsString:fix]) return nil;
    NSMutableDictionary *newEnv = [env mutableCopy];
    newEnv[@"DYLD_INSERT_LIBRARIES"] = existing.length ? [existing stringByAppendingFormat:@":%@", fix] : fix;
    fixLog(@"Steam 啟動遊戲：%@，已加入 steaminput-fix", url.path);
    return newEnv;
}

// 舊 API：Steam 目前用的是這個（已棄用，但得 hook 它）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static id (*originalLaunchApp)(id, SEL, NSURL *, NSWorkspaceLaunchOptions, NSDictionary *, NSError **);
static id hookedLaunchApp(id self, SEL _cmd, NSURL *url, NSWorkspaceLaunchOptions options,
                          NSDictionary *config, NSError **error) {
    NSDictionary *newEnv = gameEnvWithFix(config[NSWorkspaceLaunchConfigurationEnvironment], url);
    if (newEnv) {
        NSMutableDictionary *newConfig = [config mutableCopy];
        newConfig[NSWorkspaceLaunchConfigurationEnvironment] = newEnv;
        config = newConfig;
    }
    return originalLaunchApp(self, _cmd, url, options, config, error);
}
#pragma clang diagnostic pop

// 新 API：以防 Steam 之後改用
static void (*originalOpenApp)(id, SEL, NSURL *, NSWorkspaceOpenConfiguration *, id);
static void hookedOpenApp(id self, SEL _cmd, NSURL *url, NSWorkspaceOpenConfiguration *config, id handler) {
    NSDictionary *newEnv = gameEnvWithFix(config.environment, url);
    if (newEnv) config.environment = newEnv;
    originalOpenApp(self, _cmd, url, config, handler);
}

static void swizzle(SEL selector, IMP replacement, IMP *original) {
    Method m = class_getInstanceMethod(NSClassFromString(@"NSWorkspace"), selector);
    if (m) *original = method_setImplementation(m, replacement);
    else fixLog(@"找不到 NSWorkspace %@", NSStringFromSelector(selector));
}

BOOL isSteamClient;

void installSpawnInjection(void) {
    Dl_info info;
    if (dladdr((const void *)installSpawnInjection, &info) && info.dli_fname) {
        strlcpy(fixDylibPath, info.dli_fname, sizeof(fixDylibPath));
    }
    isSteamClient = strcmp(getprogname(), "steam_osx") == 0;
    if (!isSteamClient) return;

    // Steam 自己的子程序（Steam Helper 等）不需要這個 dylib；遊戲由上面的 hook 另外加。
    unsetenv("DYLD_INSERT_LIBRARIES");
    swizzle(@selector(launchApplicationAtURL:options:configuration:error:), (IMP)hookedLaunchApp, (IMP *)&originalLaunchApp);
    swizzle(@selector(openApplicationAtURL:configuration:completionHandler:), (IMP)hookedOpenApp, (IMP *)&originalOpenApp);
    fixLog(@"已注入 Steam 用戶端，之後啟動的遊戲都會自動套用");
}
