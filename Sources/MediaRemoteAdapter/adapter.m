// MediaRemote adapter: the system-wide Now Playing feed (TV, Music, Podcasts, QuickTime Player,
// browsers, anything that publishes to Control Center) for NotchIsland.
//
// Since macOS 15.4 MediaRemote answers only Apple's own processes. /usr/bin/perl is one, and its
// DynaLoader can load any dylib and call a function shaped like a perl XSUB. NotchIsland therefore
// runs `perl -e '<tiny loader>' <this dylib> stream`, and this code, inside perl, asks MediaRemote
// and writes one JSON object per line to stdout. `command <name>` sends a transport command.
//
// Nothing here links MediaRemote at build time; every symbol is resolved with dlsym so the app
// still builds and runs where the framework changes.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetBoolFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetIntFn)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFn)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientBundleFn)(id);
typedef Boolean (*MRSendCommandFn)(int, CFDictionaryRef);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRRegisterFn)(dispatch_queue_t);

static void *mr = NULL;
static MRGetInfoFn getInfo;
static MRGetBoolFn getIsPlaying;
static MRGetIntFn getPID;
static MRGetClientFn getClient;
static MRClientBundleFn clientBundle;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;
static MRRegisterFn registerNotifications;

static dispatch_queue_t work;
static NSString *lastArtworkKey = nil;
static BOOL fetchScheduled = NO;
static dispatch_source_t heartbeat;   // global: under ARC a local would be released, and with it the timer

static BOOL load(void) {
    if (mr) return YES;
    mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "adapter: dlopen MediaRemote failed: %s\n", dlerror()); return NO; }
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    registerNotifications = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getPID) { fprintf(stderr, "adapter: MediaRemote symbols missing\n"); return NO; }
    work = dispatch_queue_create("notchisland.mra", DISPATCH_QUEUE_SERIAL);
    return YES;
}

static id value(NSDictionary *info, NSString *key) {
    id v = info[key];
    return (v == nil || v == [NSNull null]) ? nil : v;
}

/// One JSON object describing the current Now Playing item. `withArtwork` adds the image (base64)
/// when it differs from the one last written; the reader caches it by `artworkKey`.
static NSDictionary *snapshot(BOOL withArtwork) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block int pid = 0;
    __block NSString *bundle = nil;

    getInfo(work, ^(CFDictionaryRef d) { info = d ? [(__bridge NSDictionary *)d copy] : nil; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    getIsPlaying(work, ^(Boolean p) { playing = p; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    getPID(work, ^(int p) { pid = p; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    if (getClient && clientBundle) {
        getClient(work, ^(id client) {
            if (client) { CFStringRef b = clientBundle(client); if (b) bundle = [(__bridge NSString *)b copy]; }
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"pid"] = @(pid);
    out[@"playing"] = @(playing);
    if (bundle) out[@"bundle"] = bundle;
    NSString *title = value(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    if (title) out[@"title"] = title;
    NSString *artist = value(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    if (artist) out[@"artist"] = artist;
    NSString *album = value(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    if (album) out[@"album"] = album;
    NSNumber *duration = value(info, @"kMRMediaRemoteNowPlayingInfoDuration");
    if (duration) out[@"duration"] = duration;
    NSNumber *elapsed = value(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime");
    if (elapsed) out[@"elapsed"] = elapsed;
    NSNumber *rate = value(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate");
    if (rate) out[@"rate"] = rate;
    NSDate *stamp = value(info, @"kMRMediaRemoteNowPlayingInfoTimestamp");
    if ([stamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([stamp timeIntervalSince1970]);
    NSString *mediaType = value(info, @"kMRMediaRemoteNowPlayingInfoMediaType");
    if (mediaType) out[@"mediaType"] = mediaType;
    id item = value(info, @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier")
                  ?: value(info, @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier");
    if ([item isKindOfClass:[NSNumber class]]) item = [item stringValue];
    if (item) out[@"id"] = item;

    NSData *art = value(info, @"kMRMediaRemoteNowPlayingInfoArtworkData");
    NSString *artKey = value(info, @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier");
    if (![artKey isKindOfClass:[NSString class]]) artKey = nil;
    if ([art isKindOfClass:[NSData class]] && art.length > 0) {
        if (!artKey) artKey = [NSString stringWithFormat:@"%@|%lu", item ?: title ?: @"", (unsigned long)art.length];
        out[@"artworkKey"] = artKey;
        if (withArtwork && ![artKey isEqualToString:lastArtworkKey]) {
            out[@"artwork"] = [art base64EncodedStringWithOptions:0];
            NSString *mime = value(info, @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType");
            if (mime) out[@"artworkMIME"] = mime;
            lastArtworkKey = artKey;
        }
    } else {
        lastArtworkKey = nil;
    }
    return out;
}

/// The reader is NotchIsland. When it is gone (quit, crashed, or replaced by an update through
/// `launchctl kickstart -k`, which gives no chance to tidy up) this process is reparented to launchd
/// and must not linger: it would keep MediaRemote busy and pile up once per relaunch.
static void exitIfOrphaned(void) {
    if (getppid() == 1) exit(0);
}

static void writeLine(NSDictionary *object) {
    exitIfOrphaned();
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!json) return;
    if (fwrite(json.bytes, 1, json.length, stdout) != json.length) exit(0);   // reader gone
    fputc('\n', stdout);
    if (fflush(stdout) != 0) exit(0);
}

static void emit(void) {
    @autoreleasepool { writeLine(snapshot(YES)); }
}

/// Notifications arrive in bursts; one fetch a little later covers them all.
static void scheduleEmit(void) {
    if (fetchScheduled) return;
    fetchScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        fetchScheduled = NO;
        emit();
    });
}

/// `stream`: a line now, a line on every change, and a heartbeat line every two seconds, until
/// the reader goes away (SIGPIPE) or the process is killed.
void notchisland_mra_stream(void *interp, void *cv) {
    @autoreleasepool {
        if (!load()) exit(2);
        if (registerNotifications) registerNotifications(dispatch_get_main_queue());
        NSArray *names = @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                           @"kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification"];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification *n) { scheduleEmit(); }];
        }
        emit();
        heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(heartbeat, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, (uint64_t)(0.2 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(heartbeat, ^{ exitIfOrphaned(); emit(); });
        dispatch_resume(heartbeat);
    }
    dispatch_main();   // services the main queue (notifications, heartbeat); never returns
}

/// `get`: one line and out.
void notchisland_mra_get(void *interp, void *cv) {
    if (!load()) exit(2);
    emit();
}

/// `command`: NOTCHISLAND_MRA_COMMAND = play | pause | toggle | next | previous | seek:<seconds>.
void notchisland_mra_command(void *interp, void *cv) {
    @autoreleasepool {
        if (!load() || !sendCommand) exit(2);
        const char *raw = getenv("NOTCHISLAND_MRA_COMMAND");
        NSString *command = raw ? [NSString stringWithUTF8String:raw] : @"";
        int code = -1;
        if ([command isEqualToString:@"play"]) code = 0;
        else if ([command isEqualToString:@"pause"]) code = 1;
        else if ([command isEqualToString:@"toggle"]) code = 2;
        else if ([command isEqualToString:@"stop"]) code = 3;
        else if ([command isEqualToString:@"next"]) code = 4;
        else if ([command isEqualToString:@"previous"]) code = 5;
        else if ([command hasPrefix:@"seek:"]) {
            if (!setElapsed) exit(2);
            setElapsed([[command substringFromIndex:5] doubleValue]);
            // Give the XPC message a moment to leave before the process ends.
            [NSThread sleepForTimeInterval:0.15];
            return;
        }
        if (code < 0) { fprintf(stderr, "adapter: unknown command %s\n", raw ? raw : "(none)"); exit(64); }
        Boolean ok = sendCommand(code, NULL);
        [NSThread sleepForTimeInterval:0.15];
        if (!ok) exit(1);
    }
}
