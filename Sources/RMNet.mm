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
