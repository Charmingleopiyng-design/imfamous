#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <netdb.h>
#import <sys/socket.h>
#import <arpa/inet.h>

static NSMutableDictionary<NSString *, NSString *> *gMap;   // lowercase old host -> new host
static NSMutableArray<NSString *> *gLines;
static NSMutableSet *gHooked;
static NSString *gLogPath;
static int gRedirects = 0, gHooksOK = 0, gHooksMissing = 0;
static int gStage = 0;        // 0 = all hooks ... 5 = nothing (raised automatically after a crash)
static int gForceStage = -1;  // from redirects.cfg: force_stage=N

#pragma mark - overlay window

@interface RRWindow : UIWindow
- (void)rrDismiss;
@end
@implementation RRWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil; // let touches reach the game
    return v;
}
- (void)rrDismiss { self.hidden = YES; }
@end

static RRWindow *gWin;
static UILabel *gTitle;
static UITextView *gText;
static int gTries = 0;

static BOOL RRIsOK(void) { return gHooksOK > 0 && gMap.count > 0; }

static void RRRefresh(void) {
    if (!gWin) return;
    BOOL ok = RRIsOK();
    gTitle.text = [NSString stringWithFormat:@" RecRedirect %@  hooks:%d  redirects:%d  safe-stage:%d",
                   ok ? @"LOADED \u2713" : @"FAILED \u2717", gHooksOK, gRedirects, gStage];
    gTitle.backgroundColor = ok ? [UIColor colorWithRed:0 green:0.55 blue:0.15 alpha:1]
                                : [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:1];
    @synchronized (gLines) { gText.text = [gLines componentsJoinedByString:@"\n"]; }
    [gText scrollRangeToVisible:NSMakeRange(gText.text.length, 0)];
}

static void RRShowOverlay(void) {
    if (gWin) return;
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene && gTries < 12) {   // scene not connected yet, try again shortly
        gTries++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RRShowOverlay(); });
        return;
    }
    CGRect b = scene ? scene.coordinateSpace.bounds : UIScreen.mainScreen.bounds;
    gWin = scene ? [[RRWindow alloc] initWithWindowScene:scene] : [[RRWindow alloc] initWithFrame:b];
    gWin.frame = b;
    gWin.windowLevel = UIWindowLevelAlert + 100;
    gWin.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gWin.rootViewController = vc;

    CGFloat w = MIN(b.size.width - 16, 580);
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(8, 36, w, 230)];
    box.layer.cornerRadius = 10; box.clipsToBounds = YES;
    box.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];

    gTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, w, 30)];
    gTitle.font = [UIFont boldSystemFontOfSize:14];
    gTitle.textColor = UIColor.whiteColor;
    [box addSubview:gTitle];

    gText = [[UITextView alloc] initWithFrame:CGRectMake(0, 30, w, 200)];
    gText.backgroundColor = UIColor.clearColor;
    gText.textColor = [UIColor greenColor];
    gText.font = [UIFont fontWithName:@"Menlo" size:10.5];
    gText.editable = NO;
    [box addSubview:gText];

    UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:gWin action:@selector(rrDismiss)];
    t.numberOfTapsRequired = 2;   // double tap to close
    [box addGestureRecognizer:t];

    [vc.view addSubview:box];
    gWin.hidden = NO;
    RRRefresh();

    if (RRIsOK()) {  // auto-hide after 30s when everything is fine; stays up on failure
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ if (RRIsOK()) gWin.hidden = YES; });
    }
}

#pragma mark - logging

static void RRLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:a];
    va_end(a);
    NSLog(@"[RecRedirect] %@", m);
    @synchronized (gLines) {
        [gLines addObject:m];
        if (gLines.count > 60) [gLines removeObjectAtIndex:0];
        if (gLogPath) {
            NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            if (!h) {
                [@"" writeToFile:gLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                h = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
            }
            [h seekToEndOfFile];
            [h writeData:[[m stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [h closeFile];
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{ RRRefresh(); });
}

#pragma mark - rewriting

static NSString *RR(NSString *s) {   // whole-string rewrite (for URLWithString: etc.)
    if (![s isKindOfClass:NSString.class] || s.length == 0 || gMap.count == 0) return s;
    NSString *out = s;
    for (NSString *old in gMap) {
        if ([out rangeOfString:old options:NSCaseInsensitiveSearch].location != NSNotFound)
            out = [out stringByReplacingOccurrencesOfString:old withString:gMap[old]
                                                    options:NSCaseInsensitiveSearch
                                                      range:NSMakeRange(0, out.length)];
    }
    if (![out isEqualToString:s]) { gRedirects++; RRLog(@"REDIRECT #%d: %@ -> %@", gRedirects, s, out); }
    return out;
}

static NSURL *RRURL(NSURL *u) {
    if (![u isKindOfClass:NSURL.class] || gMap.count == 0) return u;
    NSString *to = gMap[u.host.lowercaseString ?: @""];
    if (!to) return u;
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    c.host = to;
    NSURL *n = c.URL;
    if (!n) return u;
    gRedirects++;
    RRLog(@"REDIRECT #%d: %@ -> %@", gRedirects, u.absoluteString, n.absoluteString);
    return n;
}

static NSURLRequest *RRReq(NSURLRequest *r) {
    if (![r isKindOfClass:NSURLRequest.class]) return r;
    NSURL *n = RRURL(r.URL);
    if (n == r.URL) return r;
    NSMutableURLRequest *m = [r mutableCopy];
    m.URL = n;
    return m;
}

#pragma mark - hook helpers

static void Hook(Class c, SEL s, id (^mk)(IMP orig)) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { gHooksMissing++; return; }
    NSValue *key = [NSValue valueWithPointer:m];
    if ([gHooked containsObject:key]) return;     // inherited method already hooked
    [gHooked addObject:key];
    method_setImplementation(m, imp_implementationWithBlock(mk(method_getImplementation(m))));
    gHooksOK++;
}

static void HookStr1(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSString *a){ return ((id(*)(id,SEL,id))o)(self, s, RR(a)); }; }); }
static void HookStr2(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSString *a, id b){ return ((id(*)(id,SEL,id,id))o)(self, s, RR(a), b); }; }); }
static void HookURL1(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSURL *a){ return ((id(*)(id,SEL,id))o)(self, s, RRURL(a)); }; }); }
static void HookURL2(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSURL *a, id b){ return ((id(*)(id,SEL,id,id))o)(self, s, RRURL(a), b); }; }); }
static void HookReq1(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSURLRequest *a){ return ((id(*)(id,SEL,id))o)(self, s, RRReq(a)); }; }); }
static void HookReq2(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSURLRequest *a, id b){ return ((id(*)(id,SEL,id,id))o)(self, s, RRReq(a), b); }; }); }
static void HookReq3(Class c, SEL s) { Hook(c, s, ^id(IMP o){ return ^id(id self, NSURLRequest *a, id b, id d){ return ((id(*)(id,SEL,id,id,id))o)(self, s, RRReq(a), b, d); }; }); }

static void InstallHooks(void) {
    gHooked = [NSMutableSet new];
    Class urlMeta = object_getClass(NSURL.class);
    Class reqMeta = object_getClass(NSURLRequest.class);

    if (gStage <= 0) {   // NSURL creation
        HookStr1(urlMeta, @selector(URLWithString:));
        HookStr2(urlMeta, @selector(URLWithString:relativeToURL:));
        HookStr1(NSURL.class, @selector(initWithString:));
        HookStr2(NSURL.class, @selector(initWithString:relativeToURL:));
    }

    if (gStage <= 1) {   // NSURLRequest creation
        HookURL1(reqMeta, @selector(requestWithURL:));
        HookURL1(NSURLRequest.class, @selector(initWithURL:));
        Hook(reqMeta, @selector(requestWithURL:cachePolicy:timeoutInterval:), ^id(IMP o){
            return ^id(id self, NSURL *u, NSUInteger p, NSTimeInterval t){
                return ((id(*)(id,SEL,id,NSUInteger,NSTimeInterval))o)(self, @selector(requestWithURL:cachePolicy:timeoutInterval:), RRURL(u), p, t); }; });
        Hook(NSURLRequest.class, @selector(initWithURL:cachePolicy:timeoutInterval:), ^id(IMP o){
            return ^id(id self, NSURL *u, NSUInteger p, NSTimeInterval t){
                return ((id(*)(id,SEL,id,NSUInteger,NSTimeInterval))o)(self, @selector(initWithURL:cachePolicy:timeoutInterval:), RRURL(u), p, t); }; });
    }

    if (gStage <= 2) {   // mutable request setter
        Hook(NSMutableURLRequest.class, @selector(setURL:), ^id(IMP o){
            return ^void(id self, NSURL *u){ ((void(*)(id,SEL,id))o)(self, @selector(setURL:), RRURL(u)); }; });
    }

    if (gStage <= 3) {   // NSURLSession tasks (the safest, most targeted layer)
        NSURLSession *tmp = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
        NSArray<Class> *sess = @[NSURLSession.class, object_getClass(tmp)];
        for (Class c in sess) {
            HookURL1(c, @selector(dataTaskWithURL:));
            HookURL2(c, @selector(dataTaskWithURL:completionHandler:));
            HookURL1(c, @selector(downloadTaskWithURL:));
            HookURL2(c, @selector(downloadTaskWithURL:completionHandler:));
            HookURL1(c, @selector(webSocketTaskWithURL:));
            HookReq1(c, @selector(dataTaskWithRequest:));
            HookReq2(c, @selector(dataTaskWithRequest:completionHandler:));
            HookReq1(c, @selector(downloadTaskWithRequest:));
            HookReq2(c, @selector(downloadTaskWithRequest:completionHandler:));
            HookReq1(c, @selector(webSocketTaskWithRequest:));
            HookReq2(c, @selector(uploadTaskWithRequest:fromData:));
            HookReq2(c, @selector(uploadTaskWithRequest:fromFile:));
            HookReq3(c, @selector(uploadTaskWithRequest:fromData:completionHandler:));
            HookReq3(c, @selector(uploadTaskWithRequest:fromFile:completionHandler:));
        }
        [tmp finishTasksAndInvalidate];
    }
    RRLog(@"safe-stage %d: hooks installed: %d (optional/missing: %d)", gStage, gHooksOK, gHooksMissing);
}

#pragma mark - DNS interpose (fallback for raw sockets, e.g. Mono/IL2CPP System.Net)

#ifdef RR_ENABLE_DNS
static int rr_getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res) {
    if (node && gMap.count) {
        NSString *h = [NSString stringWithUTF8String:node];
        NSString *to = h ? gMap[h.lowercaseString] : nil;
        if (to) {
            gRedirects++;
            RRLog(@"DNS REDIRECT #%d: %s -> %@", gRedirects, node, to);
            return getaddrinfo(to.UTF8String, service, hints, res);
        }
    }
    return getaddrinfo(node, service, hints, res);
}

typedef struct { const void *replacement; const void *replacee; } rr_interpose_t;
__attribute__((used)) static const rr_interpose_t rr_interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)rr_getaddrinfo, (const void *)getaddrinfo },
};
#endif   // RR_ENABLE_DNS (off by default; build with GCC_PREPROCESSOR_DEFINITIONS=RR_ENABLE_DNS=1 to turn on)

#pragma mark - config

static void RRLoadConfig(void);

// Folder this framework was loaded from, found from the loaded image itself.
static NSString *RRFrameworkDir(void) {
    Dl_info info;
    if (dladdr((void *)&RRLoadConfig, &info) && info.dli_fname)
        return [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
    return nil;
}

static BOOL RRParse(NSString *path) {
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!txt) return NO;
    int n = 0;
    for (NSString *line in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *l = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!l.length || [l hasPrefix:@"#"] || [l hasPrefix:@";"] || [l hasPrefix:@"["]) continue;
        NSRange eq = [l rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        NSString *k = [[l substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *v = [[l substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([k.lowercaseString isEqualToString:@"force_stage"]) { gForceStage = v.intValue; continue; }
        if (k.length && v.length) { gMap[k.lowercaseString] = v; n++; }
    }
    RRLog(@"config: %d rule(s) from %@", n, path);
    return n > 0;
}

static void RRLoadConfig(void) {
    NSString *fwDir = RRFrameworkDir();
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    RRLog(@"framework dir: %@", fwDir ?: @"(unknown)");

    NSMutableArray *candidates = [NSMutableArray new];
    if (docs) [candidates addObject:[docs stringByAppendingPathComponent:@"redirects.cfg"]];   // optional override
    if (fwDir) [candidates addObject:[fwDir stringByAppendingPathComponent:@"redirects.cfg"]];
    NSString *pf = NSBundle.mainBundle.privateFrameworksPath;
    if (pf) [candidates addObject:[pf stringByAppendingPathComponent:@"RecRedirect.framework/redirects.cfg"]];

    for (NSString *p in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) { if (RRParse(p)) return; }
        else RRLog(@"no cfg at: %@", p);
    }
    RRLog(@"WARNING: cfg not found, using built-in default");
    gMap[@"ns.rec.net"] = @"ns.recflare.net";
}

#pragma mark - crash detection (raises safe-stage if the previous launch never got healthy)

static void RRStageInit(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *marker = [docs stringByAppendingPathComponent:@"rr_launching"];
    NSString *stageFile = [docs stringByAppendingPathComponent:@"rr_stage"];
    NSFileManager *fm = NSFileManager.defaultManager;
    int st = [[NSString stringWithContentsOfFile:stageFile encoding:NSUTF8StringEncoding error:nil] intValue];
    if ([fm fileExistsAtPath:marker]) {
        st = MIN(st + 1, 5);
        RRLog(@"previous launch CRASHED before 20s -> raising safe-stage to %d", st);
    }
    gStage = st;
    [[NSString stringWithFormat:@"%d", st] writeToFile:stageFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [fm removeItemAtPath:marker error:nil]; });
}

#pragma mark - preflight (proves whether the NEW host actually resolves / answers from this device)

static void RRPreflight(void) {
    for (NSString *h in [NSSet setWithArray:gMap.allValues]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            struct addrinfo hints; memset(&hints, 0, sizeof hints);
            hints.ai_socktype = SOCK_STREAM;
            struct addrinfo *res = NULL;
            int r = getaddrinfo(h.UTF8String, "443", &hints, &res);
            if (r != 0) {
                RRLog(@"CHECK %@: DNS FAILED (%s) - this device cannot find that hostname", h, gai_strerror(r));
                return;
            }
            NSMutableArray *ips = [NSMutableArray new];
            for (struct addrinfo *a = res; a; a = a->ai_next) {
                char buf[INET6_ADDRSTRLEN] = {0};
                if (a->ai_family == AF_INET)
                    inet_ntop(AF_INET, &((struct sockaddr_in *)a->ai_addr)->sin_addr, buf, sizeof buf);
                else if (a->ai_family == AF_INET6)
                    inet_ntop(AF_INET6, &((struct sockaddr_in6 *)a->ai_addr)->sin6_addr, buf, sizeof buf);
                if (buf[0]) [ips addObject:[NSString stringWithUTF8String:buf]];
            }
            freeaddrinfo(res);
            RRLog(@"CHECK %@: DNS OK -> %@", h, [ips componentsJoinedByString:@", "]);

            NSURL *u = [NSURL URLWithString:[@"https://" stringByAppendingString:h]];
            NSURLSessionDataTask *t = [NSURLSession.sharedSession dataTaskWithURL:u
                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (err) RRLog(@"CHECK %@: HTTPS FAILED %@ %ld (%@)", h, err.domain, (long)err.code, err.localizedDescription);
                else RRLog(@"CHECK %@: HTTPS reachable, status %ld", h, (long)((NSHTTPURLResponse *)resp).statusCode);
            }];
            [t resume];
        });
    }
}

#pragma mark - entry (runs when the framework is loaded, before the game's main())

__attribute__((constructor))
static void RecRedirectInit(void) {
    gMap = [NSMutableDictionary new];
    gLines = [NSMutableArray new];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    gLogPath = [docs stringByAppendingPathComponent:@"recredirect.log"];
    [NSFileManager.defaultManager removeItemAtPath:gLogPath error:nil];

    RRLog(@"=== RecRedirect INJECTED ===");
    RRLog(@"app: %@", NSBundle.mainBundle.bundleIdentifier);
    RRLoadConfig();
    RRStageInit();
    if (gForceStage >= 0) { gStage = MIN(gForceStage, 5); RRLog(@"force_stage=%d from cfg", gStage); }
    for (NSString *k in gMap) RRLog(@"rule: %@ -> %@", k, gMap[k]);
    InstallHooks();
    RRLog(RRIsOK() ? @"=== LOADED OK ===" : @"=== LOAD FAILED (no hooks or no rules) ===");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ RRPreflight(); });

    if (gStage >= 5) { RRLog(@"stage 5: nothing hooked, no overlay (log file only)"); return; }

    // Show the status box the moment the app has a window, on top of the game.
    void (^show)(NSNotification *) = ^(NSNotification *n) { RRShowOverlay(); };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:show];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:show];
}
