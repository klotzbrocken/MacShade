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
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <string>

bool macshade_bridge_process(uint32_t width, uint32_t height, void *layer, void *io_surface);
void macshade_set_window_override(void *surface_handle, void *window);
void macshade_bridge_set_overlay(bool open);
bool macshade_bridge_overlay_open();
void macshade_bridge_toggle_effects();
void macshade_frame_limit();

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
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface MSFilterController : NSObject <SCStreamOutput, SCStreamDelegate>
@property pid_t pid;
@property HotKey overlayKey, effectsKey;
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
	InstallApplicationEventHandler(&hotkey_handler, 1, &spec, nullptr, nullptr);
	EventHotKeyRef ref;
	if (self.overlayKey.code >= 0) RegisterEventHotKey(self.overlayKey.code, self.overlayKey.modifiers, EventHotKeyID{ 'MSHD', 1 }, GetApplicationEventTarget(), 0, &ref);
	if (self.effectsKey.code >= 0) RegisterEventHotKey(self.effectsKey.code, self.effectsKey.modifiers, EventHotKeyID{ 'MSHD', 2 }, GetApplicationEventTarget(), 0, &ref);

	if (std::getenv("MACSHADE_FILTER_OPEN_OVERLAY")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self hotkey:1]; });   // debug aid
	_tick = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *) { [self tick]; }];
	[self tick];
}

- (void)hotkey:(UInt32)which
{
	reshade::log::message(reshade::log::level::info, "Screen filter: hotkey %u", (unsigned)which);
	if (which == 1) {
		const bool open = !macshade_bridge_overlay_open();
		macshade_bridge_set_overlay(open);
		[self setInteractive:open];
	} else if (which == 2) macshade_bridge_toggle_effects();
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
	NSDictionary *info = [self gameWindowInfo];
	if (info == nil) {
		[self logState:"game window not found"];
		if (++_hideTicks >= 4 && !_interactive) [_window orderOut:nil];   // gone for a second: hide (a short gap, e.g. a mode change, keeps the picture)
		return;
	}
	CGRect r; CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &r);
	const CGFloat top = NSScreen.screens.firstObject.frame.size.height;
	NSRect frame = NSMakeRect(r.origin.x, top - r.origin.y - r.size.height, r.size.width, r.size.height);
	if (fabs(frame.origin.x - _window.frame.origin.x) > 0.5 || fabs(frame.origin.y - _window.frame.origin.y) > 0.5 || fabs(frame.size.width - _window.frame.size.width) > 0.5 || fabs(frame.size.height - _window.frame.size.height) > 0.5) [_window setFrame:frame display:YES];

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
	const CGSize size = CGSizeMake(round(r.size.width * screen.backingScaleFactor), round(r.size.height * screen.backingScaleFactor));
	const BOOL differs = wid != _windowID || fabs(size.width - _captureSize.width) > 2 || fabs(size.height - _captureSize.height) > 2;
	if (!differs) { _restartTicks = 0; return; }
	if (wid == _pendingWID && fabs(size.width - _pendingSize.width) <= 2 && fabs(size.height - _pendingSize.height) <= 2) ++_restartTicks; else { _pendingWID = wid; _pendingSize = size; _restartTicks = 1; }
	if (!_starting && (_stream == nil || _restartTicks >= 2)) { _restartTicks = 0; [self startStream:wid size:size]; }
}

- (void)startStream:(CGWindowID)wid size:(CGSize)size
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
			SCStreamConfiguration *config = [SCStreamConfiguration new];
			config.width = (size_t)size.width; config.height = (size_t)size.height;
			config.pixelFormat = kCVPixelFormatType_32BGRA;
			config.showsCursor = NO; config.queueDepth = 4;
			config.minimumFrameInterval = CMTimeMake(1, 120);
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
	[_lock lock];
	if (_last) CFRelease(_last);
	_last = (CMSampleBufferRef)CFRetain(sampleBuffer);
	[_lock unlock];
	[self render:sampleBuffer];
}

- (void)redrawLast
{
	[_lock lock]; CMSampleBufferRef sb = _last ? (CMSampleBufferRef)CFRetain(_last) : nullptr; [_lock unlock];
	if (sb == nullptr) return;
	dispatch_async(_queue, ^{ [self render:sb]; CFRelease(sb); });
}

/// Runs on `_queue`: copies the captured frame into a private surface, lets ReShade work on it and hands it to the overlay window.
- (void)render:(CMSampleBufferRef)sampleBuffer
{
	CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
	IOSurfaceRef source = pixels ? CVPixelBufferGetIOSurface(pixels) : nullptr;
	if (source == nullptr) return;
	const uint32_t w = (uint32_t)IOSurfaceGetWidth(source), h = (uint32_t)IOSurfaceGetHeight(source);
	if (w < 16 || h < 16) return;
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
		reshade::log::message(reshade::log::level::info, "Screen filter: processing %ux%u frames.", w, h);
	}
	MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
	sd.usage = MTLTextureUsageShaderRead; sd.storageMode = MTLStorageModeShared;
	id<MTLTexture> src = [_device newTextureWithDescriptor:sd iosurface:source plane:0];
	if (src == nil) return;
	const int i = _next; _next = (_next + 1) % 3;
	id<MTLCommandBuffer> cb = [_commands commandBuffer];
	id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
	[blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:_workTex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
	if (!macshade_bridge_process(w, h, (__bridge void *)_detached, _work)) return;   // ReShade works on the private surface
	macshade_frame_limit();
	// a display surface the window server is not using (an unfinished frame must never be visible)
	int slot = -1;
	for (int k = 0; k < 5 && slot < 0; ++k) { const int c = (_next + k) % 5; if (!IOSurfaceIsInUse(_out[c])) slot = c; }
	if (slot < 0) return;   // all busy: drop this frame
	_next = (slot + 1) % 5;
	id<MTLCommandBuffer> cb2 = [_commands commandBuffer];
	id<MTLBlitCommandEncoder> blit2 = [cb2 blitCommandEncoder];
	[blit2 copyFromTexture:_workTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toTexture:_outTex[slot] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[blit2 endEncoding]; [cb2 commit]; [cb2 waitUntilCompleted];
	IOSurfaceRef shown = _out[slot]; NSView *view = _view;
	dispatch_async(dispatch_get_main_queue(), ^{ [CATransaction begin]; [CATransaction setDisableActions:YES]; view.layer.contents = (__bridge id)shown; [CATransaction commit]; });
}
@end

/// Entry point called by the MacShadeFilter helper: `--pid <game> [--overlay <key>:<mods>] [--effects <key>:<mods>]`.
extern "C" __attribute__((visibility("default"))) int macshade_filter_main(int argc, char **argv)
{
	@autoreleasepool {
		int pid = 0; const char *overlay = nullptr, *effects = nullptr;
		for (int i = 1; i + 1 < argc; ++i) {
			if (!std::strcmp(argv[i], "--pid")) pid = std::atoi(argv[i + 1]);
			else if (!std::strcmp(argv[i], "--overlay")) overlay = argv[i + 1];
			else if (!std::strcmp(argv[i], "--effects")) effects = argv[i + 1];
		}
		if (pid <= 0) { std::fprintf(stderr, "usage: MacShadeFilter --pid <game pid>\n"); return 2; }
		if (!CGPreflightScreenCaptureAccess()) {
			CGRequestScreenCaptureAccess();
			std::fprintf(stderr, "MACSHADE_NEEDS_SCREEN_RECORDING\n");
			return 3;
		}
		[NSApplication sharedApplication];
		[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
		s_controller = [MSFilterController new];
		s_controller.pid = pid; s_controller.overlayKey = parse_hotkey(overlay); s_controller.effectsKey = parse_hotkey(effects);
		[s_controller start];
		[NSApp run];
	}
	return 0;
}
