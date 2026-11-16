//
//  RizlineMod 入口：dylib 构造时启动，等 Unity/il2cpp 就绪后启动轮询与悬浮球
//

#import "RMCommon.h"

__attribute__((constructor))
static void RMBootstrap(void) {
    RMLogReset();              // 每次启动重新生成日志
    RMLogInstallCrashHandler();
    NSBundle *bundle = [NSBundle mainBundle];
    RMLog(@"启动: %@ %@ (%@)", bundle.bundleIdentifier,
          [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
          [bundle objectForInfoDictionaryKey:@"CFBundleVersion"]);

    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    RMAutoPlay       = [d objectForKey:@"rm.auto"] ? [d boolForKey:@"rm.auto"] : YES;
    RMNoBad          = [d boolForKey:@"rm.nobad"];
    RMFreeHold       = [d boolForKey:@"rm.freehold"];
    RMLockHP         = [d boolForKey:@"rm.hp"];
    RMUnlockAllSongs = [d boolForKey:@"rm.unlock"];
    RMBlockUpload    = [d boolForKey:@"rm.block"];
    RMBallVisible    = [d objectForKey:@"rm.ball.show"] ? [d boolForKey:@"rm.ball.show"] : YES;
    RMAutoHideInGame = [d objectForKey:@"rm.ball.auto"] ? [d boolForKey:@"rm.ball.auto"] : YES;
    RMBallAlpha      = [d objectForKey:@"rm.ball.alpha"] ? [d floatForKey:@"rm.ball.alpha"] : 0.85f;
    RMBallSize       = [d objectForKey:@"rm.ball.size"] ? [d floatForKey:@"rm.ball.size"] : 56.0f;
    if (RMBallSize < 40.0f || RMBallSize > 96.0f) RMBallSize = 56.0f;

    RMLog(@"dylib 已加载（2.7.1 基线），autoplay=%d nobad=%d freehold=%d hp=%d unlock=%d block=%d",
          RMAutoPlay, RMNoBad, RMFreeHold, RMLockHP, RMUnlockAllSongs, RMBlockUpload);

    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RMShowOverlay();
        });
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            RMLog(@"启动运行时轮询 cryptid=%d uuid=%@", RMUnityCryptid(), RMUnityUUIDString());
            RMStartRuntimeFeatures();
        });
    });
}
