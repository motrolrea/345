#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// 全局开关（由设置页修改，运行时轮询中读取）
extern bool RMAutoPlay;        // 官方 AutoPlay：自动打歌（MaxPerfect）
extern bool RMNoBad;           // 官方 NoBad：Bad 不扣血 / 不中断
extern bool RMFreeHold;        // 官方 FreeHold：长条自由松手
extern bool RMLockHP;          // 锁血：保持满血
extern bool RMUnlockAllSongs;  // 全曲解锁（本地）

// 最近一次判定帧（用于判断是否在游玩中）
extern volatile double RMLastGameplayTick;

// 悬浮球
extern bool RMBallVisible;
extern bool RMAutoHideInGame;
extern float RMBallAlpha;
extern float RMBallSize;

// 诊断
extern volatile int RMLastNoteCount;
extern volatile int RMLastLevelIdCount;
extern volatile bool RMIl2CppReady;
extern volatile bool RMUnlockAllApplied;
extern volatile bool RMInLevel;
extern volatile bool RMGameReady;

void RMLog(NSString *fmt, ...);
void RMLogInstallCrashHandler(void);
void RMLogReset(void);
NSString *RMLogTail(NSUInteger maxLines);
void RMLogClear(void);
int RMUnityCryptid(void);
NSString *RMUnityUUIDString(void);
void *RMUnityBase(void);
void RMApplySettingsNow(void);
void RMStartRuntimeFeatures(void);

void RMShowOverlay(void);
void RMUpdateBall(void);

// 拦截成绩上传（返回本地假 200）
void RMInstallUploadBlocker(void);

// 官方 Mods 面板当前的屏幕区域（Unity 坐标换算成 UIKit 坐标）；面板收起时返回 NO
BOOL RMModsPanelScreenRect(CGRect *outRect);
// 当前场景里是否存在官方 Mods 面板（用于决定是否显示自定义开关条）
BOOL RMModsPanelPresent(void);

#ifdef __cplusplus
}
#endif
