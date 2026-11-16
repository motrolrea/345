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
//    getaddrinfo() 拦截 rizserver.pigeongames.net      离线模式（成绩不上传）
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
bool RMNoBad = false;
bool RMFreeHold = false;
bool RMLockHP = false;
bool RMUnlockAllSongs = false;
bool RMBlockUpload = false;

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
volatile int RMUploadBlocked = 0;

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
static void (*il2cpp_runtime_class_init)(Il2CppClass *);
static uint32_t (*il2cpp_gchandle_new)(Il2CppObject *, bool);
static void (*il2cpp_gchandle_free)(uint32_t);

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
    il2cpp_runtime_class_init = (__typeof__(il2cpp_runtime_class_init))dlsym(h, "il2cpp_runtime_class_init");
    il2cpp_gchandle_new = (__typeof__(il2cpp_gchandle_new))dlsym(h, "il2cpp_gchandle_new");
    il2cpp_gchandle_free = (__typeof__(il2cpp_gchandle_free))dlsym(h, "il2cpp_gchandle_free");
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
static Il2CppClass *gSelectClass = NULL;
static Il2CppClass *gObjectClass = NULL;

static const MethodInfo *gFindTypeM2 = NULL;
static const MethodInfo *gFindTypeM1 = NULL;

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

static CFTimeInterval gLastFind = 0;
static CFTimeInterval gLastApply = 0;
static CFTimeInterval gLastUnlock = 0;
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
    gSelectClass = rm_find_class_any("LevelSelectControl");
    gObjectClass = rm_find_class_ns("UnityEngine", "Object");

    if (il2cpp_runtime_class_init && gPaymentClass) {
        il2cpp_runtime_class_init(gPaymentClass);
    }

    if (gObjectClass) {
        gFindTypeM2 = il2cpp_class_get_method_from_name(gObjectClass, "FindObjectOfType", 2);
        if (!gFindTypeM2) {
            gFindTypeM1 = il2cpp_class_get_method_from_name(gObjectClass, "FindObjectOfType", 1);
        }
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
    // 官方 Mod 静态状态：让结算把本局标记成 Mod 游玩
    if (gModsClass) {
        rm_call_static_bool(gModsClass, "set_AutoPlay", RMAutoPlay);
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
        rm_obj_set_bool(judge, kOff_Judge_AutoPlay, RMAutoPlay);
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
        rm_obj_set_bool(gNormalObj, kOff_Normal_AutoPlayField, RMAutoPlay);
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
// 全曲解锁：把 LevelControl 的所有 id 塞进 PaymentService.ownedTracks
// ---------------------------------------------------------------------------
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
    if (!items || count <= 0) return;
    if (count > 20000) return;

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

    int added = 0;
    for (int i = 0; i < count; i++) {
        Il2CppString *sid = (Il2CppString *)items[i];
        if (!sid) continue;
        if (!rm_list_contains(owned, sid)) {
            rm_list_add(owned, sid);
            added++;
        }
        if (vip) rm_hashset_add(vip, sid);
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
            }
            count += discCount;
        }
    }

    RMLastLevelIdCount = count;
    RMUnlockAllApplied = true;
    if (added > 0) {
        RMLog(@"全曲解锁: 新增 %d / 共 %d 首", added, count);
        // 让选曲界面重新检查一次锁图标
        rm_call_static_void(gSelectClass, "RefreshAllPurchasableLocksGlobal");
    }
}

// ---------------------------------------------------------------------------
// 离线模式：拦截 rizserver.pigeongames.net 的 DNS 解析
// ---------------------------------------------------------------------------
static int (*gRealGetaddrinfo)(const char *, const char *, const struct addrinfo *, struct addrinfo **) = NULL;

static int rm_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **res) {
    if (RMBlockUpload && node && strstr(node, "rizserver.pigeongames.net")) {
        RMUploadBlocked = RMUploadBlocked + 1;
        RMLog(@"离线模式已拦截成绩服务器: %s", node);
        return EAI_NONAME;
    }
    if (!gRealGetaddrinfo) {
        gRealGetaddrinfo = (__typeof__(gRealGetaddrinfo))dlsym(RTLD_DEFAULT, "getaddrinfo");
    }
    if (!gRealGetaddrinfo) return EAI_FAIL;
    return gRealGetaddrinfo(node, service, hints, res);
}

#define RM_DYLD_INTERPOSE(_replacement, _replacee)                                      \
    __attribute__((used)) static struct {                                               \
        const void *replacement;                                                        \
        const void *replacee;                                                           \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = {         \
        (const void *)(unsigned long)&_replacement,                                     \
        (const void *)(unsigned long)&_replacee};

RM_DYLD_INTERPOSE(rm_getaddrinfo, getaddrinfo)

// ---------------------------------------------------------------------------
// 对外接口
// ---------------------------------------------------------------------------
void RMApplySettingsNow(void) {
    if (!RMIl2CppReady) return;
    rm_apply_mods();
    if (RMUnlockAllSongs) rm_apply_unlock();
}

static void rm_runtime_tick(void) {
    if (!RMIl2CppReady) return;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();

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

    rm_pin_life_fast();

    if (now - gLastApply > 0.5) {
        gLastApply = now;
        rm_apply_mods();
    }

    if (RMUnlockAllSongs && now - gLastUnlock > 2.0) {
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
