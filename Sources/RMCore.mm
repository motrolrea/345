#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE 1
//
//  RizlineMod —— 《律动轨迹》iOS 2.7.1 (com.leiting.ldgj) 注入型 mod 核心
//  适用于已解密（cryptid=0）的 UnityFramework + 未签名 / TrollStore 安装环境
//
//  本版本不改代码页，全部通过 il2cpp 反射 + 字段写入实现：
//    InLevel.NoteJudgeControl.AutoPlay / FreeHold     自动打歌（官方 AutoPlay）
//    Normal/Challenge/Weekly 关卡控制器 _life          锁血
//    Normal/Challenge _noBad                           无 Bad
//    ModsControl.<AutoPlay/NoBad/FreeHold>             官方 Mod 状态（用于结算标记）
//    PaymentService.ownedTracks / vipTracks            全曲本地解锁
//

#import "RMCommon.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <os/lock.h>
#include <signal.h>
#include <ucontext.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------
bool RMAutoPlay = true;
bool RMAutoDemo = false;
bool RMNoBad = false;
bool RMFreeHold = false;
bool RMLockHP = false;
bool RMUnlockAllSongs = false;

volatile double RMLastGameplayTick = 0;
bool RMBallVisible = true;
bool RMAutoHideInGame = true;
float RMBallAlpha = 0.85f;
float RMBallSize = 56.0f;

volatile int RMLastNoteCount = -1;
volatile int RMLastLevelIdCount = -1;
volatile bool RMIl2CppReady = false;
volatile bool RMUnlockAllApplied = false;
volatile bool RMInLevel = false;
volatile bool RMGameReady = false;

// 关键字段偏移（2.7.1 Il2CppDumper，UUID 41d3a6b76c0d3f01a6cb0ddd615f3156）
static const size_t kOff_Info_NoteJudge       = 0x58;
static const size_t kOff_Info_LevelBegan      = 0xCF;
static const size_t kOff_Info_LevelOver       = 0xD0;
static const size_t kOff_Judge_FreeHold       = 0x89;
static const size_t kOff_Judge_AutoPlay       = 0x8A;
static const size_t kOff_Judge_Notes          = 0x40;
static const size_t kOff_Normal_Life          = 0x44;
static const size_t kOff_Normal_Damage        = 0x88;
static const size_t kOff_Normal_NoBad         = 0x24C;
static const size_t kOff_Normal_AutoPlayField = 0x258;
static const size_t kOff_Challenge_Life       = 0x40;
static const size_t kOff_Challenge_NoFail     = 0x160;
static const size_t kOff_Challenge_NoBad      = 0x161;
static const size_t kOff_Weekly_Life          = 0x23C;
static const size_t kOff_Weekly_Damage        = 0x240;

static const size_t kOff_List_Items   = 0x10;
static const size_t kOff_List_Size    = 0x18;
static const size_t kOff_Array_Elements = 0x20;
static const size_t kOff_Boxed_Value  = 0x10;
static const size_t kOff_User_Items   = 0x58;   // User.getItems
static const size_t kOff_User_Levels  = 0x70;   // User.unlockedLevels
static const size_t kOff_Item_AssetId = 0x10;   // OwnedItemInfo.itemAssetId
static const size_t kOff_Item_Amount  = 0x18;   // OwnedItemInfo.amount

static void **rm_list_items(void *list, int *outSize) {
    if (!list) return NULL;
    void *arr = *(void **)((char *)list + kOff_List_Items);
    int size = *(int *)((char *)list + kOff_List_Size);
    if (!arr || size < 0 || size > 200000) return NULL;
    if (outSize) *outSize = size;
    return (void **)((char *)arr + kOff_Array_Elements);
}

// ---------------------------------------------------------------------------
// 日志：NSLog + 文件（Documents/RizlineMod.log，超过 2MB 自动清空）
// ---------------------------------------------------------------------------
static os_unfair_lock gLogLock = OS_UNFAIR_LOCK_INIT;
static NSString *gLogPath = nil;

static NSString *RMLogPath(void) {
    if (gLogPath) return gLogPath;
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = dirs.count ? dirs[0] : NSTemporaryDirectory();
    gLogPath = [dir stringByAppendingPathComponent:@"RizlineMod.log"];
    return gLogPath;
}

static void rm_log_write(NSString *line) {
    os_unfair_lock_lock(&gLogLock);
    @autoreleasepool {
        NSString *path = RMLogPath();
        NSFileManager *fm = NSFileManager.defaultManager;
        NSUInteger limit = 2 * 1024 * 1024;
        if ([fm fileExistsAtPath:path]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
            if ([attrs[NSFileSize] unsignedLongLongValue] > limit) {
                [fm removeItemAtPath:path error:NULL];
            }
        }
        if (![fm fileExistsAtPath:path]) {
            [[line stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            } @catch (NSException *e) {
            }
        }
    }
    os_unfair_lock_unlock(&gLogLock);
}

static NSString *rm_timestamp(void) {
    struct tm t;
    time_t now = time(NULL);
    localtime_r(&now, &t);
    char buf[32];
    snprintf(buf, sizeof(buf), "%02d:%02d:%02d", t.tm_hour, t.tm_min, t.tm_sec);
    return [NSString stringWithUTF8String:buf];
}

void RMLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[RizlineMod] %@", msg);
    rm_log_write([NSString stringWithFormat:@"%@ [%@] %@", rm_timestamp(), NSThread.currentThread.name ?: @"?", msg]);
}

NSString *RMLogTail(NSUInteger maxLines) {
    os_unfair_lock_lock(&gLogLock);
    NSString *content = [NSString stringWithContentsOfFile:RMLogPath() encoding:NSUTF8StringEncoding error:NULL];
    os_unfair_lock_unlock(&gLogLock);
    if (!content.length) return @"(还没有日志)";
    if (maxLines == 0) return content;
    NSArray<NSString *> *lines = [content componentsSeparatedByString:@"\n"];
    if (lines.count <= maxLines) return content;
    return [[lines subarrayWithRange:NSMakeRange(lines.count - maxLines, maxLines)] componentsJoinedByString:@"\n"];
}

void RMLogClear(void) {
    os_unfair_lock_lock(&gLogLock);
    [NSFileManager.defaultManager removeItemAtPath:RMLogPath() error:NULL];
    os_unfair_lock_unlock(&gLogLock);
}

void RMLogReset(void) { RMLogClear(); }

static void rm_uncaught_handler(NSException *e) {
    RMLog(@"💥 未捕获异常 %@: %@\n%@", e.name, e.reason, [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

static char gLogPathC[1024] = {0};

static void rm_signal_handler(int sig, siginfo_t *info, void *uctx) {
    uintptr_t pc = 0, lr = 0, far = 0;
    ucontext_t *uc = (ucontext_t *)uctx;
    if (uc) {
        pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
        lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
        far = (uintptr_t)uc->uc_mcontext->__es.__far;
    }
    char buf[256];
    int n = snprintf(buf, sizeof(buf), "\n[CRASH] sig=%d pc=%p lr=%p far=%p\n",
                     sig, (void *)pc, (void *)lr, (void *)far);
    if (n > 0 && gLogPathC[0]) {
        int fd = open(gLogPathC, O_WRONLY | O_APPEND | O_CREAT, 0644);
        if (fd >= 0) {
            write(fd, buf, (size_t)n);
            close(fd);
        }
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void RMLogInstallCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&rm_uncaught_handler);
    strncpy(gLogPathC, [RMLogPath() fileSystemRepresentation], sizeof(gLogPathC) - 1);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = rm_signal_handler;
    sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    Dl_info dli;
    if (dladdr((void *)&rm_signal_handler, &dli) && dli.dli_fbase) {
        RMLog(@"本模块 base=%p, main base=%p", dli.dli_fbase, _dyld_get_image_header(0));
    }
    RMLog(@"日志文件: %@", RMLogPath());
}

// ---------------------------------------------------------------------------
// UnityFramework 基址 / Mach-O 信息
// ---------------------------------------------------------------------------
static uintptr_t gUnityBase = 0;

void *RMUnityBase(void) {
    if (gUnityBase) return (void *)gUnityBase;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            gUnityBase = (uintptr_t)_dyld_get_image_header(i);
            RMLog(@"UnityFramework base = %p (%s)", (void *)gUnityBase, name);
            return (void *)gUnityBase;
        }
    }
    return NULL;
}

static int rm_macho_cryptid(void *base) {
    uint32_t *p = (uint32_t *)base;
    if (!p || p[0] != 0xFEEDFACF) return -1;
    uint32_t ncmds = p[4];
    uintptr_t off = 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = *(uint32_t *)((char *)base + off);
        uint32_t cmdsize = *(uint32_t *)((char *)base + off + 4);
        if (cmdsize < 8) break;
        if (cmd == 0x2C) return *(int *)((char *)base + off + 16);
        off += cmdsize;
    }
    return -1;
}

int RMUnityCryptid(void) {
    void *b = RMUnityBase();
    return b ? rm_macho_cryptid(b) : -2;
}

static void rm_macho_uuid(void *base, char *out, size_t cap) {
    if (cap) out[0] = 0;
    uint32_t *p = (uint32_t *)base;
    if (!p || p[0] != 0xFEEDFACF || cap < 33) return;
    uint32_t ncmds = p[4];
    uintptr_t off = 32;
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t cmd = *(uint32_t *)((char *)base + off);
        uint32_t cmdsize = *(uint32_t *)((char *)base + off + 4);
        if (cmdsize < 8) break;
        if (cmd == 0x1B) {
            const unsigned char *u = (const unsigned char *)base + off + 8;
            snprintf(out, cap,
                     "%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                     u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7],
                     u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
            return;
        }
        off += cmdsize;
    }
}

NSString *RMUnityUUIDString(void) {
    void *b = RMUnityBase();
    if (!b) return @"(no base)";
    char uuid[40];
    rm_macho_uuid(b, uuid, sizeof(uuid));
    return [NSString stringWithUTF8String:uuid];
}

// ---------------------------------------------------------------------------
// il2cpp 运行时 API
// ---------------------------------------------------------------------------
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppObject Il2CppObject;
typedef struct Il2CppString Il2CppString;
typedef struct Il2CppType Il2CppType;
typedef struct Il2CppException Il2CppException;
typedef struct Il2CppArray Il2CppArray;
typedef struct FieldInfo FieldInfo;
typedef struct MethodInfo MethodInfo;

static Il2CppDomain *(*il2cpp_domain_get)(void);
static const Il2CppAssembly **(*il2cpp_domain_get_assemblies)(const Il2CppDomain *, size_t *);
static Il2CppImage *(*il2cpp_assembly_get_image)(const Il2CppAssembly *);
static Il2CppClass *(*il2cpp_class_from_name)(const Il2CppImage *, const char *, const char *);
static const MethodInfo *(*il2cpp_class_get_method_from_name)(Il2CppClass *, const char *, int);
static Il2CppObject *(*il2cpp_runtime_invoke)(const MethodInfo *, void *, void **, Il2CppException **);
static Il2CppClass *(*il2cpp_object_get_class)(Il2CppObject *);
static FieldInfo *(*il2cpp_class_get_field_from_name)(Il2CppClass *, const char *);
static void (*il2cpp_field_static_set_value)(FieldInfo *, void *);
static void (*il2cpp_field_static_get_value)(FieldInfo *, void *);
static Il2CppDomain *(*il2cpp_thread_attach)(Il2CppDomain *);
static Il2CppString *(*il2cpp_string_new)(const char *);
static Il2CppType *(*il2cpp_class_get_type)(Il2CppClass *);
static Il2CppObject *(*il2cpp_type_get_object)(const Il2CppType *);
static uint32_t (*il2cpp_gchandle_new)(Il2CppObject *, bool);
static void (*il2cpp_gchandle_free)(uint32_t);
static void *(*il2cpp_object_new)(Il2CppClass *);
static Il2CppArray *(*il2cpp_array_new)(Il2CppClass *, size_t);

static bool rm_resolve_il2cpp(void) {
    if (RMIl2CppReady) return true;
    void *h = dlopen(NULL, RTLD_NOW);
    if (!h) return false;
#define RESOLVE(var, name)                                   \
    var = (__typeof__(var))dlsym(h, name);                    \
    if (!var) { RMLog(@"缺少符号 %s", name); return false; }
    RESOLVE(il2cpp_domain_get, "il2cpp_domain_get");
    RESOLVE(il2cpp_domain_get_assemblies, "il2cpp_domain_get_assemblies");
    RESOLVE(il2cpp_assembly_get_image, "il2cpp_assembly_get_image");
    RESOLVE(il2cpp_class_from_name, "il2cpp_class_from_name");
    RESOLVE(il2cpp_class_get_method_from_name, "il2cpp_class_get_method_from_name");
    RESOLVE(il2cpp_runtime_invoke, "il2cpp_runtime_invoke");
    RESOLVE(il2cpp_object_get_class, "il2cpp_object_get_class");
    RESOLVE(il2cpp_class_get_field_from_name, "il2cpp_class_get_field_from_name");
    RESOLVE(il2cpp_field_static_set_value, "il2cpp_field_static_set_value");
    RESOLVE(il2cpp_field_static_get_value, "il2cpp_field_static_get_value");
    RESOLVE(il2cpp_thread_attach, "il2cpp_thread_attach");
    RESOLVE(il2cpp_string_new, "il2cpp_string_new");
    il2cpp_class_get_type = (__typeof__(il2cpp_class_get_type))dlsym(h, "il2cpp_class_get_type");
    il2cpp_type_get_object = (__typeof__(il2cpp_type_get_object))dlsym(h, "il2cpp_type_get_object");
    il2cpp_gchandle_new = (__typeof__(il2cpp_gchandle_new))dlsym(h, "il2cpp_gchandle_new");
    il2cpp_gchandle_free = (__typeof__(il2cpp_gchandle_free))dlsym(h, "il2cpp_gchandle_free");
    il2cpp_object_new = (__typeof__(il2cpp_object_new))dlsym(h, "il2cpp_object_new");
    il2cpp_array_new = (__typeof__(il2cpp_array_new))dlsym(h, "il2cpp_array_new");
#undef RESOLVE
    RMIl2CppReady = true;
    return true;
}

static Il2CppClass *rm_find_class_ns(const char *ns, const char *name) {
    if (!il2cpp_domain_get) return NULL;
    Il2CppDomain *domain = il2cpp_domain_get();
    if (!domain) return NULL;
    if (il2cpp_thread_attach) il2cpp_thread_attach(domain);
    size_t count = 0;
    const Il2CppAssembly **asms = il2cpp_domain_get_assemblies(domain, &count);
    if (!asms || count == 0 || count > 4096) return NULL;
    for (size_t i = 0; i < count; i++) {
        Il2CppImage *img = il2cpp_assembly_get_image(asms[i]);
        if (!img) continue;
        Il2CppClass *k = il2cpp_class_from_name(img, ns, name);
        if (k) return k;
    }
    return NULL;
}

static Il2CppClass *rm_find_class_any(const char *name) {
    static const char *namespaces[] = {"", "InLevel", "UnityEngine", "System"};
    for (int i = 0; i < 4; i++) {
        Il2CppClass *k = rm_find_class_ns(namespaces[i], name);
        if (k) return k;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// 运行时对象缓存
// ---------------------------------------------------------------------------
static Il2CppClass *gInfoClass = NULL;
static Il2CppClass *gJudgeClass = NULL;
static Il2CppClass *gNormalClass = NULL;
static Il2CppClass *gChallengeClass = NULL;
static Il2CppClass *gWeeklyClass = NULL;
static Il2CppClass *gLevelCtlClass = NULL;
static Il2CppClass *gPaymentClass = NULL;
static Il2CppClass *gModsClass = NULL;
static Il2CppClass *gModBtnClass = NULL;
static Il2CppClass *gSelectClass = NULL;
static Il2CppClass *gObjectClass = NULL;
static Il2CppClass *gGoClass = NULL;
static Il2CppClass *gOwnedItemClass = NULL;
static Il2CppClass *gProductInfoClass = NULL;
static Il2CppClass *gStringClass = NULL;
static Il2CppClass *gInt32Class = NULL;
static Il2CppClass *gTransformClass = NULL;
static Il2CppClass *gRectTransformClass = NULL;

static const MethodInfo *gFindTypeM2 = NULL;
static const MethodInfo *gFindTypeM1 = NULL;
static const MethodInfo *gFindObjectsM1 = NULL;

static void *gInfoObj = NULL;
static uint32_t gInfoHandle = 0;
static void *gNormalObj = NULL;
static uint32_t gNormalHandle = 0;
static void *gChallengeObj = NULL;
static uint32_t gChallengeHandle = 0;
static void *gWeeklyObj = NULL;
static uint32_t gWeeklyHandle = 0;
static void *gLevelCtlObj = NULL;
static uint32_t gLevelCtlHandle = 0;
static void *gSelectObj = NULL;
static uint32_t gSelectHandle = 0;
static void *gModsObj = NULL;
static uint32_t gModsHandle = 0;

static CFTimeInterval gLastFind = 0;
static CFTimeInterval gLastApply = 0;
static CFTimeInterval gLastUnlock = 0;
static CFTimeInterval gLastModUnlock = 0;
static CFTimeInterval gLastResolve = 0;
static BOOL gWasInLevel = NO;

static void rm_setup_classes(void) {
    gInfoClass = rm_find_class_ns("InLevel", "LevelInformation");
    gJudgeClass = rm_find_class_ns("InLevel", "NoteJudgeControl");
    gNormalClass = rm_find_class_any("NormalModeInLevelController");
    gChallengeClass = rm_find_class_any("ChallengeInLevelController");
    gWeeklyClass = rm_find_class_any("WeeklyChallengeModeController");
    gLevelCtlClass = rm_find_class_any("LevelControl");
    gPaymentClass = rm_find_class_any("PaymentService");
    gModsClass = rm_find_class_any("ModsControl");
    gModBtnClass = rm_find_class_any("ModButtonControl");
    gSelectClass = rm_find_class_any("LevelSelectControl");
    gObjectClass = rm_find_class_ns("UnityEngine", "Object");
    gGoClass = rm_find_class_ns("UnityEngine", "GameObject");
    gOwnedItemClass = rm_find_class_any("OwnedItemInfo");
    gProductInfoClass = rm_find_class_any("RizlineProductInfo");
    gStringClass = rm_find_class_ns("System", "String");
    gInt32Class = rm_find_class_ns("System", "Int32");
    gTransformClass = rm_find_class_ns("UnityEngine", "Transform");
    gRectTransformClass = rm_find_class_ns("UnityEngine", "RectTransform");

    if (gObjectClass) {
        gFindTypeM2 = il2cpp_class_get_method_from_name(gObjectClass, "FindObjectOfType", 2);
        if (!gFindTypeM2) {
            gFindTypeM1 = il2cpp_class_get_method_from_name(gObjectClass, "FindObjectOfType", 1);
        }
        gFindObjectsM1 = il2cpp_class_get_method_from_name(gObjectClass, "FindObjectsOfType", 1);
    }
    int mask = (gInfoClass ? 1 : 0) | (gJudgeClass ? 2 : 0) | (gNormalClass ? 4 : 0) |
               (gChallengeClass ? 8 : 0) | (gWeeklyClass ? 16 : 0) | (gLevelCtlClass ? 32 : 0) |
               (gPaymentClass ? 64 : 0) | (gModsClass ? 128 : 0) | (gSelectClass ? 256 : 0) |
               ((gFindTypeM2 || gFindTypeM1) ? 512 : 0);
    static int lastMask = -1;
    if (mask != lastMask) {
        lastMask = mask;
        RMLog(@"类定位: info=%p judge=%p normal=%p challenge=%p weekly=%p levelCtl=%p payment=%p mods=%p select=%p find=%p",
              gInfoClass, gJudgeClass, gNormalClass, gChallengeClass, gWeeklyClass,
              gLevelCtlClass, gPaymentClass, gModsClass, gSelectClass,
              gFindTypeM2 ? (void *)gFindTypeM2 : (void *)gFindTypeM1);
    }
}

static void *rm_find_object(Il2CppClass *k, uint32_t *handle) {
    if (!k) return NULL;
    if (!il2cpp_class_get_type || !il2cpp_type_get_object) return NULL;
    Il2CppType *t = il2cpp_class_get_type(k);
    void *typeObj = t ? il2cpp_type_get_object(t) : NULL;
    if (!typeObj) return NULL;
    Il2CppException *exc = NULL;
    Il2CppObject *o = NULL;
    if (gFindTypeM2) {
        uint8_t includeInactive = 1;
        void *args[2] = {typeObj, &includeInactive};
        o = il2cpp_runtime_invoke(gFindTypeM2, NULL, args, &exc);
    } else if (gFindTypeM1) {
        void *args[1] = {typeObj};
        o = il2cpp_runtime_invoke(gFindTypeM1, NULL, args, &exc);
    }
    if (exc) return NULL;
    if (!o) {
        if (handle && *handle && il2cpp_gchandle_free) {
            il2cpp_gchandle_free(*handle);
            *handle = 0;
        }
        return NULL;
    }
    if (handle) {
        if (*handle && il2cpp_gchandle_free) il2cpp_gchandle_free(*handle);
        *handle = il2cpp_gchandle_new ? il2cpp_gchandle_new(o, false) : 0;
    }
    return o;
}

static void rm_refresh_objects(void) {
    gInfoObj = rm_find_object(gInfoClass, &gInfoHandle);
    gNormalObj = rm_find_object(gNormalClass, &gNormalHandle);
    gChallengeObj = rm_find_object(gChallengeClass, &gChallengeHandle);
    gWeeklyObj = rm_find_object(gWeeklyClass, &gWeeklyHandle);
    gLevelCtlObj = rm_find_object(gLevelCtlClass, &gLevelCtlHandle);
    gSelectObj = rm_find_object(gSelectClass, &gSelectHandle);
    gModsObj = rm_find_object(gModsClass, &gModsHandle);

    if (!RMGameReady && (gSelectObj || gInfoObj)) {
        RMGameReady = true;
        RMLog(@"游戏界面已就绪，开始应用 Mod 设置");
    }
}

// ---------------------------------------------------------------------------
// 诊断：抓取屏幕上的 Unity / UIKit 文本（用于定位 SDK 报错原文）
// ---------------------------------------------------------------------------
static NSString *rm_il2cpp_string_text(Il2CppString *s) {
    if (!s) return nil;
    int32_t len = *(int32_t *)((char *)s + 0x10);
    if (len <= 0 || len > 2048) return nil;
    const uint16_t *chars = (const uint16_t *)((char *)s + 0x14);
    NSString *txt = [[NSString alloc] initWithBytes:chars
                                             length:(NSUInteger)len * 2
                                           encoding:NSUTF16LittleEndianStringEncoding];
    if (!txt) {
        txt = [[NSString alloc] initWithBytes:chars
                                       length:(NSUInteger)len * 2
                                     encoding:NSUTF16BigEndianStringEncoding];
    }
    return txt;
}

static NSUInteger rm_array_count(void *arr) {
    if (!arr) return 0;
    return (NSUInteger)*(uintptr_t *)((char *)arr + 0x18);
}

static NSString *gLastUiDump = nil;

static void rm_scan_unity_texts(void) {
    if (!gFindObjectsM1 || !il2cpp_class_get_type || !il2cpp_type_get_object) return;

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableString *stats = [NSMutableString string];

    const char *nss[3] = {"TMPro", "TMPro", "UnityEngine.UI"};
    const char *names[3] = {"TextMeshProUGUI", "TextMeshPro", "Text"};
    for (int ci = 0; ci < 3; ci++) {
        Il2CppClass *k = rm_find_class_ns(nss[ci], names[ci]);
        if (!k) { [stats appendFormat:@"%s=缺失 ", names[ci]]; continue; }
        Il2CppType *t = il2cpp_class_get_type(k);
        void *typeObj = t ? il2cpp_type_get_object(t) : NULL;
        if (!typeObj) { [stats appendFormat:@"%s=无类型 ", names[ci]]; continue; }

        Il2CppException *exc = NULL;
        void *args[1] = {typeObj};
        Il2CppObject *arr = il2cpp_runtime_invoke(gFindObjectsM1, NULL, args, &exc);
        if (exc || !arr) { [stats appendFormat:@"%s=异常 ", names[ci]]; continue; }

        NSUInteger n = rm_array_count(arr);
        if (n > 1024) n = 1024;
        [stats appendFormat:@"%s=%lu ", names[ci], (unsigned long)n];

        const MethodInfo *baseGet = il2cpp_class_get_method_from_name(k, "get_text", 0);
        void **elems = (void **)((char *)arr + kOff_Array_Elements);
        for (NSUInteger i = 0; i < n; i++) {
            Il2CppObject *o = (Il2CppObject *)elems[i];
            if (!o) continue;
            const MethodInfo *m = baseGet;
            if (!m) {
                Il2CppClass *oc = il2cpp_object_get_class(o);
                m = oc ? il2cpp_class_get_method_from_name(oc, "get_text", 0) : NULL;
            }
            if (!m) continue;
            Il2CppException *e2 = NULL;
            Il2CppObject *str = il2cpp_runtime_invoke(m, o, NULL, &e2);
            if (e2 || !str) continue;
            NSString *txt = rm_il2cpp_string_text((Il2CppString *)str);
            txt = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (txt.length < 2 || txt.length > 300) continue;
            if ([seen containsObject:txt]) continue;
            [seen addObject:txt];
            [texts addObject:txt];
            if (texts.count >= 60) break;
        }
        if (texts.count >= 60) break;
    }

    NSString *joined = texts.count ? [texts componentsJoinedByString:@" ⏐ "] : @"(无文本)";
    NSString *sig = [NSString stringWithFormat:@"%@→ %@", stats, joined];
    if (gLastUiDump && [sig isEqualToString:gLastUiDump]) return;
    gLastUiDump = sig;
    RMLog(@"界面文本[Unity] %@", sig);
}

static NSString *gLastUIKitDump = nil;

static void rm_collect_uikit_texts(UIView *v, NSMutableArray<NSString *> *out) {
    if (!v || v.hidden || v.alpha < 0.02) return;
    NSString *t = nil;
    if ([v isKindOfClass:[UILabel class]]) {
        t = ((UILabel *)v).text;
    } else if ([v isKindOfClass:[UIButton class]]) {
        t = [(UIButton *)v titleForState:UIControlStateNormal];
    } else if ([v isKindOfClass:[UITextField class]]) {
        t = ((UITextField *)v).text;
    } else if ([v isKindOfClass:[UITextView class]]) {
        t = ((UITextView *)v).text;
    }
    if (t.length >= 2 && t.length <= 300) [out addObject:t];
    for (UIView *s in v.subviews) rm_collect_uikit_texts(s, out);
}

static void rm_scan_uikit_texts(void) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            // 跳过本 mod 自己的悬浮球 / 设置页
            if (w.windowLevel >= UIWindowLevelAlert) continue;
            rm_collect_uikit_texts(w, texts);
        }
    }
    for (NSString *t in texts) {
        if (t.length) [seen addObject:t];
    }
    if (!seen.count) return;
    NSArray *sorted = [[seen allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSString *joined = [sorted componentsJoinedByString:@" ⏐ "];
    if (gLastUIKitDump && [joined isEqualToString:gLastUIKitDump]) return;
    gLastUIKitDump = joined;
    RMLog(@"界面文本[UIKit] %@", joined);
}

// ---------------------------------------------------------------------------
// il2cpp 小工具
// ---------------------------------------------------------------------------
static void rm_obj_set_bool(void *obj, size_t off, bool v) {
    if (!obj) return;
    *(uint8_t *)((char *)obj + off) = v ? 1 : 0;
}

static void rm_obj_set_float(void *obj, size_t off, float v) {
    if (!obj) return;
    *(float *)((char *)obj + off) = v;
}

static bool rm_call_static_bool(Il2CppClass *k, const char *setter, bool value) {
    if (!k) return false;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, setter, 1);
    if (!m) return false;
    uint8_t v = value ? 1 : 0;
    void *args[1] = {&v};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, NULL, args, &exc);
    return exc == NULL;
}

static void rm_call_static_void(Il2CppClass *k, const char *method) {
    if (!k) return;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, method, 0);
    if (!m) return;
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, NULL, NULL, &exc);
}

static bool rm_boxed_bool(Il2CppObject *o) {
    if (!o) return false;
    return *(uint8_t *)((char *)o + kOff_Boxed_Value) != 0;
}

static int rm_boxed_int(Il2CppObject *o) {
    if (!o) return 0;
    return *(int *)((char *)o + kOff_Boxed_Value);
}

static BOOL rm_istring_equal(Il2CppString *a, Il2CppString *b) {
    if (a == b) return YES;
    if (!a || !b) return NO;
    int la = *(int *)((char *)a + 0x10);
    int lb = *(int *)((char *)b + 0x10);
    if (la != lb || la < 0) return NO;
    return memcmp((char *)a + 0x14, (char *)b + 0x14, (size_t)la * 2) == 0;
}

static Il2CppObject *rm_call_obj0(void *obj, const char *method) {
    if (!obj) return NULL;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)obj);
    if (!k) return NULL;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, method, 0);
    if (!m) return NULL;
    Il2CppException *exc = NULL;
    Il2CppObject *r = il2cpp_runtime_invoke(m, obj, NULL, &exc);
    return exc ? NULL : r;
}

static int rm_call_int0(void *obj, const char *method) {
    return rm_boxed_int(rm_call_obj0(obj, method));
}

// user.getItems 里是否已有该 itemAssetId
static bool rm_owned_has(void *items, Il2CppString *assetId) {
    int n = 0;
    void **elems = rm_list_items(items, &n);
    if (!elems) return false;
    for (int i = 0; i < n; i++) {
        void *it = elems[i];
        if (!it) continue;
        if (rm_istring_equal(*(Il2CppString **)((char *)it + kOff_Item_AssetId), assetId)) return true;
    }
    return false;
}

static bool rm_owned_add(void *items, Il2CppString *assetId) {
    if (!items || !assetId || !gOwnedItemClass || !il2cpp_object_new) return false;
    Il2CppObject *it = (Il2CppObject *)il2cpp_object_new(gOwnedItemClass);
    if (!it) return false;
    *(Il2CppString **)((char *)it + kOff_Item_AssetId) = assetId;
    *(int *)((char *)it + kOff_Item_Amount) = 1;
    const MethodInfo *m = il2cpp_class_get_method_from_name(il2cpp_object_get_class((Il2CppObject *)items), "Add", 1);
    if (!m) return false;
    Il2CppException *exc = NULL;
    void *args[1] = {it};
    il2cpp_runtime_invoke(m, items, args, &exc);
    return exc == NULL;
}

static bool rm_list_contains(void *list, Il2CppString *value) {
    if (!list || !value) return false;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)list);
    if (!k) return false;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, "Contains", 1);
    if (!m) return false;
    void *args[1] = {value};
    Il2CppException *exc = NULL;
    Il2CppObject *r = il2cpp_runtime_invoke(m, list, args, &exc);
    return !exc && rm_boxed_bool(r);
}

static void rm_list_add(void *list, Il2CppString *value) {
    if (!list || !value) return;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)list);
    if (!k) return;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, "Add", 1);
    if (!m) return;
    void *args[1] = {value};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, list, args, &exc);
}

static void rm_hashset_add(void *set, Il2CppString *value) {
    if (!set || !value) return;
    Il2CppClass *k = il2cpp_object_get_class((Il2CppObject *)set);
    if (!k) return;
    const MethodInfo *m = il2cpp_class_get_method_from_name(k, "Add", 1);
    if (!m) return;
    void *args[1] = {value};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(m, set, args, &exc);
}

// ---------------------------------------------------------------------------
// 玩法开关
// ---------------------------------------------------------------------------
static void rm_apply_mods(void) {
    bool autoJudge = RMAutoPlay || RMAutoDemo;
    // 官方 Mod 静态状态：
    //   AutoPlay（官方的“自动演示”）只有在 RMAutoDemo 打开时才置位，
    //   否则游戏会把本局标记成演示、结算不给成绩。
    if (gModsClass) {
        rm_call_static_bool(gModsClass, "set_AutoPlay", RMAutoDemo);
        rm_call_static_bool(gModsClass, "set_NoBad", RMNoBad);
        rm_call_static_bool(gModsClass, "set_FreeHold", RMFreeHold);
    }

    if (!gInfoObj) {
        RMInLevel = false;
        if (gWasInLevel) {
            gWasInLevel = NO;
            RMLog(@"离开游玩");
        }
        return;
    }
    if (il2cpp_object_get_class && gInfoClass &&
        il2cpp_object_get_class((Il2CppObject *)gInfoObj) != gInfoClass) {
        gInfoObj = NULL;
        return;
    }

    bool began = *(uint8_t *)((char *)gInfoObj + kOff_Info_LevelBegan) != 0;
    bool over = *(uint8_t *)((char *)gInfoObj + kOff_Info_LevelOver) != 0;

    void *judge = *(void **)((char *)gInfoObj + kOff_Info_NoteJudge);
    if (judge && gJudgeClass && il2cpp_object_get_class &&
        il2cpp_object_get_class((Il2CppObject *)judge) == gJudgeClass) {
        rm_obj_set_bool(judge, kOff_Judge_AutoPlay, autoJudge);
        rm_obj_set_bool(judge, kOff_Judge_FreeHold, RMFreeHold);

        void *notes = *(void **)((char *)judge + kOff_Judge_Notes);
        int n = -1;
        if (notes) n = *(int *)((char *)notes + kOff_List_Size);
        if (n >= 0 && n < 200000) RMLastNoteCount = n;
    }

    bool active = began && !over;
    RMInLevel = active;
    if (active) {
        RMLastGameplayTick = CFAbsoluteTimeGetCurrent();
        if (!gWasInLevel) {
            gWasInLevel = YES;
            RMLog(@"进入游玩: judge=%p notes=%d auto=%d", judge, RMLastNoteCount, RMAutoPlay);
        }
    } else if (gWasInLevel) {
        gWasInLevel = NO;
        RMLog(@"离开游玩");
    }

    if (gNormalObj) {
        rm_obj_set_bool(gNormalObj, kOff_Normal_NoBad, RMNoBad);
        rm_obj_set_bool(gNormalObj, kOff_Normal_AutoPlayField, autoJudge);
        if (RMLockHP) rm_obj_set_float(gNormalObj, kOff_Normal_Life, 1.0f);
    }
    if (gChallengeObj) {
        rm_obj_set_bool(gChallengeObj, kOff_Challenge_NoBad, RMNoBad);
        if (RMLockHP) {
            rm_obj_set_bool(gChallengeObj, kOff_Challenge_NoFail, true);
            rm_obj_set_float(gChallengeObj, kOff_Challenge_Life, 1.0f);
        }
    }
    if (gWeeklyObj && RMLockHP) {
        rm_obj_set_float(gWeeklyObj, kOff_Weekly_Life, 1.0f);
    }
}

// 锁血需要每帧压住，避免判定那一下把血量扣下去
static void rm_pin_life_fast(void) {
    if (!RMLockHP) return;
    if (gNormalObj) {
        rm_obj_set_float(gNormalObj, kOff_Normal_Damage, 0.0f);
        rm_obj_set_float(gNormalObj, kOff_Normal_Life, 1.0f);
    }
    if (gChallengeObj) {
        rm_obj_set_float(gChallengeObj, kOff_Challenge_Life, 1.0f);
    }
    if (gWeeklyObj) {
        rm_obj_set_float(gWeeklyObj, kOff_Weekly_Damage, 0.0f);
        rm_obj_set_float(gWeeklyObj, kOff_Weekly_Life, 1.0f);
    }
}

// ---------------------------------------------------------------------------
// 全曲解锁
//   TrackUnlocked(trackId) 的实际实现是 user.getItems.Any(i => i.itemAssetId == trackId)，
//   所以要写 User.getItems（OwnedItemInfo），只写 PaymentService.ownedTracks 没用。
//   trackAssetId 从 PaymentService.GetSongProductMap() 的 key 取。
// ---------------------------------------------------------------------------
static Il2CppObject *rm_payment_user(void) {
    if (!gPaymentClass || !il2cpp_class_get_field_from_name) return NULL;
    FieldInfo *f = il2cpp_class_get_field_from_name(gPaymentClass, "user");
    if (!f) return NULL;
    void *user = NULL;
    il2cpp_field_static_get_value(f, &user);
    return (Il2CppObject *)user;
}

static int rm_collect_track_ids(Il2CppObject ***outIDs, int *outCount) {
    *outIDs = NULL;
    *outCount = 0;
    if (!gPaymentClass || !gStringClass || !il2cpp_array_new) return 0;
    const MethodInfo *mMap = il2cpp_class_get_method_from_name(gPaymentClass, "GetSongProductMap", 0);
    if (!mMap) return 0;
    Il2CppException *exc = NULL;
    Il2CppObject *map = il2cpp_runtime_invoke(mMap, NULL, NULL, &exc);
    if (!map || exc) return 0;

    Il2CppObject *keys = rm_call_obj0(map, "get_Keys");
    int kn = rm_call_int0(keys, "get_Count");
    if (!keys || kn <= 0 || kn > 5000) return 0;

    Il2CppArray *arr = il2cpp_array_new(gStringClass, (size_t)kn);
    if (!arr) return 0;
    const MethodInfo *mCopy = il2cpp_class_get_method_from_name(
        il2cpp_object_get_class(keys), "CopyTo", 2);
    if (!mCopy) return 0;
    int zero = 0;
    void *args[2] = {arr, &zero};
    Il2CppException *exc2 = NULL;
    il2cpp_runtime_invoke(mCopy, keys, args, &exc2);
    if (exc2) return 0;

    *outIDs = (Il2CppObject **)((char *)arr + kOff_Array_Elements);
    *outCount = kn;
    return kn;
}

static bool rm_track_unlocked(Il2CppString *trackId) {
    if (!gPaymentClass || !trackId) return false;
    const MethodInfo *m = il2cpp_class_get_method_from_name(gPaymentClass, "TrackUnlocked", 1);
    if (!m) return false;
    void *args[1] = {trackId};
    Il2CppException *exc = NULL;
    Il2CppObject *r = il2cpp_runtime_invoke(m, NULL, args, &exc);
    return !exc && rm_boxed_bool(r);
}

// 选曲界面锁图标查的是 PaymentService.OwnedProduct(int itemId)，
// 它读静态 ownedProducts 字典（登录时由 User.getItems 派生），写 getItems 不会同步过去。
// 所以按 GetSongProductMap() 的 value.id 调 SetOwnedProductCount 补齐，并触发一次刷新。
static int rm_owned_product_count(int productId) {
    if (!gPaymentClass) return 0;
    const MethodInfo *m = il2cpp_class_get_method_from_name(gPaymentClass, "GetOwnedProductCount", 1);
    if (!m) return 0;
    void *args[1] = {&productId};
    Il2CppException *exc = NULL;
    Il2CppObject *r = il2cpp_runtime_invoke(m, NULL, args, &exc);
    return exc ? 0 : rm_boxed_int(r);
}

static int rm_set_owned_product(int pid) {
    if (pid <= 0) return 0;
    if (rm_owned_product_count(pid) > 0) return 0;
    const MethodInfo *mSet = il2cpp_class_get_method_from_name(gPaymentClass, "SetOwnedProductCount", 2);
    if (!mSet) return 0;
    int one = 1;
    void *args[2] = {&pid, &one};
    Il2CppException *e = NULL;
    il2cpp_runtime_invoke(mSet, NULL, args, &e);
    return e ? 0 : 1;
}

// PaymentService.products 是「全部商品」字典（含曲目包和官方 Mod 商品），
// OwnedProduct(id) 只认 ownedProducts，所以把整张商品表都写一遍，
// 官方的 Mod 按钮、曲目锁、价格条就会一起解锁。
static int rm_sync_owned_products(void) {
    if (!gPaymentClass || !gInt32Class || !il2cpp_array_new) return 0;
    FieldInfo *fProducts = il2cpp_class_get_field_from_name(gPaymentClass, "products");
    if (!fProducts) return 0;
    void *dict = NULL;
    il2cpp_field_static_get_value(fProducts, &dict);
    if (!dict) return 0;

    Il2CppObject *keys = rm_call_obj0(dict, "get_Keys");
    int n = rm_call_int0(keys, "get_Count");
    if (!keys || n <= 0 || n > 20000) return 0;

    Il2CppArray *arr = il2cpp_array_new(gInt32Class, (size_t)n);
    if (!arr) return 0;
    const MethodInfo *mCopy = il2cpp_class_get_method_from_name(
        il2cpp_object_get_class((Il2CppObject *)keys), "CopyTo", 2);
    if (!mCopy) return 0;
    int zero = 0;
    void *copyArgs[2] = {arr, &zero};
    Il2CppException *exc = NULL;
    il2cpp_runtime_invoke(mCopy, keys, copyArgs, &exc);
    if (exc) return 0;

    int synced = 0;
    char *base = (char *)arr + kOff_Array_Elements;
    for (int i = 0; i < n; i++) {
        synced += rm_set_owned_product(*(int *)(base + (size_t)i * 4));
    }
    static int lastLogged = -1;
    if (synced != lastLogged) {
        lastLogged = synced;
        RMLog(@"官方商品解锁: 商品表 %d 个，本次新增拥有 %d", n, synced);
    }
    return synced;
}

static void rm_infer_track_id_affix(Il2CppObject **keys, int keyCount,
                                    void **levelIds, int levelCount);
static Il2CppString *rm_level_track_id(Il2CppString *levelId);

static void rm_apply_unlock(void) {
    if (!RMUnlockAllSongs) {
        RMUnlockAllApplied = false;
        return;
    }
    if (!gLevelCtlObj || !gLevelCtlClass || !gPaymentClass) return;

    const MethodInfo *mAll = il2cpp_class_get_method_from_name(gLevelCtlClass, "GetAllLevelId", 0);
    if (!mAll) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; RMLog(@"LevelControl.GetAllLevelId 未找到"); }
        return;
    }
    Il2CppException *exc = NULL;
    Il2CppObject *ids = il2cpp_runtime_invoke(mAll, gLevelCtlObj, NULL, &exc);
    if (!ids || exc) return;

    int count = 0;
    void **items = rm_list_items(ids, &count);
    if (!items || count <= 0 || count > 20000) return;

    FieldInfo *fTracks = il2cpp_class_get_field_from_name(gPaymentClass, "ownedTracks");
    if (!fTracks) return;
    void *owned = NULL;
    il2cpp_field_static_get_value(fTracks, &owned);
    if (!owned) {
        static BOOL logged = NO;
        if (!logged) { logged = YES; RMLog(@"PaymentService.ownedTracks 尚未初始化"); }
        return;
    }

    FieldInfo *fVip = il2cpp_class_get_field_from_name(gPaymentClass, "vipTracks");
    void *vip = NULL;
    if (fVip) il2cpp_field_static_get_value(fVip, &vip);

    Il2CppObject *user = rm_payment_user();
    void *userItems = user ? *(void **)((char *)user + kOff_User_Items) : NULL;
    void *userLevels = user ? *(void **)((char *)user + kOff_User_Levels) : NULL;

    // 1) 曲目资源 id（getItems 真正比对的值）
    Il2CppObject **trackIDs = NULL;
    int trackCount = 0;
    rm_collect_track_ids(&trackIDs, &trackCount);
    rm_infer_track_id_affix(trackIDs, trackCount, items, count);
    int itemAdded = 0;
    int trackAdded = 0;
    for (int i = 0; i < trackCount; i++) {
        Il2CppString *tid = (Il2CppString *)trackIDs[i];
        if (!tid) continue;
        if (userItems && !rm_owned_has(userItems, tid)) {
            if (rm_owned_add(userItems, tid)) itemAdded++;
        }
        if (!rm_list_contains(owned, tid)) {
            rm_list_add(owned, tid);
            trackAdded++;
        }
        if (vip) rm_hashset_add(vip, tid);
    }

    // 1.5) 选曲面板真正比对的是 Level.musicInfo.id（BeginOpenLevel 里的 TrackUnlocked）
    const MethodInfo *mLevels = il2cpp_class_get_method_from_name(gLevelCtlClass, "GetAllLevel", 0);
    if (mLevels) {
        Il2CppException *excL = NULL;
        Il2CppObject *levels = il2cpp_runtime_invoke(mLevels, gLevelCtlObj, NULL, &excL);
        int lc = 0;
        void **le = (!excL && levels) ? rm_list_items(levels, &lc) : NULL;
        if (le && lc > 0 && lc < 20000) {
            int musicAdded = 0;
            for (int i = 0; i < lc; i++) {
                void *lv = le[i];
                if (!lv) continue;
                void *music = *(void **)((char *)lv + 0x20);                     // Level.musicInfo
                Il2CppString *tid = music ? *(Il2CppString **)((char *)music + 0x10) : NULL;  // MusicInfo.id
                if (!tid) continue;
                if (userItems && !rm_owned_has(userItems, tid)) {
                    if (rm_owned_add(userItems, tid)) { itemAdded++; musicAdded++; }
                }
                if (!rm_list_contains(owned, tid)) {
                    rm_list_add(owned, tid);
                    trackAdded++;
                }
                if (vip) rm_hashset_add(vip, tid);
            }
            if (musicAdded > 0) RMLog(@"全曲解锁: 补写 musicInfo.id %d 个", musicAdded);
        }
    }

    // 2) 关卡 id（ownedTracks / unlockedLevels，兜底）
    int added = 0;
    for (int i = 0; i < count; i++) {
        Il2CppString *sid = (Il2CppString *)items[i];
        if (!sid) continue;
        if (!rm_list_contains(owned, sid)) {
            rm_list_add(owned, sid);
            added++;
        }
        if (vip) rm_hashset_add(vip, sid);
        if (userLevels && !rm_list_contains(userLevels, sid)) rm_list_add(userLevels, sid);
        // 关卡 id 本身 + 推断出前缀后的形式，都补进 getItems
        if (userItems) {
            if (!rm_owned_has(userItems, sid)) {
                if (rm_owned_add(userItems, sid)) itemAdded++;
            }
            Il2CppString *altId = rm_level_track_id(sid);
            if (altId && altId != sid && !rm_owned_has(userItems, altId)) {
                if (rm_owned_add(userItems, altId)) itemAdded++;
            }
        }
    }

    // DiscO 关卡在独立的 map 里，单独补一遍
    const MethodInfo *mDiscO = il2cpp_class_get_method_from_name(gLevelCtlClass, "GetAllDiscOLevel", 0);
    if (mDiscO) {
        Il2CppException *exc2 = NULL;
        Il2CppObject *discO = il2cpp_runtime_invoke(mDiscO, gLevelCtlObj, NULL, &exc2);
        int discCount = 0;
        void **discItems = discO ? rm_list_items(discO, &discCount) : NULL;
        if (discItems && discCount > 0 && discCount < 20000) {
            for (int i = 0; i < discCount; i++) {
                void *level = discItems[i];
                if (!level) continue;
                Il2CppString *sid = *(Il2CppString **)((char *)level + 0x10);   // Level.id
                if (!sid) continue;
                if (!rm_list_contains(owned, sid)) {
                    rm_list_add(owned, sid);
                    added++;
                }
                if (vip) rm_hashset_add(vip, sid);
                if (userLevels && !rm_list_contains(userLevels, sid)) rm_list_add(userLevels, sid);
            }
            count += discCount;
        }
    }

    RMLastLevelIdCount = count;
    RMUnlockAllApplied = true;
    int productAdded = rm_sync_owned_products();
    if (added + trackAdded + itemAdded + productAdded > 0) {
        static BOOL verified = NO;
        bool ok = false;
        if (!verified && trackCount > 0 && trackIDs[0]) {
            verified = YES;
            ok = rm_track_unlocked((Il2CppString *)trackIDs[0]);
        }
        RMLog(@"全曲解锁: 关卡 %d，曲目 id %d，新增 item %d / ownedTracks %d / 商品 %d（TrackUnlocked 校验=%d）",
              count, trackCount, itemAdded, trackAdded + added, productAdded, ok ? 1 : 0);
        // 让选曲界面重新检查一次锁图标
        rm_call_static_void(gSelectClass, "RefreshAllPurchasableLocksGlobal");
    }
}

// ---------------------------------------------------------------------------
// 曲目 id 形式推断
//   LevelSelectControl.PlayLevel 里的判定是 TrackUnlocked(<固定串> + Level.id)，
//   而 GetSongProductMap 的 key 不一定等于 Level.id。用两者对比推断出前后缀，
//   之后补写 item 时就能给出 PlayLevel 真正要比对的那个字符串。
// ---------------------------------------------------------------------------
static NSString *gTrackIdPrefix = @"";
static NSString *gTrackIdSuffix = @"";
static BOOL gTrackIdAffixReady = NO;

static void rm_infer_track_id_affix(Il2CppObject **keys, int keyCount,
                                    void **levelIds, int levelCount) {
    if (gTrackIdAffixReady || keyCount <= 0 || levelCount <= 0) return;
    int limitKeys = MIN(keyCount, 300);
    int limitLevels = MIN(levelCount, 400);
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (int i = 0; i < limitKeys; i++) {
        NSString *k = rm_il2cpp_string_text((Il2CppString *)keys[i]);
        if (k.length < 3 || k.length > 160) continue;
        for (int j = 0; j < limitLevels; j++) {
            NSString *lv = rm_il2cpp_string_text((Il2CppString *)levelIds[j]);
            if (lv.length < 2 || lv.length >= k.length) continue;
            if ([k hasSuffix:lv]) {
                NSString *p = [@"P|" stringByAppendingString:[k substringToIndex:k.length - lv.length]];
                counts[p] = @([counts[p] intValue] + 1);
            } else if ([k hasPrefix:lv]) {
                NSString *s = [@"S|" stringByAppendingString:[k substringFromIndex:lv.length]];
                counts[s] = @([counts[s] intValue] + 1);
            }
        }
    }
    NSString *best = nil;
    int bestCount = 0;
    for (NSString *key in counts) {
        int c = [counts[key] intValue];
        if (c > bestCount) { bestCount = c; best = key; }
    }
    if (best.length > 2 && bestCount >= 3) {
        if ([best hasPrefix:@"P|"]) gTrackIdPrefix = [best substringFromIndex:2];
        else gTrackIdSuffix = [best substringFromIndex:2];
    }
    gTrackIdAffixReady = YES;
    RMLog(@"曲目 id 形式: level.id %@%@%@（样本命中 %d）",
          gTrackIdPrefix, @"<id>", gTrackIdSuffix, bestCount);
}

static Il2CppString *rm_level_track_id(Il2CppString *levelId) {
    if (!levelId) return NULL;
    if (gTrackIdPrefix.length == 0 && gTrackIdSuffix.length == 0) return levelId;
    if (!il2cpp_string_new) return levelId;
    NSString *lv = rm_il2cpp_string_text(levelId);
    if (lv.length == 0) return levelId;
    NSString *full = [NSString stringWithFormat:@"%@%@%@", gTrackIdPrefix, lv, gTrackIdSuffix];
    return il2cpp_string_new(full.UTF8String);
}

// ---------------------------------------------------------------------------
// 选曲界面「开始」按钮自愈
//   PlayLevel 开头的两个拦截：
//     previewControl.nowAudioSource.ClipLength < 0.1  → 直接 return（点了没反应）
//     TrackUnlocked(前缀 + Level.id) == false        → 直接 return
//   这里把两者都补齐，并把每次变化写进日志。
// ---------------------------------------------------------------------------
static NSString *gLastPlayProbe = nil;
static int gLastDiscId = -1;
static CFTimeInterval gDiscSwitchUntil = 0;

// Disc 切换时会预热/加载整张盘的面板，这段时间不做解锁写入，避免和它抢主线程
static void rm_watch_disc_change(void) {
    if (!gSelectObj) return;
    int disc = *(int *)((char *)gSelectObj + 0x1B8);   // LevelSelectControl.selectedDiscId
    if (disc != gLastDiscId) {
        gLastDiscId = disc;
        gDiscSwitchUntil = CFAbsoluteTimeGetCurrent() + 3.0;
        RMLog(@"切换 Disc: %d", disc);
    }
}

// 一次性的存储诊断：确认歌曲资源到底有没有下载到本地
static void rm_log_storage_once(void) {
    static BOOL done = NO;
    if (done) return;
    done = YES;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *bases = @[
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"",
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"Application Support"] ?: @"",
    ];
    NSMutableString *out = [NSMutableString string];
    for (NSString *base in bases) {
        if (base.length == 0) continue;
        NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:base error:NULL];
        unsigned long long total = 0;
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (NSString *s in subs) {
            NSString *full = [base stringByAppendingPathComponent:s];
            unsigned long long sz = 0;
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:NULL];
            if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                NSArray *inner = [fm subpathsAtPath:full];
                for (NSString *f in inner) {
                    NSDictionary *a = [fm attributesOfItemAtPath:[full stringByAppendingPathComponent:f] error:NULL];
                    sz += [a[NSFileSize] unsignedLongLongValue];
                }
            } else {
                sz = [attrs[NSFileSize] unsignedLongLongValue];
            }
            total += sz;
            if (sz > 1024 * 1024) [parts addObject:[NSString stringWithFormat:@"%@=%.0fMB", s, sz / 1048576.0]];
        }
        [out appendFormat:@"%@ 合计 %.0fMB [%@]；", base.lastPathComponent, total / 1048576.0,
                          [parts componentsJoinedByString:@", "]];
    }
    RMLog(@"存储: %@", out.length ? out : @"(空)");
}

static void rm_watch_play_gate(void) {
    if (!gSelectObj || RMInLevel) return;

    void *sel = gSelectObj;
    void *preview = *(void **)((char *)sel + 0x100);            // LevelSelectControl.previewControl
    void *audio = preview ? *(void **)((char *)preview + 0x20) : NULL;   // PreviewControl.nowAudioSource
    float clipLen = audio ? *(float *)((char *)audio + 0xB8) : -1.0f;    // AddressableAudioSource.ClipLength
    void *level = *(void **)((char *)sel + 0x180);              // SelectedLevel
    Il2CppString *levelId = level ? *(Il2CppString **)((char *)level + 0x10) : NULL;

    if (audio && (!(clipLen >= 0.1f) || clipLen != clipLen)) {
        *(float *)((char *)audio + 0xB8) = 60.0f;
        RMLog(@"开始按钮: 预览音轨 ClipLength=%.2f，已补成 60", clipLen);
    }

    if (!levelId) return;

    // 选曲面板（BeginOpenLevel）用的是 Level.musicInfo.id；
    // 进关判定（PlayLevel）用的是 Level.id。两个都补齐。
    void *music = *(void **)((char *)level + 0x20);
    Il2CppString *musicId = music ? *(Il2CppString **)((char *)music + 0x10) : NULL;

    Il2CppString *trackId = rm_level_track_id(levelId);
    BOOL unlocked = rm_track_unlocked(trackId);
    BOOL musicUnlocked = musicId ? rm_track_unlocked(musicId) : NO;

    Il2CppObject *user = rm_payment_user();
    void *items = user ? *(void **)((char *)user + kOff_User_Items) : NULL;
    if (items) {
        if (!unlocked && rm_owned_add(items, trackId)) {
            unlocked = YES;
            RMLog(@"开始按钮: 补写曲目 id %@", rm_il2cpp_string_text(trackId) ?: @"?");
        }
        if (musicId && !musicUnlocked && rm_owned_add(items, musicId)) {
            musicUnlocked = YES;
            RMLog(@"开始按钮: 补写 musicId %@", rm_il2cpp_string_text(musicId) ?: @"?");
        }
    }

    uint8_t onPlay = *(uint8_t *)((char *)sel + 0x20C);
    NSString *probe = [NSString stringWithFormat:
                       @"选曲: level=%@ music=%@ onPlay=%d clip=%.1f unlocked=%d/%d",
                       rm_il2cpp_string_text(levelId) ?: @"-",
                       rm_il2cpp_string_text(musicId) ?: @"-",
                       onPlay, clipLen, unlocked ? 1 : 0, musicUnlocked ? 1 : 0];
    if (![probe isEqualToString:gLastPlayProbe]) {
        gLastPlayProbe = probe;
        RMLog(@"%@", probe);
    }
}

// ---------------------------------------------------------------------------
// 官方 Mods 面板位置（设置页 / 悬浮层把自定义开关贴在官方面板上）
// ---------------------------------------------------------------------------
static void rm_log_mods_rect(NSString *reason) {
    static NSString *last = nil;
    static CFTimeInterval lastTime = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (last && [last isEqualToString:reason] && now - lastTime < 10.0) return;
    last = reason;
    lastTime = now;
    RMLog(@"Mods 面板: %@", reason);
}

// ---------------------------------------------------------------------------
// 官方 Mod 按钮解锁
//   这些按钮在 Init 时按 ownedProducts 记录 isLocked，看起来像付费商品。
//   直接对每个实例跑一遍 Unlock()（清 isLocked、换图标、播解锁动画），
//   之后点击就是正常开关，不再弹购买。
// ---------------------------------------------------------------------------
static int rm_unlock_mod_buttons(void) {
    if (!gModBtnClass || !gFindObjectsM1 || !il2cpp_class_get_type || !il2cpp_type_get_object) {
        return 0;
    }
    Il2CppType *type = il2cpp_class_get_type(gModBtnClass);
    void *typeObj = type ? il2cpp_type_get_object(type) : NULL;
    if (!typeObj) return 0;
    Il2CppException *exc = NULL;
    void *args[1] = {typeObj};
    Il2CppObject *arr = il2cpp_runtime_invoke(gFindObjectsM1, NULL, args, &exc);
    if (exc || !arr) return 0;

    const MethodInfo *mUnlock = il2cpp_class_get_method_from_name(gModBtnClass, "Unlock", 0);
    if (!mUnlock) return 0;

    NSUInteger n = rm_array_count(arr);
    if (n > 256) n = 256;
    void **elems = (void **)((char *)arr + kOff_Array_Elements);
    int unlocked = 0;
    for (NSUInteger i = 0; i < n; i++) {
        void *btn = elems[i];
        if (!btn) continue;
        if (*(uint8_t *)((char *)btn + 0x98) == 0) continue;   // ModButtonControl.isLocked
        // 只处理当前真正显示着的面板，别去动预热中的隐藏面板（会让切盘流程卡住）
        void *btr = rm_call_obj0(btn, "get_transform");
        void *bgo = btr ? rm_call_obj0(btr, "get_gameObject") : NULL;
        if (!bgo || !rm_boxed_bool(rm_call_obj0(bgo, "get_activeInHierarchy"))) continue;
        Il2CppException *e2 = NULL;
        il2cpp_runtime_invoke(mUnlock, btn, NULL, &e2);
        if (!e2) unlocked++;
    }
    if (unlocked > 0) RMLog(@"官方 Mod 解锁: %d 个按钮", unlocked);
    return unlocked;
}

// ---------------------------------------------------------------------------
// 在官方 Mods 条里追加自定义按钮
//   克隆一个已初始化的 ModButtonControl（保留图标 / 动画 / 布局），挂到同一个父节点，
//   布局组会把它排在官方按钮后面；点击回调换成我们伪造的 Action<int> 委托。
// ---------------------------------------------------------------------------
static void rm_chip_tap(void *target, int32_t index) {
    int which = (int)index - 200;
    switch (which) {
        case 0: RMLockHP = !RMLockHP; break;
        case 1: RMUnlockAllSongs = !RMUnlockAllSongs; break;
        case 2: RMBallVisible = !RMBallVisible; break;
        default: return;
    }
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setBool:RMLockHP forKey:@"rm.hp"];
    [d setBool:RMUnlockAllSongs forKey:@"rm.unlock"];
    [d setBool:RMBallVisible forKey:@"rm.ball.show"];
    RMLog(@"自定义 Mod 点击: %d (锁血=%d 解锁=%d 球=%d)",
          which, RMLockHP, RMUnlockAllSongs, RMBallVisible);
    RMApplySettingsNow();
    RMUpdateBall();
}

// 复制一个现成的 Action<int> 委托对象，只把入口换成我们自己的 C 函数
static Il2CppObject *rm_clone_action_delegate(Il2CppObject *proto) {
    if (!proto || !il2cpp_object_new) return NULL;
    Il2CppClass *k = il2cpp_object_get_class(proto);
    if (!k) return NULL;
    Il2CppObject *d = (Il2CppObject *)il2cpp_object_new(k);
    if (!d) return NULL;
    memcpy((char *)d + 0x10, (char *)proto + 0x10, 0x60);
    *(void **)((char *)d + 0x10) = (void *)rm_chip_tap;   // method_ptr
    *(void **)((char *)d + 0x20) = (void *)1;             // m_target（占位，不用）
    return d;
}

static void *gCustomModsOwner = NULL;

static void rm_append_custom_mods(void) {
    if (!gModsClass || !gModBtnClass || !gObjectClass || !gGoClass || !gFindObjectsM1) return;

    Il2CppType *mt = il2cpp_class_get_type(gModsClass);
    void *mtObj = mt ? il2cpp_type_get_object(mt) : NULL;
    if (!mtObj) return;
    Il2CppException *exc = NULL;
    void *args[1] = {mtObj};
    Il2CppObject *modsArr = il2cpp_runtime_invoke(gFindObjectsM1, NULL, args, &exc);
    if (exc || !modsArr) return;

    NSUInteger n = rm_array_count(modsArr);
    if (n == 0 || n > 32) return;
    void **modsElems = (void **)((char *)modsArr + kOff_Array_Elements);

    for (NSUInteger i = 0; i < n; i++) {
        void *mods = modsElems[i];
        if (!mods || mods == gCustomModsOwner) continue;
        void *tr = rm_call_obj0(mods, "get_transform");
        void *go = tr ? rm_call_obj0(tr, "get_gameObject") : NULL;
        if (!go || !rm_boxed_bool(rm_call_obj0(go, "get_activeInHierarchy"))) continue;

        void *buttons = *(void **)((char *)mods + 0xD8);   // ModsControl.modButtons
        int count = buttons ? (int)rm_array_count(buttons) : 0;
        if (count <= 0) continue;
        void *tmpl = ((void **)((char *)buttons + kOff_Array_Elements))[count - 1];
        if (!tmpl) continue;

        void *tmplGo = rm_call_obj0(tmpl, "get_gameObject");
        void *tmplTr = rm_call_obj0(tmpl, "get_transform");
        void *parentTr = tmplTr ? rm_call_obj0(tmplTr, "get_parent") : NULL;
        Il2CppObject *proto = (Il2CppObject *)*(void **)((char *)tmpl + 0xA8);   // onClick
        if (!tmplGo || !parentTr || !proto) continue;

        const MethodInfo *mInst = il2cpp_class_get_method_from_name(gObjectClass, "Instantiate", 2);
        const MethodInfo *mGetComp = il2cpp_class_get_method_from_name(gGoClass, "GetComponent", 1);
        Il2CppType *bt = il2cpp_class_get_type(gModBtnClass);
        void *btObj = bt ? il2cpp_type_get_object(bt) : NULL;
        if (!mInst || !mGetComp || !btObj) return;

        Il2CppObject *delegate = rm_clone_action_delegate(proto);
        if (!delegate) { RMLog(@"自定义 Mod: 委托复制失败"); return; }

        // 官方这条 Mods 是手工布局（不是滑动列表），克隆体默认会叠在原位置，
        // 这里把它们的 anchoredPosition 排到最后那个按钮下面一行。
        float tmplX = 0, tmplY = 0, tmplW = 100, tmplH = 100;
        {
            Il2CppObject *rt = (Il2CppObject *)tmplTr;
            Il2CppObject *posObj = rm_call_obj0(rt, "get_anchoredPosition");
            Il2CppObject *sizeObj = rm_call_obj0(rt, "get_sizeDelta");
            if (posObj) {
                tmplX = *(float *)((char *)posObj + 0x10);
                tmplY = *(float *)((char *)posObj + 0x14);
            }
            if (sizeObj) {
                tmplW = *(float *)((char *)sizeObj + 0x10);
                tmplH = *(float *)((char *)sizeObj + 0x14);
            }
        }
        const MethodInfo *mSetPos = il2cpp_class_get_method_from_name(gRectTransformClass, "set_anchoredPosition", 1);

        int added = 0;
        for (int k = 0; k < 3; k++) {
            void *instArgs[2] = {tmplGo, parentTr};
            Il2CppException *e1 = NULL;
            Il2CppObject *cloneGo = il2cpp_runtime_invoke(mInst, NULL, instArgs, &e1);
            if (e1 || !cloneGo) break;
            void *compArgs[1] = {btObj};
            Il2CppException *e2 = NULL;
            Il2CppObject *comp = il2cpp_runtime_invoke(mGetComp, cloneGo, compArgs, &e2);
            if (e2 || !comp) break;
            *(int *)((char *)comp + 0x70) = 200 + k;     // modIndex
            *(uint8_t *)((char *)comp + 0x98) = 0;       // isLocked
            *(uint8_t *)((char *)comp + 0xD8) = 0;       // onUnlockPopup
            *(void **)((char *)comp + 0xA8) = delegate;  // onClick

            if (mSetPos && tmplW > 1 && tmplH > 1) {
                Il2CppObject *tr2 = rm_call_obj0(comp, "get_transform");
                if (tr2) {
                    // 官方那排上方新增一行：x 以模板为中心左右排开
                    struct { float x, y; } p = { tmplX + (float)(k - 1) * (tmplW + 8),
                                                 tmplY + tmplH + 8 };
                    Il2CppException *e3 = NULL;
                    void *pargs[1] = {&p};
                    il2cpp_runtime_invoke(mSetPos, tr2, pargs, &e3);
                }
            }
            const MethodInfo *mSetActive = il2cpp_class_get_method_from_name(gGoClass, "SetActive", 1);
            if (mSetActive) {
                uint8_t yes = 1;
                void *sargs[1] = {&yes};
                Il2CppException *e4 = NULL;
                il2cpp_runtime_invoke(mSetActive, cloneGo, sargs, &e4);
            }
            // 克隆体继承的是“收起”状态（灰色圆球），调 Expand() 让它变成正常图标
            const MethodInfo *mExpand = il2cpp_class_get_method_from_name(gModBtnClass, "Expand", 0);
            if (mExpand) {
                Il2CppException *e5 = NULL;
                il2cpp_runtime_invoke(mExpand, comp, NULL, &e5);
            }
            if (k == 0) {
                Il2CppObject *tr3 = rm_call_obj0(comp, "get_transform");
                Il2CppObject *wp = tr3 ? rm_call_obj0(tr3, "get_position") : NULL;
                if (wp) {
                    float wx = *(float *)((char *)wp + 0x10);
                    float wy = *(float *)((char *)wp + 0x14);
                    float wz = *(float *)((char *)wp + 0x18);
                    RMLog(@"自定义 Mod: 第1个克隆 world=(%.0f,%.0f,%.0f)", wx, wy, wz);
                }
            }
            added++;
        }
        gCustomModsOwner = mods;

        // 把官方 Mods 栏整体拉高一行，让新增的那排也在栏内
        if (tmplH > 1) {
            Il2CppObject *prt = rm_call_obj0(mods, "get_transform");
            Il2CppObject *psz = prt ? rm_call_obj0(prt, "get_sizeDelta") : NULL;
            Il2CppObject *pps = prt ? rm_call_obj0(prt, "get_anchoredPosition") : NULL;
            const MethodInfo *mSetSize = il2cpp_class_get_method_from_name(gRectTransformClass, "set_sizeDelta", 1);
            if (prt && psz && pps && mSetSize) {
                float sw = *(float *)((char *)psz + 0x10);
                float sh = *(float *)((char *)psz + 0x14);
                float ax = *(float *)((char *)pps + 0x10);
                float ay = *(float *)((char *)pps + 0x14);
                struct { float x, y; } ns = { sw, sh + tmplH + 12 };
                struct { float x, y; } np = { ax, ay + (tmplH + 12) / 2 };
                Il2CppException *e6 = NULL, *e7 = NULL;
                void *a1[1] = {&ns};
                il2cpp_runtime_invoke(mSetSize, prt, a1, &e6);
                void *a2[1] = {&np};
                if (mSetPos) il2cpp_runtime_invoke(mSetPos, prt, a2, &e7);
                RMLog(@"自定义 Mod: 面板加高 %.0f（原 %.0f×%.0f）", tmplH + 12, sw, sh);
            }
        }
        RMLog(@"自定义 Mod: 追加 %d 个按钮（锁血 / 解锁 / 球）", added);
        return;
    }
}


BOOL RMModsPanelPresent(void) {
    if (!gModsClass || !gFindObjectsM1 || !il2cpp_class_get_type || !il2cpp_type_get_object) return NO;
    Il2CppType *type = il2cpp_class_get_type(gModsClass);
    void *typeObj = type ? il2cpp_type_get_object(type) : NULL;
    if (!typeObj) return NO;
    Il2CppException *exc = NULL;
    void *args[1] = {typeObj};
    Il2CppObject *arr = il2cpp_runtime_invoke(gFindObjectsM1, NULL, args, &exc);
    if (exc || !arr) return NO;
    return rm_array_count(arr) > 0;
}

BOOL RMModsPanelScreenRect(CGRect *outRect) {
    if (!outRect) return NO;
    if (!gModsClass || !gFindObjectsM1 || !il2cpp_class_get_type || !il2cpp_type_get_object) {
        rm_log_mods_rect(@"缺少 ModsControl / FindObjectsOfType");
        return NO;
    }
    Il2CppType *type = il2cpp_class_get_type(gModsClass);
    void *typeObj = type ? il2cpp_type_get_object(type) : NULL;
    if (!typeObj) { rm_log_mods_rect(@"ModsControl 类型对象缺失"); return NO; }

    Il2CppException *exc = NULL;
    void *args[1] = {typeObj};
    Il2CppObject *arr = il2cpp_runtime_invoke(gFindObjectsM1, NULL, args, &exc);
    if (exc || !arr) { rm_log_mods_rect(@"FindObjectsOfType 失败"); return NO; }

    NSUInteger n = rm_array_count(arr);
    if (n == 0) { rm_log_mods_rect(@"未找到 ModsControl"); return NO; }
    if (n > 64) n = 64;

    CGSize screen = UIScreen.mainScreen.bounds.size;
    void **elems = (void **)((char *)arr + kOff_Array_Elements);
    NSString *lastReason = @"无可用实例";
    for (NSUInteger i = 0; i < n; i++) {
        void *mods = elems[i];
        if (!mods) continue;
        void *tr = rm_call_obj0(mods, "get_transform");
        void *go = tr ? rm_call_obj0(tr, "get_gameObject") : NULL;
        if (!go || !rm_boxed_bool(rm_call_obj0(go, "get_activeInHierarchy"))) continue;

        Il2CppObject *posObj = rm_call_obj0(tr, "get_position");
        Il2CppObject *scaleObj = rm_call_obj0(tr, "get_lossyScale");
        Il2CppObject *rectObj = rm_call_obj0(tr, "get_rect");
        if (!posObj || !scaleObj || !rectObj) { lastReason = @"属性读取失败"; continue; }

        float px = *(float *)((char *)posObj + 0x10);
        float py = *(float *)((char *)posObj + 0x14);
        float sx = *(float *)((char *)scaleObj + 0x10);
        float sy = *(float *)((char *)scaleObj + 0x14);
        float rw = *(float *)((char *)rectObj + 0x18);
        float rh = *(float *)((char *)rectObj + 0x1C);
        if (!(rw > 0) || !(rh > 0) || !(sx > 0) || !(sy > 0)) {
            lastReason = [NSString stringWithFormat:@"数值无效 pos=(%.0f,%.0f) scale=(%.2f,%.2f) rect=(%.0f,%.0f)",
                          px, py, sx, sy, rw, rh];
            continue;
        }

        CGFloat w = rw * sx;
        CGFloat h = rh * sy;
        CGRect r = CGRectMake(px - w / 2, screen.height - py - h / 2, w, h);
        if (r.size.width < 40 || r.size.width > screen.width * 2) {
            lastReason = [NSString stringWithFormat:@"尺寸异常 %.0f×%.0f", w, h];
            continue;
        }
        if (r.origin.y < -600 || r.origin.y > screen.height + 600) {
            lastReason = [NSString stringWithFormat:@"位置异常 (%.0f,%.0f)", r.origin.x, r.origin.y];
            continue;
        }
        *outRect = r;
        return YES;
    }
    rm_log_mods_rect(lastReason);
    return NO;
}

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------
void RMApplySettingsNow(void) {
    if (!RMIl2CppReady || !RMGameReady) return;
    rm_apply_mods();
    if (RMUnlockAllSongs) rm_apply_unlock();
}

static CFTimeInterval gStartTime = 0;
static CFTimeInterval gLastUiScan = 0;
static BOOL gLoggedNoGameReady = NO;

static void rm_runtime_tick(void) {
    if (!RMIl2CppReady) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (gStartTime == 0) gStartTime = now;

    if (!gInfoClass || !gJudgeClass || (!gFindTypeM2 && !gFindTypeM1)) {
        if (now - gLastResolve > 2.0) {
            gLastResolve = now;
            rm_setup_classes();
        }
        if (!gInfoClass) return;
    }

    if (now - gLastFind > 0.5) {
        gLastFind = now;
        rm_refresh_objects();
    }

    // 诊断：抓屏幕文本，定位 SDK / 登录报错原文
    CFTimeInterval scanInterval = RMGameReady ? 30.0 : 5.0;
    if (now - gLastUiScan > scanInterval) {
        gLastUiScan = now;
        rm_scan_unity_texts();
        rm_scan_uikit_texts();
        if (!RMGameReady && !gLoggedNoGameReady && now - gStartTime > 20.0) {
            gLoggedNoGameReady = YES;
            RMLog(@"启动 %.0f 秒仍未检测到游戏主界面；若停在报错页，请把上面的界面文本发我", now - gStartTime);
        }
    }

    if (!RMGameReady) return;

    rm_log_storage_once();
    rm_watch_disc_change();
    rm_pin_life_fast();

    if (now - gLastApply > 0.5) {
        gLastApply = now;
        rm_apply_mods();
        rm_watch_play_gate();
    }

    if (now - gLastModUnlock > 2.0) {
        gLastModUnlock = now;
        if (!RMInLevel) rm_unlock_mod_buttons();
        // 自定义克隆按钮先停用：它会在官方面板里留一个灰色圆球，且结算有概率闪退
        // rm_append_custom_mods();
    }

    static CFTimeInterval lastBeat = 0;
    if (now - lastBeat > 10.0) {
        lastBeat = now;
        RMLog(@"心跳: 主线程正常 inLevel=%d disc=%d", RMInLevel ? 1 : 0, gLastDiscId);
    }

    // 结算期间和刚出关的几秒内不做解锁写入，避免和存档/结算抢数据
    double sincePlay = CFAbsoluteTimeGetCurrent() - RMLastGameplayTick;
    if (RMUnlockAllSongs && now - gLastUnlock > 5.0 && now > gDiscSwitchUntil &&
        !RMInLevel && sincePlay > 6.0) {
        gLastUnlock = now;
        if (!gLevelCtlObj) rm_refresh_objects();
        rm_apply_unlock();
    }
}

@interface RMRuntimeTicker : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@end

static RMRuntimeTicker *gRuntimeTicker = nil;

@implementation RMRuntimeTicker
- (void)tick:(CADisplayLink *)link { rm_runtime_tick(); }
@end

void RMStartRuntimeFeatures(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!rm_resolve_il2cpp()) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ RMStartRuntimeFeatures(); });
            return;
        }
        rm_setup_classes();
        if (!gRuntimeTicker) {
            gRuntimeTicker = [RMRuntimeTicker new];
            gRuntimeTicker.link = [CADisplayLink displayLinkWithTarget:gRuntimeTicker
                                                              selector:@selector(tick:)];
            [gRuntimeTicker.link addToRunLoop:[NSRunLoop mainRunLoop]
                                      forMode:NSRunLoopCommonModes];
        }
        RMLog(@"运行时轮询已启动（反射 + 字段写入，不改代码页）");
    });
}
