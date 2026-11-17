//
//  RizlineMod 网络层：拦截成绩上传，直接返回本地假响应
//  游戏上传成绩 → 看到 HTTP 200 + {"code":0,...} → 认为成功，不再重试
//

#import "RMCommon.h"
#import <Foundation/Foundation.h>

static BOOL rm_is_upload_request(NSURLRequest *req) {
    if (![req.HTTPMethod isEqualToString:@"POST"]) return NO;
    NSString *host = req.URL.host.lowercaseString ?: @"";
    if (![host containsString:@"pigeongames"]) return NO;
    NSString *path = req.URL.path.lowercaseString ?: @"";
    static NSArray<NSString *> *keys = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[@"result", @"play", @"score", @"submit", @"upload", @"record"];
    });
    for (NSString *k in keys) {
        if ([path containsString:k]) return YES;
    }
    return NO;
}

@interface RMAntiUploadProtocol : NSURLProtocol
@end

@implementation RMAntiUploadProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"RMHandled" inRequest:request]) return NO;
    return rm_is_upload_request(request);
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURLRequest *req = self.request;
    RMLog(@"已拦截成绩上传: %@ %@", req.HTTPMethod, req.URL.absoluteString);

    NSData *body = [@"{\"code\":0,\"message\":\"ok\",\"data\":{}}"
                        dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
        initWithURL:req.URL
         statusCode:200
        HTTPVersion:@"HTTP/1.1"
       headerFields:@{@"Content-Type": @"application/json",
                      @"Content-Length": @(body.length).stringValue}];
    id<NSURLProtocolClient> client = self.client;
    [client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [client URLProtocol:self didLoadData:body];
    [client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {}

@end

void RMInstallUploadBlocker(void) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    [NSURLProtocol registerClass:[RMAntiUploadProtocol class]];
    RMLog(@"假上传服务已启用（本地直接返回 200 {\"code\":0}）");
}

// ---------------------------------------------------------------------------
// 资源下载器
//   catalog.json 里的 bundle 地址是占位前缀 http://rizastcdn.pigeongames.cn/default/…
//   实际地址 = {dis.resourceUrl}/{相对路径}，下载到 Documents/com.unity.addressables/aa/iOS
// ---------------------------------------------------------------------------
static NSString *rm_json_string(id obj, NSString *key) {
    if ([obj isKindOfClass:NSDictionary.class]) {
        id v = ((NSDictionary *)obj)[key];
        if ([v isKindOfClass:NSString.class]) return v;
        for (id sub in ((NSDictionary *)obj).allValues) {
            NSString *r = rm_json_string(sub, key);
            if (r) return r;
        }
    } else if ([obj isKindOfClass:NSArray.class]) {
        for (id sub in (NSArray *)obj) {
            NSString *r = rm_json_string(sub, key);
            if (r) return r;
        }
    }
    return nil;
}

static NSString *rm_resource_cache_dir(void) {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *d = [dirs.firstObject stringByAppendingPathComponent:@"com.unity.addressables/aa/iOS"];
    [NSFileManager.defaultManager createDirectoryAtPath:d
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:NULL];
    return d;
}

static NSString *rm_fetch_resource_base(void) {
    __block NSString *base = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURL *u = [NSURL URLWithString:@"https://rizserver.pigeongames.net/game/server_api/v1/dis"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 15;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (data) {
            id j = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            base = rm_json_string(j, @"resourceUrl");
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (!base) base = @"https://rizlineasset.pigeongames.net/versions/v140_2_7_1_dce216eb11P";
    return base;
}

void RMStartResourceDownload(void) {
    static BOOL running = NO;
    if (running) {
        RMLog(@"资源下载: 已经在跑了");
        return;
    }
    running = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @autoreleasepool {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *catalogPath = [[NSBundle mainBundle] pathForResource:@"catalog"
                                                                    ofType:@"json"
                                                               inDirectory:@"Data/Raw/aa"];
            NSData *cd = catalogPath ? [NSData dataWithContentsOfFile:catalogPath] : nil;
            if (!cd) {
                RMLog(@"资源下载: 找不到 catalog.json");
                running = NO;
                return;
            }
            NSDictionary *cat = [NSJSONSerialization JSONObjectWithData:cd options:0 error:NULL];
            NSArray *ids = [cat isKindOfClass:NSDictionary.class] ? cat[@"m_InternalIds"] : nil;
            if (![ids isKindOfClass:NSArray.class]) {
                RMLog(@"资源下载: catalog 里没有 m_InternalIds");
                running = NO;
                return;
            }

            NSString *base = rm_fetch_resource_base();
            NSString *cache = rm_resource_cache_dir();
            RMLog(@"资源下载: 资源根 %@，缓存目录 %@，条目 %lu",
                  base, cache.lastPathComponent, (unsigned long)ids.count);

            NSString *placeholder = @"http://rizastcdn.pigeongames.cn/default/";
            NSInteger total = 0, skipped = 0, ok = 0, failed = 0;
            for (NSString *raw in ids) {
                if (![raw isKindOfClass:NSString.class]) continue;
                if (![raw containsString:@".bundle"]) continue;
                NSString *urlStr = nil;
                if ([raw hasPrefix:placeholder]) {
                    urlStr = [base stringByAppendingFormat:@"/%@", [raw substringFromIndex:placeholder.length]];
                } else if ([raw hasPrefix:@"http"]) {
                    urlStr = raw;
                } else {
                    continue;
                }
                total++;
                NSString *name = urlStr.lastPathComponent;
                if (name.length == 0) continue;
                NSString *dest = [cache stringByAppendingPathComponent:name];
                if ([fm fileExistsAtPath:dest]) { skipped++; continue; }

                NSURL *u = [NSURL URLWithString:urlStr];
                if (!u) { failed++; continue; }
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                __block BOOL good = NO;
                NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
                req.timeoutInterval = 30;
                [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    if (data.length > 0 && !err) {
                        good = [data writeToFile:dest atomically:YES];
                    }
                    dispatch_semaphore_signal(sem);
                }] resume];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)));
                if (good) ok++; else failed++;
                if ((ok + failed) % 20 == 0) {
                    RMLog(@"资源下载: %ld/%ld（成功 %ld 失败 %ld 已有 %ld）",
                          (long)(ok + failed), (long)total, (long)ok, (long)failed, (long)skipped);
                }
            }
            RMLog(@"资源下载完成: 共 %ld，成功 %ld，失败 %ld，已存在 %ld",
                  (long)total, (long)ok, (long)failed, (long)skipped);
            running = NO;
        }
    });
}
