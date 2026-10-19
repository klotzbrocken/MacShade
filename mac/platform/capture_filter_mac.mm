// Screen filter mode (opt-in, per game): ReShade for games that cannot be hooked.
//
// The game runs completely untouched (no copy, no injection). A helper process (MacShadeFilter, which loads this library) captures the
// game's window with ScreenCaptureKit, feeds every frame through the same ReShade bridge the OpenGL/Metal path uses, and shows the result in a
// borderless window that sits exactly above the game window and lets mouse input pass through:
//
//   game window --ScreenCaptureKit--> IOSurface --blit--> private IOSurface --macshade_bridge_process (ReShade)--> overlay window layer
//
// Cost: one or two frames of delay, no depth buffer. Gain: works with Metal games, Mac App Store titles, DRM and hardened runtime.
// ReShade's overlay and the effect toggle are opened with global hotkeys (Carbon, no extra permission); while the overlay is open the window
// takes mouse and keyboard, afterwards the focus goes back to the game.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include "dll_log.hpp"
#include <filesystem>
extern std::filesystem::path g_target_executable_path;   // dll_main_mac.cpp: ReShade names screenshots after it
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>

bool macshade_bridge_process(uint32_t width, uint32_t height, void *layer, void *io_surface);
void macshade_set_window_override(void *surface_handle, void *window);
void macshade_bridge_set_overlay(bool open);
bool macshade_bridge_overlay_open();
bool macshade_bridge_is_idle(bool *fps_only);
void macshade_bridge_toggle_effects();
void macshade_bridge_request_screenshot();
void macshade_frame_limit();
bool macshade_bridge_pipeline_init(uint32_t width, uint32_t height, void *layer, void *const io_surfaces[3], void *const depth_surfaces[3]);
void macshade_bridge_pipeline_submit(int slot, bool with_depth);
void macshade_bridge_pipeline_wait(int slot);
void macshade_bridge_pipeline_drain();

namespace
{
	struct HotKey { int code = -1; UInt32 modifiers = 0; };

	HotKey parse_hotkey(const char *text)   // "<mac key code>:<mods>", mods: 1 ctrl, 2 shift, 4 option
	{
		HotKey k; int code = -1, mods = 0;
		if (text != nullptr && std::sscanf(text, "%d:%d", &code, &mods) >= 1) { k.code = code; if (mods & 1) k.modifiers |= controlKey; if (mods & 2) k.modifiers |= shiftKey; if (mods & 4) k.modifiers |= optionKey; }
		return k;
	}
}

/// Borderless window that can become key (needed while ReShade's overlay is open).
@interface MSFilterWindow : NSWindow
@end
@implementation MSFilterWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; }   // the overlay has to sit exactly on the game window, also over the menu bar
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface MSFilterController : NSObject <SCStreamOutput, SCStreamDelegate>
@property pid_t pid;
@property HotKey overlayKey, effectsKey, screenshotKey;
@property double captureScale;
- (void)start;
- (void)hotkey:(UInt32)which;
@end

static MSFilterController *s_controller = nil;

static OSStatus hotkey_handler(EventHandlerCallRef, EventRef event, void *)
{
	EventHotKeyID id; GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, nullptr, sizeof(id), nullptr, &id);
	dispatch_async(dispatch_get_main_queue(), ^{ [s_controller hotkey:id.id]; });
	return noErr;
}

@implementation MSFilterController
{
	NSRunningApplication *_game;
	MSFilterWindow *_window;
	NSView *_view;
	SCStream *_stream;
	dispatch_queue_t _queue;
	id<MTLDevice> _device;
	id<MTLCommandQueue> _commands;
	// ReShade works on _work (never shown); only finished frames are copied into one of the display surfaces the window may still be reading
	IOSurfaceRef _work; id<MTLTexture> _workTex;
	IOSurfaceRef _out[5];
	id<MTLTexture> _outTex[5];
	int _next;
	uint32_t _w, _h;
	CAMetalLayer *_detached;
	CMSampleBufferRef _last;
	NSLock *_lock;
	CGWindowID _windowID;
	CGSize _captureSize;
	BOOL _starting, _interactive;
	NSTimer *_tick, *_redraw;
	NSDate *_lastFrame;
	int _missing, _hideTicks, _restartTicks;
	CGRect _contentRect;   // normalised: the window content inside the captured frame
	NSString *_lastGeometry; int _geometryLogs;
	CGFloat _pixelScale;   // pixels per point as ScreenCaptureKit reports it for the filter (macOS 14 and later), 0 = not known
	BOOL _hotkeysOn; EventHotKeyRef _hotkeyRefs[3];
	BOOL _bypass, _bypassEnabled; int _idleTicks; NSDate *_noBypassUntil;   // effects off: the game runs unfiltered, the capture is stopped
	// statistics, logged every few seconds
	unsigned _statFrames, _statShown, _statDropped; double _statMs, _statIn, _statShade, _statOut; NSDate *_statSince;
	std::atomic<bool> _pending[5];   // display surfaces whose copy has not finished on the GPU yet
	// pipelined mode (MACSHADE_PIPELINE): three frames circulate, ReShade works on them while the next ones are captured; the result is shown two frames late
	BOOL _pipelined;
	IOSurfaceRef _ring[3]; id<MTLTexture> _ringTex[3]; id<MTLCommandBuffer> _ringCb[3];
	uint64_t _frameNumber; uint32_t _pipeW, _pipeH;
	CFAbsoluteTime _lastCapture; int _flushLeft;   // idle: the captured frame is fed again a few times so the pipeline empties
	CMSampleBufferRef _flushSample;
	CGWindowID _pendingWID;
	CGSize _pendingSize;
	NSDate *_holdShownUntil;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_queue = dispatch_queue_create("macshade.filter", DISPATCH_QUEUE_SERIAL);
		_lock = [NSLock new];
		_device = MTLCreateSystemDefaultDevice();
		_pipelined = std::getenv("MACSHADE_PIPELINE") != nullptr;
		_bypassEnabled = std::getenv("MACSHADE_FILTER_NO_BYPASS") == nullptr;
		_commands = [_device newCommandQueue];
	}
	return self;
}

- (void)start
{
	_game = [NSRunningApplication runningApplicationWithProcessIdentifier:self.pid];
	_window = [[MSFilterWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
	_window.opaque = YES; _window.backgroundColor = NSColor.blackColor; _window.hasShadow = NO;
	_window.ignoresMouseEvents = YES; _window.releasedWhenClosed = NO;
	_window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
	_view = [[NSView alloc] initWithFrame:_window.contentView.bounds];
	_view.wantsLayer = YES; _view.layer.contentsGravity = kCAGravityResize; _view.layer.magnificationFilter = kCAFilterNearest;
	_view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	[_window.contentView addSubview:_view];

	EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
	InstallApplicationEventHandler(&hotkey_handler, 1, &spec, nullptr, nullptr);   // the keys themselves are registered while the game is in front (updateHotkeys)
	if (std::getenv("MACSHADE_FILTER_OPEN_OVERLAY")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self hotkey:1]; });   // debug aid
	if (_pipelined) _redraw = [NSTimer scheduledTimerWithTimeInterval:1.0 / 20 repeats:YES block:^(NSTimer *) { [self redrawLast]; }];
	_tick = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) { [self tick]; }];
	[self tick];
}

/// The hotkeys are system-wide, so they are only taken while the game (or this helper, with the menu open) is the frontmost program; otherwise the keys belong to whatever else is in front.
- (void)updateHotkeys
{
	const BOOL gameFront = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == self.pid;
	const BOOL handover = _holdShownUntil != nil && [_holdShownUntil timeIntervalSinceNow] > 0;
	const BOOL want = gameFront || NSApp.active || _interactive || handover;
	if (want == _hotkeysOn) return;
	_hotkeysOn = want;
	const HotKey keys[3] = { self.overlayKey, self.effectsKey, self.screenshotKey };
	for (int i = 0; i < 3; ++i) {
		if (want) {
			if (keys[i].code < 0) continue;
			const OSStatus st = RegisterEventHotKey(keys[i].code, keys[i].modifiers, EventHotKeyID{ 'MSHD', (UInt32)(i + 1) }, GetApplicationEventTarget(), 0, &_hotkeyRefs[i]);
			if (st != noErr) reshade::log::message(reshade::log::level::warning, "Screen filter: hotkey %d (key code %d) could not be registered (status %d); another program may use it.", i + 1, keys[i].code, (int)st);
		} else if (_hotkeyRefs[i]) { UnregisterEventHotKey(_hotkeyRefs[i]); _hotkeyRefs[i] = nullptr; }
	}
}

- (void)hotkey:(UInt32)which
{
	if (_bypass) { _bypass = NO; _noBypassUntil = [NSDate dateWithTimeIntervalSinceNow:3.0]; reshade::log::message(reshade::log::level::info, "Screen filter: bypass ended by a hotkey"); }   // the request is applied with the next frame, so frames have to flow again
	reshade::log::message(reshade::log::level::info, "Screen filter: hotkey %u", (unsigned)which);
	if (which == 1) {
		const bool open = !macshade_bridge_overlay_open();
		macshade_bridge_set_overlay(open);
		[self setInteractive:open];
	} else if (which == 2) macshade_bridge_toggle_effects();
	else if (which == 3) macshade_bridge_request_screenshot();
}

- (void)enterBypass
{
	_bypass = YES; _idleTicks = 0;
	SCStream *old = _stream; _stream = nil; _windowID = 0;
	[old stopCaptureWithCompletionHandler:^(NSError *) {}];
	[_window orderOut:nil];
	reshade::log::message(reshade::log::level::info, "Screen filter: bypass started: ReShade has nothing to draw, the capture is stopped and the game runs unfiltered.");
}

- (void)setInteractive:(BOOL)on
{
	if (_interactive == on) return;
	_interactive = on;
	_holdShownUntil = [NSDate dateWithTimeIntervalSinceNow:1.5];
	reshade::log::message(reshade::log::level::info, "Screen filter: interactive %d", (int)on);
	_window.ignoresMouseEvents = !on;
	[_redraw invalidate]; _redraw = nil;
	if (on) {
		[NSApp activateIgnoringOtherApps:YES];
		[_window makeKeyAndOrderFront:nil];
		// the game may not deliver new frames while it is idle: keep redrawing the last one so ReShade's menu stays responsive
		_redraw = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *) { [self redrawLast]; }];
	} else {
		[_window resignKeyWindow];
		[_game activateWithOptions:NSApplicationActivateIgnoringOtherApps];
		if (_pipelined) _redraw = [NSTimer scheduledTimerWithTimeInterval:1.0 / 20 repeats:YES block:^(NSTimer *) { [self redrawLast]; }];
	}
}

/// The game window to filter: the one captured now while it is still on screen, otherwise the largest one (games often have several windows; switching between them restarts the capture).
- (NSDictionary *)gameWindowInfo
{
	NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
	NSDictionary *best = nil, *current = nil; double bestArea = 0;
	for (NSDictionary *w in list) {
		if ([w[(id)kCGWindowOwnerPID] intValue] != self.pid || [w[(id)kCGWindowLayer] intValue] < 0) continue;   // any level: games with a borderless full-screen window often raise it above normal windows
		CGRect r; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
		if (r.size.width < 200 || r.size.height < 150 || [w[(id)kCGWindowAlpha] doubleValue] < 0.1) continue;
		if (_windowID != 0 && [w[(id)kCGWindowNumber] unsignedIntValue] == _windowID) current = w;
		if (r.size.width * r.size.height > bestArea) { bestArea = r.size.width * r.size.height; best = w; }
	}
	return current ?: best;
}

- (void)logState:(const char *)what
{
	static std::string last; static int repeats = 0;
	if (last == what) { ++repeats; return; }
	reshade::log::message(reshade::log::level::info, "Screen filter: %s (previous state held for %d ticks)", what, repeats); last = what; repeats = 0;
}

- (void)tick
{
	if (_game == nil || _game.terminated) { [NSApp terminate:nil]; return; }
	[self updateHotkeys];
	NSDictionary *info = [self gameWindowInfo];
	if (info == nil) {
		[self logState:"game window not found"];
		if (++_hideTicks >= 4 && !_interactive) [_window orderOut:nil];   // gone for a second: hide (a short gap, e.g. a mode change, keeps the picture)
		return;
	}
	CGRect r; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &r);
	const CGFloat top = NSScreen.screens.firstObject.frame.size.height;
	NSRect frame = NSMakeRect(r.origin.x, top - r.origin.y - r.size.height, r.size.width, r.size.height);
	if (fabs(frame.origin.x - _window.frame.origin.x) > 0.5 || fabs(frame.origin.y - _window.frame.origin.y) > 0.5 || fabs(frame.size.width - _window.frame.size.width) > 0.5 || fabs(frame.size.height - _window.frame.size.height) > 0.5) {
		[_window setFrame:frame display:YES];
		NSMutableString *screens = [NSMutableString string];
		for (NSScreen *sc in NSScreen.screens) [screens appendFormat:@"[%.0f,%.0f %.0fx%.0f @%.0fx] ", sc.frame.origin.x, sc.frame.origin.y, sc.frame.size.width, sc.frame.size.height, sc.backingScaleFactor];
		const NSRect got = _window.frame;
		reshade::log::message(reshade::log::level::info, "Screen filter: game window (CG) %.0f,%.0f %.0fx%.0f -> overlay wanted %.0f,%.0f %.0fx%.0f, got %.0f,%.0f %.0fx%.0f; screens %s",
			r.origin.x, r.origin.y, r.size.width, r.size.height, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, got.origin.x, got.origin.y, got.size.width, got.size.height, screens.UTF8String);
	}

	// nothing for ReShade to draw (effects off, menu closed): stop capturing and show the game itself; a hotkey brings the filter back
	if (_bypassEnabled && !_bypass && !_interactive && _stream != nil && (_noBypassUntil == nil || [_noBypassUntil timeIntervalSinceNow] <= 0)) {
		bool fpsOnly = false;
		if (macshade_bridge_is_idle(&fpsOnly) && !macshade_bridge_overlay_open()) { if (++_idleTicks >= 3) [self enterBypass]; } else _idleTicks = 0;
	} else _idleTicks = 0;
	if (_bypass) { [_window orderOut:nil]; [self logState:"bypass: effects are off, the game is shown unfiltered"]; return; }
	const BOOL gameFront = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == self.pid;
	const BOOL weFront = NSApp.active;
	const BOOL handover = _holdShownUntil != nil && [_holdShownUntil timeIntervalSinceNow] > 0;   // focus moves between the game and this helper: nobody is in front for a moment
	if (gameFront || weFront || handover || _interactive) {
		_hideTicks = 0;
		_window.level = MAX((NSInteger)NSFloatingWindowLevel, (NSInteger)[info[(id)kCGWindowLayer] intValue] + 1);   // above the game's own window level
		[_window orderFrontRegardless];
		[self logState:gameFront ? "overlay shown (game in front)" : "overlay shown (helper in front)"];
	} else if (++_hideTicks >= 3) { [_window orderOut:nil]; [self logState:"overlay hidden (another app in front)"]; }
	if (_interactive && !macshade_bridge_overlay_open() && !handover) [self setInteractive:NO];   // closed from inside ReShade

	// scale of the display the game window is on; a new size or window has to stay the same for two ticks before the capture is restarted
	NSScreen *screen = NSScreen.mainScreen; CGFloat bestOverlap = -1;
	for (NSScreen *sc in NSScreen.screens) { NSRect i = NSIntersectionRect(sc.frame, frame); const CGFloat o = i.size.width * i.size.height; if (o > bestOverlap) { bestOverlap = o; screen = sc; } }
	const CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
	const CGFloat factor = (_pixelScale > 0 ? _pixelScale : screen.backingScaleFactor) * (self.captureScale > 0 ? self.captureScale : 1.0);   // the same rule as in startStream
	const CGSize size = CGSizeMake(round(r.size.width * factor), round(r.size.height * factor));
	const BOOL differs = wid != _windowID || fabs(size.width - _captureSize.width) > 2 || fabs(size.height - _captureSize.height) > 2;
	if (!differs) { _restartTicks = 0; return; }
	if (wid == _pendingWID && fabs(size.width - _pendingSize.width) <= 2 && fabs(size.height - _pendingSize.height) <= 2) ++_restartTicks; else { _pendingWID = wid; _pendingSize = size; _restartTicks = 1; }
	if (!_starting && (_stream == nil || _restartTicks >= 2)) { _restartTicks = 0; [self startStream:wid points:r.size backing:screen.backingScaleFactor]; }
}

- (void)startStream:(CGWindowID)wid points:(CGSize)points backing:(CGFloat)backing
{
	_starting = YES;
	SCStream *old = _stream; _stream = nil;
	[old stopCaptureWithCompletionHandler:^(NSError *) {}];
	[SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			SCWindow *target = nil;
			for (SCWindow *w in content.windows) if (w.windowID == wid) { target = w; break; }
			if (target == nil) { if (error) reshade::log::message(reshade::log::level::error, "Screen filter: cannot list windows: %s", error.localizedDescription.UTF8String); self->_starting = NO; return; }
			SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:target];
			// pixels per point: ScreenCaptureKit's own value (macOS 14+) instead of the screen's backing scale, which is wrong for scaled display modes
			CGFloat pps = 0; CGRect filterRect = CGRectZero;
			if (@available(macOS 14.0, *)) { pps = filter.pointPixelScale; filterRect = filter.contentRect; }
			const CGFloat unit = pps > 0 ? pps : backing;
			const CGFloat halve = self.captureScale > 0 ? self.captureScale : 1.0;   // half resolution capture: fewer pixels for ReShade
			const CGSize size = CGSizeMake(round(points.width * unit * halve), round(points.height * unit * halve));
			self->_pixelScale = pps;
			reshade::log::message(reshade::log::level::info, "Screen filter: capture size: window %.1fx%.1f pt (filter content rect %.1f,%.1f %.1fx%.1f), pointPixelScale %.3f, screen backingScaleFactor %.3f, scale %.2f -> %.0fx%.0f px", points.width, points.height, filterRect.origin.x, filterRect.origin.y, filterRect.size.width, filterRect.size.height, pps, backing, halve, size.width, size.height);
			SCStreamConfiguration *config = [SCStreamConfiguration new];
			config.width = (size_t)size.width; config.height = (size_t)size.height;
			config.pixelFormat = kCVPixelFormatType_32BGRA;
			config.showsCursor = NO; config.queueDepth = 4;
			// the frame rate limit of the game page limits the captured (and so the filtered) picture; the game itself keeps running at its own rate
			const double limit = std::getenv("MACSHADE_FPS_LIMIT") ? std::atof(std::getenv("MACSHADE_FPS_LIMIT")) : 0.0;
			config.minimumFrameInterval = limit >= 1.0 ? CMTimeMakeWithSeconds(1.0 / limit, 600) : CMTimeMake(1, 120);
			SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
			NSError *addError = nil;
			[stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_queue error:&addError];
			[stream startCaptureWithCompletionHandler:^(NSError *startError) {
				dispatch_async(dispatch_get_main_queue(), ^{
					if (startError || addError) {
						reshade::log::message(reshade::log::level::error, "Screen filter: capture failed: %s", (startError ?: addError).localizedDescription.UTF8String);
						fprintf(stderr, "MACSHADE_CAPTURE_FAILED %s\n", (startError ?: addError).localizedDescription.UTF8String);
					} else {
						self->_stream = stream; self->_windowID = wid; self->_captureSize = size;
						reshade::log::message(reshade::log::level::info, "Screen filter: capturing window %u of pid %d at %.0fx%.0f.", wid, (int)self.pid, size.width, size.height);
					}
					self->_starting = NO;
				});
			}];
		});
	}];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
	reshade::log::message(reshade::log::level::warning, "Screen filter: stream stopped: %s", error.localizedDescription.UTF8String);
	dispatch_async(dispatch_get_main_queue(), ^{ self->_stream = nil; self->_windowID = 0; });   // the next tick starts it again
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type
{
	if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
	NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
	if ([attachments.firstObject[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
	// where the window content lies inside the frame (points) and how many points the frame has: the crop keeps margins out of ReShade and the window
	NSDictionary *a = attachments.firstObject; CGRect bounding = CGRectZero, content = CGRectZero;
	if (@available(macOS 14.0, *)) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)a[SCStreamFrameInfoBoundingRect], &bounding);   // the key does not exist before macOS 14: no crop there
	CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)a[SCStreamFrameInfoContentRect], &content);
	// both rects are in surface coordinates: the content's place relative to the bounding box, as a fraction of it
	_contentRect = (bounding.size.width > 0 && content.size.width > 0) ? CGRectMake((content.origin.x - bounding.origin.x) / bounding.size.width, (content.origin.y - bounding.origin.y) / bounding.size.height, content.size.width / bounding.size.width, content.size.height / bounding.size.height) : CGRectMake(0, 0, 1, 1);
	{   // log every change of the geometry (not every frame): what ScreenCaptureKit reports, so a report shows where picture and window differ
		IOSurfaceRef surface = CVPixelBufferGetIOSurface(CMSampleBufferGetImageBuffer(sampleBuffer));
		id screenRect = nil;
		if (@available(macOS 13.1, *)) screenRect = a[SCStreamFrameInfoScreenRect];
		NSString *geometry = [NSString stringWithFormat:@"surface %zux%zu, boundingRect %.1f,%.1f %.1fx%.1f, contentRect %.1f,%.1f %.1fx%.1f, contentScale %@, scaleFactor %@, screenRect %@",
			surface ? IOSurfaceGetWidth(surface) : 0, surface ? IOSurfaceGetHeight(surface) : 0,
			bounding.origin.x, bounding.origin.y, bounding.size.width, bounding.size.height, content.origin.x, content.origin.y, content.size.width, content.size.height,
			a[SCStreamFrameInfoContentScale], a[SCStreamFrameInfoScaleFactor], screenRect];
		if (![geometry isEqualToString:_lastGeometry] && _geometryLogs++ < 12) { _lastGeometry = geometry; reshade::log::message(reshade::log::level::info, "Screen filter: frame geometry: %s", geometry.UTF8String); }
	}
	[_lock lock];
	if (_last) CFRelease(_last);
	_last = (CMSampleBufferRef)CFRetain(sampleBuffer);
	_lastCapture = CFAbsoluteTimeGetCurrent(); _flushLeft = 3;
	[_lock unlock];
	[self render:sampleBuffer];
}

- (void)redrawLast
{
	if (_bypass) return;
	if (_pipelined && !_interactive) {   // pipelined and the capture is quiet: feed the last frame again so the frames still inside the pipeline come out
		[_lock lock]; const BOOL quiet = CFAbsoluteTimeGetCurrent() - _lastCapture > 0.06 && _flushLeft > 0; if (quiet) --_flushLeft; [_lock unlock];
		if (!quiet) return;
	}
	[_lock lock]; CMSampleBufferRef sb = _last ? (CMSampleBufferRef)CFRetain(_last) : nullptr; [_lock unlock];
	if (sb == nullptr) return;
	dispatch_async(_queue, ^{ [self render:sb]; CFRelease(sb); });
}

/// Runs on `_queue`: copies the captured frame into a private surface, lets ReShade work on it and hands it to the overlay window.
/// (Re)creates the surfaces and the bridge for a new picture size. Everything in flight has to be finished first.
- (BOOL)setupPipelineWidth:(uint32_t)w height:(uint32_t)h
{
	macshade_bridge_pipeline_drain();
	for (int i = 0; i < 3; ++i) if (_ringCb[i]) { [_ringCb[i] waitUntilCompleted]; _ringCb[i] = nil; }
	for (int spin = 0; spin < 200; ++spin) { BOOL busy = NO; for (int i = 0; i < 5; ++i) busy |= _pending[i].load(); if (!busy) break; usleep(5000); }
	NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @((w * 4 + 63) & ~63), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
	MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
	d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModeShared;
	for (int i = 0; i < 3; ++i) {
		if (_ring[i]) { CFRelease(_ring[i]); _ring[i] = nullptr; }
		_ring[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		_ringTex[i] = _ring[i] ? [_device newTextureWithDescriptor:d iosurface:_ring[i] plane:0] : nil;
		if (_ringTex[i] == nil) return NO;
	}
	for (int i = 0; i < 5; ++i) {
		if (_out[i]) { CFRelease(_out[i]); _out[i] = nullptr; }
		_out[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		_outTex[i] = _out[i] ? [_device newTextureWithDescriptor:d iosurface:_out[i] plane:0] : nil;
		if (_outTex[i] == nil) return NO;
	}
	_detached = [CAMetalLayer layer]; _detached.device = _device; _detached.pixelFormat = MTLPixelFormatBGRA8Unorm;
	_detached.drawableSize = CGSizeMake(w, h); _detached.frame = CGRectMake(0, 0, w, h);
	NSWindow *window = _window; CAMetalLayer *layer = _detached;
	dispatch_sync(dispatch_get_main_queue(), ^{ macshade_set_window_override((__bridge void *)layer, (__bridge void *)window); });
	void *surfaces[3] = { _ring[0], _ring[1], _ring[2] };
	if (!macshade_bridge_pipeline_init(w, h, (__bridge void *)_detached, surfaces, nullptr)) return NO;
	_pipeW = w; _pipeH = h; _frameNumber = 0; _w = w; _h = h;
	reshade::log::message(reshade::log::level::info, "Screen filter: pipelined processing of %ux%u frames (result shown two frames late).", w, h);
	return YES;
}

/// Pipelined: copies this frame into a ring slot (not awaited), hands the previous one to ReShade (not awaited) and shows the one before that.
- (void)renderPipelined:(IOSurfaceRef)source crop:(CGRect)crop frame:(CGSize)frame
{
	const uint32_t cx = (uint32_t)crop.origin.x, cy = (uint32_t)crop.origin.y, w = (uint32_t)crop.size.width, h = (uint32_t)crop.size.height;
	if (w != _pipeW || h != _pipeH) {
		if (![self setupPipelineWidth:w height:h]) { reshade::log::message(reshade::log::level::error, "Screen filter: pipelined mode failed, using the synchronous path."); _pipelined = NO; return; }
	}
	NSDate *t0 = [NSDate date];
	++_statFrames;
	MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)frame.width height:(NSUInteger)frame.height mipmapped:NO];
	sd.usage = MTLTextureUsageShaderRead; sd.storageMode = MTLStorageModeShared;
	id<MTLTexture> src = [_device newTextureWithDescriptor:sd iosurface:source plane:0];
	if (src == nil) return;
	const uint64_t n = _frameNumber++;
	const int cur = (int)(n % 3);
	id<MTLCommandBuffer> cb = [_commands commandBuffer];
	id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
	[blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(cx, cy, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:_ringTex[cur] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding]; [cb commit];
	_ringCb[cur] = cb;
	if (n >= 1) {
		const int prev = (int)((n - 1) % 3);
		NSDate *t1 = [NSDate date];
		[_ringCb[prev] waitUntilCompleted];   // a whole frame ago: normally done
		NSDate *t2 = [NSDate date];
		macshade_bridge_pipeline_submit(prev, false);
		_statIn += [t2 timeIntervalSinceDate:t1] * 1000.0; _statShade += -[t2 timeIntervalSinceNow] * 1000.0;
	}
	if (n >= 2) {
		const int old = (int)((n - 2) % 3);
		NSDate *t3 = [NSDate date];
		macshade_bridge_pipeline_wait(old);   // ReShade's work on that frame
		_statOut += -[t3 timeIntervalSinceNow] * 1000.0;
		int slot = -1;
		for (int k = 0; k < 5 && slot < 0; ++k) { const int c = (_next + k) % 5; if (!_pending[c].load() && !IOSurfaceIsInUse(_out[c])) slot = c; }
		if (slot >= 0) {
			_next = (slot + 1) % 5; _pending[slot] = true;
			id<MTLCommandBuffer> cb2 = [_commands commandBuffer];
			id<MTLBlitCommandEncoder> blit2 = [cb2 blitCommandEncoder];
			[blit2 copyFromTexture:_ringTex[old] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:_outTex[slot] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
			[blit2 endEncoding];
			IOSurfaceRef shown = _out[slot]; NSView *view = _view; std::atomic<bool> *flag = &_pending[slot];
			[cb2 addCompletedHandler:^(id<MTLCommandBuffer>) {
				dispatch_async(dispatch_get_main_queue(), ^{ [CATransaction begin]; [CATransaction setDisableActions:YES]; view.layer.contents = (__bridge id)shown; [CATransaction commit]; flag->store(false); });
			}];
			[cb2 commit];
			++_statShown;
		} else ++_statDropped;
	}
	_statMs += -[t0 timeIntervalSinceNow] * 1000.0;
	if (_statSince == nil) _statSince = [NSDate date];
	if (-[_statSince timeIntervalSinceNow] >= 10.0 && _statFrames > 0) {
		reshade::log::message(reshade::log::level::info, "Screen filter: last %.0f s: %u frames in, %u shown, %u dropped, %.1f ms per frame (pipelined: wait for copy %.1f + submit %.1f + wait for ReShade %.1f).", -[_statSince timeIntervalSinceNow], _statFrames, _statShown, _statDropped, _statMs / _statFrames, _statIn / _statFrames, _statShade / _statFrames, _statOut / _statFrames);
		_statFrames = _statShown = _statDropped = 0; _statMs = _statIn = _statShade = _statOut = 0; _statSince = [NSDate date];
	}
}

- (void)render:(CMSampleBufferRef)sampleBuffer
{
	CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
	IOSurfaceRef source = pixels ? CVPixelBufferGetIOSurface(pixels) : nullptr;
	if (source == nullptr) return;
	const uint32_t fw = (uint32_t)IOSurfaceGetWidth(source), fh = (uint32_t)IOSurfaceGetHeight(source);
	if (fw < 16 || fh < 16) return;
	// the part of the frame that is the window content (the whole frame unless ScreenCaptureKit reports margins)
	uint32_t cx = 0, cy = 0, w = fw, h = fh;
	const CGRect cr = _contentRect;
	if (cr.size.width > 0.2 && cr.size.height > 0.2 && (cr.size.width < 0.99 || cr.size.height < 0.99 || cr.origin.x > 0.01 || cr.origin.y > 0.01)) {
		cx = (uint32_t)MAX(0.0, round(cr.origin.x * fw)); cy = (uint32_t)MAX(0.0, round(cr.origin.y * fh));
		w = (uint32_t)round(cr.size.width * fw); h = (uint32_t)round(cr.size.height * fh);
		if (cx + w > fw) w = fw - cx;
		if (cy + h > fh) h = fh - cy;
	}
	if (w < 16 || h < 16) return;
	if (_pipelined) { [self renderPipelined:source crop:CGRectMake(cx, cy, w, h) frame:CGSizeMake(fw, fh)]; return; }
	NSDate *started = [NSDate date];
	if (w != _w || h != _h) {
		NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @((w * 4 + 63) & ~63), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModeShared;
		if (_work) { CFRelease(_work); _work = nullptr; }
		_work = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		_workTex = _work ? [_device newTextureWithDescriptor:d iosurface:_work plane:0] : nil;
		for (int i = 0; i < 5; ++i) {
			if (_out[i]) { CFRelease(_out[i]); _out[i] = nullptr; }
			_out[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			_outTex[i] = _out[i] ? [_device newTextureWithDescriptor:d iosurface:_out[i] plane:0] : nil;
		}
		if (_workTex == nil || _outTex[4] == nil) { reshade::log::message(reshade::log::level::error, "Screen filter: cannot create the frame surfaces."); return; }
		_detached = [CAMetalLayer layer]; _detached.device = _device; _detached.pixelFormat = MTLPixelFormatBGRA8Unorm;
		_detached.drawableSize = CGSizeMake(w, h); _detached.frame = CGRectMake(0, 0, w, h);
		NSWindow *window = _window; CAMetalLayer *layer = _detached;
		dispatch_sync(dispatch_get_main_queue(), ^{ macshade_set_window_override((__bridge void *)layer, (__bridge void *)window); });
		_w = w; _h = h;
		reshade::log::message(reshade::log::level::info, "Screen filter: processing %ux%u frames (captured frame %ux%u, content at %u,%u, normalised content rect %.3f,%.3f %.3fx%.3f).", w, h, fw, fh, cx, cy, cr.origin.x, cr.origin.y, cr.size.width, cr.size.height);
	}
	MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:fw height:fh mipmapped:NO];
	sd.usage = MTLTextureUsageShaderRead; sd.storageMode = MTLStorageModeShared;
	id<MTLTexture> src = [_device newTextureWithDescriptor:sd iosurface:source plane:0];
	if (src == nil) return;
	NSDate *tIn = [NSDate date];
	id<MTLCommandBuffer> cb = [_commands commandBuffer];
	id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
	[blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(cx, cy, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:_workTex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
	NSDate *tShade = [NSDate date];
	if (!macshade_bridge_process(w, h, (__bridge void *)_detached, _work)) return;   // ReShade works on the private surface
	NSDate *tOut = [NSDate date];
	// a display surface the window server is not using (an unfinished frame must never be visible)
	++_statFrames;
	int slot = -1;
	for (int k = 0; k < 5 && slot < 0; ++k) { const int c = (_next + k) % 5; if (!_pending[c].load() && !IOSurfaceIsInUse(_out[c])) slot = c; }
	if (slot >= 0) {
		_next = (slot + 1) % 5;
		_pending[slot] = true;
		id<MTLCommandBuffer> cb2 = [_commands commandBuffer];
		id<MTLBlitCommandEncoder> blit2 = [cb2 blitCommandEncoder];
		[blit2 copyFromTexture:_workTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:_outTex[slot] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
		[blit2 endEncoding];
		// the copy runs on the GPU while the next frame is already being processed; the window gets the surface when the copy is done
		IOSurfaceRef shown = _out[slot]; NSView *view = _view; std::atomic<bool> *flag = &_pending[slot];
		[cb2 addCompletedHandler:^(id<MTLCommandBuffer>) {
			dispatch_async(dispatch_get_main_queue(), ^{ [CATransaction begin]; [CATransaction setDisableActions:YES]; view.layer.contents = (__bridge id)shown; [CATransaction commit]; flag->store(false); });
		}];
		[cb2 commit];
		++_statShown;
	} else ++_statDropped;   // all busy: this frame is dropped
	_statIn += [tShade timeIntervalSinceDate:tIn] * 1000.0; _statShade += [tOut timeIntervalSinceDate:tShade] * 1000.0; _statOut += -[tOut timeIntervalSinceNow] * 1000.0;
	_statMs += -[started timeIntervalSinceNow] * 1000.0;
	if (_statSince == nil) _statSince = [NSDate date];
	if (-[_statSince timeIntervalSinceNow] >= 10.0 && _statFrames > 0) {
		reshade::log::message(reshade::log::level::info, "Screen filter: last %.0f s: %u frames in, %u shown, %u dropped, %.1f ms per frame (copy in %.1f + ReShade %.1f + copy out %.1f).", -[_statSince timeIntervalSinceNow], _statFrames, _statShown, _statDropped, _statMs / _statFrames, _statIn / _statFrames, _statShade / _statFrames, _statOut / _statFrames);
		_statFrames = _statShown = _statDropped = 0; _statMs = _statIn = _statShade = _statOut = 0; _statSince = [NSDate date];
	}
}
@end

/// Entry point called by the MacShadeFilter helper: `--pid <game> [--overlay <key>:<mods>] [--effects <key>:<mods>]`.
extern "C" __attribute__((visibility("default"))) int macshade_filter_main(int argc, char **argv)
{
	@autoreleasepool {
		int pid = 0; double scale = 1.0; const char *overlay = nullptr, *effects = nullptr, *screenshot = nullptr;
		for (int i = 1; i + 1 < argc; ++i) {
			if (!std::strcmp(argv[i], "--pid")) pid = std::atoi(argv[i + 1]);
			else if (!std::strcmp(argv[i], "--overlay")) overlay = argv[i + 1];
			else if (!std::strcmp(argv[i], "--effects")) effects = argv[i + 1];
			else if (!std::strcmp(argv[i], "--scale")) scale = std::atof(argv[i + 1]);
			else if (!std::strcmp(argv[i], "--screenshot")) screenshot = argv[i + 1];
		}
		if (pid <= 0) { std::fprintf(stderr, "usage: MacShadeFilter --pid <game pid>\n"); return 2; }
		if (!CGPreflightScreenCaptureAccess()) {
			CGRequestScreenCaptureAccess();
			std::fprintf(stderr, "MACSHADE_NEEDS_SCREEN_RECORDING\n");
			return 3;
		}
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		if (NSRunningApplication *game = [NSRunningApplication runningApplicationWithProcessIdentifier:pid]; game.executableURL) g_target_executable_path = game.executableURL.path.UTF8String;   // screenshots get the game's name, not the helper's
		s_controller = [MSFilterController new];
		s_controller.captureScale = scale; s_controller.pid = pid; s_controller.overlayKey = parse_hotkey(overlay); s_controller.effectsKey = parse_hotkey(effects); s_controller.screenshotKey = parse_hotkey(screenshot);
		[s_controller start];
		[NSApp run];
	}
	return 0;
}
