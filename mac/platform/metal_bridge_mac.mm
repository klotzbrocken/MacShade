// Metal side of the OpenGL/Metal bridge (see vk_bridge_mac.cpp for the idea).
//
// Metal games present through -[MTLCommandBuffer presentDrawable:] (SDL_GPU, MetalKit, native engines). We take over the present:
// once the game's command buffer has finished rendering, the drawable texture is copied into an IOSurface-backed texture, ReShade
// processes the IOSurface through its private Vulkan device, the result is copied back into the drawable and the drawable is presented.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#include "dll_log.hpp"
#include <cstdlib>
#include <mutex>
#include <chrono>
#include <atomic>

extern bool g_app_uses_vulkan;
bool macshade_bridge_process(uint32_t width, uint32_t height, void *layer, void *io_surface);
void macshade_bridge_reset();
void macshade_set_window_override(void *surface_handle, void *window);
void macshade_frame_limit();
bool macshade_bridge_is_idle(bool *fps_only);
bool macshade_bridge_pipeline_init(uint32_t width, uint32_t height, void *layer, void *const io_surfaces[3], void *const depth_surfaces[3]);
bool macshade_bridge_pipeline_uses_depth();
void macshade_bridge_pipeline_submit(int slot, bool with_depth);
void macshade_bridge_pipeline_wait(int slot);
void macshade_bridge_pipeline_drain();

namespace
{
	struct MetalState
	{
		id<MTLDevice> device = nil;
		id<MTLCommandQueue> queue = nil;
		IOSurfaceRef surface = nullptr;
		id<MTLTexture> texture = nil;
		CAMetalLayer *detached = nil;
		MTLPixelFormat format = MTLPixelFormatInvalid;
		NSUInteger width = 0, height = 0;
		bool failed = false;
		unsigned frame = 0;
		// pipelined mode: three frames circulate (see process_pipelined)
		IOSurfaceRef ring_surface[3] = {};
		id<MTLTexture> ring_tex[3] = {};
		id<MTLCommandBuffer> copy_cb[3] = {};
		uint64_t n = 0;
		// depth for ReShade's depth effects: the game's scene depth texture -> (render pass) R32F IOSurface texture
		IOSurfaceRef depth_surface[3] = {};
		id<MTLTexture> depth_tex[3] = {};
		id<MTLCommandBuffer> depth_cb[3] = {};
		bool depth_valid[3] = {}, depth_ok = false;
	} s_state;
	std::atomic<bool> s_depth_wanted{false};   // set by the processing thread (an enabled effect reads depth), read by the game's encoding thread
	id<MTLTexture> s_game_depth = nil;         // the largest recent depth attachment the game rendered to
	std::mutex s_depth_mutex;
	std::mutex s_mutex;

	bool bridge_enabled() { static const bool on = std::getenv("MACSHADE_DISABLE_METAL_BRIDGE") == nullptr; return on && !g_app_uses_vulkan; }

	/// Format of the IOSurface texture for a given drawable format: same bytes when it already is BGRA8, otherwise a conversion pass is used.
	MTLPixelFormat io_format(MTLPixelFormat f) { return (f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB) ? f : MTLPixelFormatBGRA8Unorm; }

	// Fullscreen pass that converts between pixel formats (10-bit, float16, RGBA8, ...)
	NSString *const kConvertSource = @"#include <metal_stdlib>\nusing namespace metal;\n"
		"struct VOut { float4 pos [[position]]; float2 uv; };\n"
		"vertex VOut vs_copy(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); VOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o; }\n"
		"fragment float4 fs_copy(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest); return saturate(t.sample(s, in.uv)); }\n"
		"fragment float4 fs_depth(VOut in [[stage_in]], depth2d<float> t [[texture(0)]]) { constexpr sampler s(filter::nearest); return float4(t.sample(s, in.uv), 0.0, 0.0, 1.0); }\n"
		"fragment float4 fs_depth_ms(VOut in [[stage_in]], depth2d_ms<float> t [[texture(0)]]) { return float4(t.read(uint2(in.pos.xy), 0), 0.0, 0.0, 1.0); }\n";
	id<MTLLibrary> s_library = nil;
	NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *s_pipelines = nil;

	id<MTLRenderPipelineState> pipeline_for(MTLPixelFormat format)
	{
		if (s_pipelines == nil) s_pipelines = [NSMutableDictionary dictionary];
		if (id<MTLRenderPipelineState> cached = s_pipelines[@(format)]) return cached;
		if (s_library == nil) s_library = [s_state.device newLibraryWithSource:kConvertSource options:nil error:nil];
		if (s_library == nil) return nil;
		MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = [s_library newFunctionWithName:@"vs_copy"];
		d.fragmentFunction = [s_library newFunctionWithName:@"fs_copy"];
		d.colorAttachments[0].pixelFormat = format;
		NSError *error = nil;
		id<MTLRenderPipelineState> state = [s_state.device newRenderPipelineStateWithDescriptor:d error:&error];
		if (state) s_pipelines[@(format)] = state;
		return state;
	}

	bool setup(id<MTLTexture> source)
	{
		MetalState &s = s_state;
		macshade_bridge_reset();
		if (s.surface) { CFRelease(s.surface); s.surface = nullptr; }
		s.texture = nil;
		s.width = source.width; s.height = source.height; s.format = source.pixelFormat;
		const int w = (int)s.width, h = (int)s.height, bytes_per_row = (w * 4 + 63) & ~63;
		NSDictionary *props = @{
			(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(bytes_per_row),
			(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
		};
		s.surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		if (s.surface == nullptr) return false;
		MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:io_format(s.format) width:s.width height:s.height mipmapped:NO];
		desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
		desc.storageMode = MTLStorageModeShared;
		s.texture = [s.device newTextureWithDescriptor:desc iosurface:s.surface plane:0];
		if (s.texture == nil) return false;

		s.detached = [CAMetalLayer layer];
		s.detached.device = s.device;
		s.detached.pixelFormat = MTLPixelFormatBGRA8Unorm;
		s.detached.drawableSize = CGSizeMake(w, h);
		s.detached.frame = CGRectMake(0, 0, w, h);
		return true;
	}

	id<MTLRenderPipelineState> depth_pipeline(bool multisample)
	{
		static id<MTLRenderPipelineState> cache[2] = {};
		if (cache[multisample]) return cache[multisample];
		if (s_library == nil) s_library = [s_state.device newLibraryWithSource:kConvertSource options:nil error:nil];
		if (s_library == nil) return nil;
		MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = [s_library newFunctionWithName:@"vs_copy"];
		d.fragmentFunction = [s_library newFunctionWithName:multisample ? @"fs_depth_ms" : @"fs_depth"];
		d.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
		NSError *error = nil;
		cache[multisample] = [s_state.device newRenderPipelineStateWithDescriptor:d error:&error];
		if (!cache[multisample]) reshade::log::message(reshade::log::level::warning, "Bridge: depth pipeline: %s", error.localizedDescription.UTF8String);
		return cache[multisample];
	}

	/// Renders the game's depth texture into `to` (R32Float): one float per pixel, row 0 = top.
	id<MTLCommandBuffer> encode_depth(id<MTLTexture> depth, id<MTLTexture> to)
	{
		id<MTLCommandBuffer> cb = [s_state.queue commandBuffer];
		if (!(depth.usage & MTLTextureUsageShaderRead))   // the game's depth texture cannot be sampled: copy it into one that can
		{
			static id<MTLTexture> copy = nil;
			if (copy == nil || copy.width != depth.width || copy.height != depth.height || copy.pixelFormat != depth.pixelFormat || copy.textureType != depth.textureType || copy.sampleCount != depth.sampleCount)
			{
				MTLTextureDescriptor *td = [MTLTextureDescriptor new];
				td.textureType = depth.textureType; td.pixelFormat = depth.pixelFormat; td.width = depth.width; td.height = depth.height; td.sampleCount = depth.sampleCount;
				td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModePrivate;
				copy = [s_state.device newTextureWithDescriptor:td];
				if (copy == nil) return nil;
			}
			id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
			[blit copyFromTexture:depth toTexture:copy];
			[blit endEncoding];
			depth = copy;
		}
		id<MTLRenderPipelineState> pipeline = depth_pipeline(depth.textureType == MTLTextureType2DMultisample);
		if (pipeline == nil) return nil;
		MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
		pass.colorAttachments[0].texture = to;
		pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
		pass.colorAttachments[0].storeAction = MTLStoreActionStore;
		id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
		[encoder setRenderPipelineState:pipeline];
		[encoder setFragmentTexture:depth atIndex:0];
		[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
		[encoder endEncoding];
		return cb;
	}

	/// Encodes "copy `from` into `to`" (a blit, or a render pass when the pixel formats differ) into a new, not yet committed command buffer.
	id<MTLCommandBuffer> encode_copy(id<MTLTexture> from, id<MTLTexture> to)
	{
		id<MTLCommandBuffer> cb = [s_state.queue commandBuffer];
		if (from.pixelFormat == to.pixelFormat)
		{
			id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
			[blit copyFromTexture:from sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(from.width, from.height, 1)
			            toTexture:to destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
			[blit endEncoding];
		}
		else
		{
			id<MTLRenderPipelineState> pipeline = pipeline_for(to.pixelFormat);
			if (pipeline == nil) { s_state.failed = true; reshade::log::message(reshade::log::level::error, "Bridge: cannot convert pixel format %d.", (int)to.pixelFormat); return nil; }
			MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
			pass.colorAttachments[0].texture = to;
			pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
			pass.colorAttachments[0].storeAction = MTLStoreActionStore;
			id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
			[encoder setRenderPipelineState:pipeline];
			[encoder setFragmentTexture:from atIndex:0];
			[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
			[encoder endEncoding];
		}
		return cb;
	}

	void copy(id<MTLTexture> from, id<MTLTexture> to)
	{
		id<MTLCommandBuffer> cb = encode_copy(from, to);
		if (cb == nil) return;
		[cb commit];
		[cb waitUntilCompleted];
	}

	// MACSHADE_BRIDGE_STATS=1: average milliseconds per frame, logged every 300 frames
	using Clock = std::chrono::steady_clock;
	double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }
	void note_frame(double process_ms)
	{
		static const bool on = std::getenv("MACSHADE_BRIDGE_STATS") != nullptr;
		if (!on) return;
		static double total = 0, interval = 0; static unsigned n = 0; static Clock::time_point last{};
		const auto now = Clock::now();
		if (last.time_since_epoch().count() != 0) interval += ms(last, now);
		last = now; total += process_ms;
		if (++n == 300) { reshade::log::message(reshade::log::level::info, "Bridge stats (Metal, ms/frame): frame interval %.2f (%.0f fps) | process (copy in + ReShade + copy out) %.2f", interval / n, 1000.0 * n / interval, total / n); total = interval = 0; n = 0; }
	}

	/// Runs ReShade over the finished frame in `drawable`. Called once the game's command buffer has completed.
	void process(id<CAMetalDrawable> drawable)
	{
		const auto t_start = Clock::now();
		struct Stat { Clock::time_point t; ~Stat() { note_frame(ms(t, Clock::now())); } } stat{ t_start };
		std::lock_guard<std::mutex> lock(s_mutex);
		MetalState &s = s_state;
		if (s.failed) return;
		@autoreleasepool
		{
			id<MTLTexture> target = drawable.texture;
			if (s.device == nil) { s.device = target.device; s.queue = [s.device newCommandQueue]; }
			if (++s.frame < 10) { stat.t = Clock::now(); return; } // let the game finish starting up
			if (s.texture == nil || target.width != s.width || target.height != s.height || target.pixelFormat != s.format)
			{
				if (!setup(target)) { s.failed = true; reshade::log::message(reshade::log::level::error, "Bridge: could not set up the Metal side."); return; }
				// Input (overlay clicks, hotkeys) belongs to the game's window
				CAMetalLayer *game_layer = drawable.layer;
				NSWindow *window = nil;
				if ([game_layer.delegate isKindOfClass:[NSView class]]) window = ((NSView *)game_layer.delegate).window;
				if (window == nil) window = NSApp.keyWindow ?: NSApp.mainWindow ?: NSApp.windows.firstObject;
				if (window != nil) macshade_set_window_override((__bridge void *)s.detached, (__bridge void *)window);
				reshade::log::message(reshade::log::level::info, "Bridge: processing %lux%lu Metal drawables (pixel format %d).", (unsigned long)s.width, (unsigned long)s.height, (int)s.format);
			}
			static const bool debug = std::getenv("MACSHADE_BRIDGE_DEBUG") != nullptr;
			const bool trace = debug && s.frame < 14;
			if (trace) reshade::log::message(reshade::log::level::info, "Bridge: frame %u: copy in (thread %s)", s.frame, [NSThread isMainThread] ? "main" : "other");
			copy(target, s.texture);
			if (trace) reshade::log::message(reshade::log::level::info, "Bridge: frame %u: reshade", s.frame);
			if (!macshade_bridge_process((uint32_t)s.width, (uint32_t)s.height, (__bridge void *)s.detached, s.surface)) { s.failed = true; return; }
			if (trace) reshade::log::message(reshade::log::level::info, "Bridge: frame %u: copy out", s.frame);
			copy(s.texture, target);
			if (trace) reshade::log::message(reshade::log::level::info, "Bridge: frame %u: done", s.frame);
		}
	}

	bool pipeline_enabled() { static const bool on = std::getenv("MACSHADE_PIPELINE") != nullptr; return on; }

	typedef void (*PresentDrawableFn)(id, SEL, id<MTLDrawable>);
	extern PresentDrawableFn s_orig_present;

	bool setup_ring(id<MTLTexture> source, id<CAMetalDrawable> drawable)
	{
		MetalState &s = s_state;
		macshade_bridge_reset();
		for (int i = 0; i < 3; ++i) { if (s.ring_surface[i]) CFRelease(s.ring_surface[i]); s.ring_surface[i] = nullptr; s.ring_tex[i] = nil; s.copy_cb[i] = nil; }
		s.n = 0; s.surface = nullptr; s.texture = nil;
		s.width = source.width; s.height = source.height; s.format = source.pixelFormat;
		const int w = (int)s.width, h = (int)s.height, bytes_per_row = (w * 4 + 63) & ~63;
		for (int i = 0; i < 3; ++i)
		{
			NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(bytes_per_row), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
			s.ring_surface[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			if (s.ring_surface[i] == nullptr) return false;
			MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:io_format(s.format) width:s.width height:s.height mipmapped:NO];
			desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
			desc.storageMode = MTLStorageModeShared;
			s.ring_tex[i] = [s.device newTextureWithDescriptor:desc iosurface:s.ring_surface[i] plane:0];
			if (s.ring_tex[i] == nil) return false;
		}
		s.detached = [CAMetalLayer layer];
		s.detached.device = s.device;
		s.detached.pixelFormat = MTLPixelFormatBGRA8Unorm;
		s.detached.drawableSize = CGSizeMake(w, h);
		s.detached.frame = CGRectMake(0, 0, w, h);
		// Input (overlay clicks, hotkeys) belongs to the game's window
		NSWindow *window = nil;
		if ([drawable.layer.delegate isKindOfClass:[NSView class]]) window = ((NSView *)drawable.layer.delegate).window;
		if (window == nil) window = NSApp.keyWindow ?: NSApp.mainWindow ?: NSApp.windows.firstObject;
		if (window != nil) macshade_set_window_override((__bridge void *)s.detached, (__bridge void *)window);
		void *surfaces[3] = { s.ring_surface[0], s.ring_surface[1], s.ring_surface[2] };
		// depth (optional): R32Float textures backed by IOSurfaces; without them the pipeline works as before
		static const bool want_depth = std::getenv("MACSHADE_NO_DEPTH") == nullptr;
		bool depth_ready = want_depth;
		for (int i = 0; i < 3 && depth_ready; ++i)
		{
			if (s.depth_surface[i]) { CFRelease(s.depth_surface[i]); s.depth_surface[i] = nullptr; }
			NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @((w * 4 + 63) & ~63), (id)kIOSurfacePixelFormat: @((uint32_t)'L00f') };
			s.depth_surface[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float width:s.width height:s.height mipmapped:NO];
			dd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModeShared;
			s.depth_tex[i] = s.depth_surface[i] ? [s.device newTextureWithDescriptor:dd iosurface:s.depth_surface[i] plane:0] : nil;
			if (s.depth_tex[i] == nil) depth_ready = false;
		}
		void *depth_surfaces[3] = { s.depth_surface[0], s.depth_surface[1], s.depth_surface[2] };
		s.depth_ok = depth_ready && macshade_bridge_pipeline_init((uint32_t)w, (uint32_t)h, (__bridge void *)s.detached, surfaces, depth_surfaces);
		if (!s.depth_ok)
		{
			if (depth_ready) { reshade::log::message(reshade::log::level::info, "Bridge: depth buffer not available, continuing without."); macshade_bridge_reset(); }
			if (!macshade_bridge_pipeline_init((uint32_t)w, (uint32_t)h, (__bridge void *)s.detached, surfaces, nullptr)) return false;
		}
		reshade::log::message(reshade::log::level::info, "Bridge: pipelined processing of %lux%lu Metal drawables (pixel format %d).", (unsigned long)s.width, (unsigned long)s.height, (int)s.format);
		return true;
	}

	/// Pipelined: copies the finished frame n into a ring slot (not awaited), hands frame n-1 to ReShade (not awaited) and shows frame n-2, processed, in this
	/// drawable. The game's own frame is therefore not shown, but two frames later; in exchange nothing here ever waits for the GPU for long.
	void process_pipelined(id<CAMetalDrawable> drawable, void (^present)(void))
	{
		struct Stat { Clock::time_point t = Clock::now(); ~Stat() { note_frame(ms(t, Clock::now())); } } stat;
		std::lock_guard<std::mutex> lock(s_mutex);
		MetalState &s = s_state;
		if (s.failed) { present(); return; }
		@autoreleasepool
		{
			id<MTLTexture> target = drawable.texture;
			if (s.device == nil) { s.device = target.device; s.queue = [s.device newCommandQueue]; }
			if (++s.frame < 10) { present(); return; }   // let the game finish starting up
			if (s.ring_tex[0] == nil || target.width != s.width || target.height != s.height || target.pixelFormat != s.format)
				if (!setup_ring(target, drawable)) { s.failed = true; reshade::log::message(reshade::log::level::error, "Bridge: could not set up the Metal pipeline."); present(); return; }

			bool fps_only = false;
			if (macshade_bridge_is_idle(&fps_only) && !fps_only)   // nothing to show: leave the frame alone (there is no own FPS counter for Metal yet)
			{
				if (s.n != 0) { macshade_bridge_pipeline_drain(); s.n = 0; }
				present(); return;
			}
			const uint64_t n = s.n++;
			const int cur = (int)(n % 3);
			id<MTLCommandBuffer> in = encode_copy(target, s.ring_tex[cur]);
			if (in == nil) { present(); return; }
			[in commit];
			s.copy_cb[cur] = in;
			const bool wants_depth = s.depth_ok && macshade_bridge_pipeline_uses_depth();
			{ static int last = -1; if (last != (int)wants_depth) { last = (int)wants_depth; reshade::log::message(reshade::log::level::info, "Bridge: depth wanted: %d (depth supported: %d).", (int)wants_depth, (int)s.depth_ok); } }
			s_depth_wanted = wants_depth;   // from now on the game's passes keep their depth (see hooked_render_encoder)
			s.depth_valid[cur] = false; s.depth_cb[cur] = nil;
			if (wants_depth)
			{
				id<MTLTexture> game_depth = nil;
				{ std::lock_guard<std::mutex> depth_lock(s_depth_mutex); game_depth = s_game_depth; }
				if (game_depth != nil && game_depth.width == s.width && game_depth.height == s.height)
					if (id<MTLCommandBuffer> dcb = encode_depth(game_depth, s.depth_tex[cur])) { [dcb commit]; s.depth_cb[cur] = dcb; s.depth_valid[cur] = true; }
			}
			if (n >= 1)
			{
				const int prev = (int)((n - 1) % 3);
				[s.copy_cb[prev] waitUntilCompleted];   // long done: one frame ago
				if (s.depth_valid[prev]) [s.depth_cb[prev] waitUntilCompleted];
				macshade_bridge_pipeline_submit(prev, s.depth_valid[prev]);
			}
			if (n < 2) { present(); return; }
			const int old = (int)((n - 2) % 3);
			macshade_bridge_pipeline_wait(old);
			id<MTLCommandBuffer> out = encode_copy(s.ring_tex[old], target);
			if (out == nil) { present(); return; }
			s_orig_present(out, @selector(presentDrawable:), drawable);   // shown when the copy has finished
			[out commit];
		}
	}

	// ---- hooks ----
	typedef void (*PresentAtTimeFn)(id, SEL, id<MTLDrawable>, CFTimeInterval);
	PresentDrawableFn s_orig_present = nullptr;
	PresentAtTimeFn s_orig_present_at = nullptr, s_orig_present_after = nullptr;

	/// Present `drawable` after the command buffer completed and the frame was processed.
	void present_later(id<MTLCommandBuffer> cb, id<MTLDrawable> drawable, void (^present)(void))
	{
		if (![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) { present(); return; }
		[cb addCompletedHandler:^(id<MTLCommandBuffer>) {
			if (pipeline_enabled()) process_pipelined((id<CAMetalDrawable>)drawable, present);
			else { process((id<CAMetalDrawable>)drawable); present(); }
		}];
	}

	void hooked_present_drawable(id self, SEL cmd, id<MTLDrawable> drawable)
	{
		macshade_frame_limit();
		static bool logged = false;
		if (!logged) { logged = true; reshade::log::message(reshade::log::level::info, "Bridge: first presentDrawable: on %s (app Vulkan: %d).", class_getName(object_getClass(self)), (int)g_app_uses_vulkan); }
		if (!bridge_enabled()) { note_frame(0); s_orig_present(self, cmd, drawable); return; }
		present_later(self, drawable, ^{ [drawable present]; });
	}
	void hooked_present_at(id self, SEL cmd, id<MTLDrawable> drawable, CFTimeInterval time)
	{
		macshade_frame_limit();
		if (!bridge_enabled()) { s_orig_present_at(self, cmd, drawable, time); return; }
		present_later(self, drawable, ^{ [drawable presentAtTime:time]; });
	}
	void hooked_present_after(id self, SEL cmd, id<MTLDrawable> drawable, CFTimeInterval duration)
	{
		macshade_frame_limit();
		if (!bridge_enabled()) { s_orig_present_after(self, cmd, drawable, duration); return; }
		present_later(self, drawable, ^{ [drawable presentAfterMinimumDuration:duration]; });
	}

	// The game's scene depth: remember the depth attachment of the render passes, and while an effect needs depth keep it (many games discard it at the end of the pass)
	id (*s_orig_render_encoder)(id, SEL, MTLRenderPassDescriptor *) = nullptr;
	id hooked_render_encoder(id self, SEL cmd, MTLRenderPassDescriptor *desc)
	{
		if (s_depth_wanted.load(std::memory_order_relaxed))
		{
			id<MTLTexture> depth = desc.depthAttachment.texture;
			static id<MTLTexture> logged = nil;
			if (depth != nil && depth != logged && depth.width >= 320) { logged = depth; reshade::log::message(reshade::log::level::info, "Bridge: depth attachment %lux%lu, format %d, type %d, usage 0x%x, storage %d, store action %d.", (unsigned long)depth.width, (unsigned long)depth.height, (int)depth.pixelFormat, (int)depth.textureType, (unsigned)depth.usage, (int)depth.storageMode, (int)desc.depthAttachment.storeAction); }
			if (depth != nil && depth.width >= 320 && depth.storageMode != MTLStorageModeMemoryless)
			{
				if (desc.depthAttachment.storeAction == MTLStoreActionDontCare) desc.depthAttachment.storeAction = MTLStoreActionStore;
				std::lock_guard<std::mutex> lock(s_depth_mutex);
				s_game_depth = depth;
			}
		}
		return s_orig_render_encoder(self, cmd, desc);
	}

	id (*s_orig_next_drawable)(id, SEL) = nullptr;
	id hooked_next_drawable(id self, SEL cmd)
	{
		if (bridge_enabled() && [(CAMetalLayer *)self framebufferOnly]) [(CAMetalLayer *)self setFramebufferOnly:NO]; // the drawable has to be readable
		return s_orig_next_drawable(self, cmd);
	}

	/// The class in the hierarchy of `cls` that implements `sel` itself (swizzling there covers all subclasses, e.g. every kind of command buffer).
	Class owner_class(Class cls, SEL sel)
	{
		for (Class c = cls; c != nil; c = class_getSuperclass(c))
		{
			unsigned int count = 0;
			Method *methods = class_copyMethodList(c, &count);
			bool found = false;
			for (unsigned int i = 0; i < count && !found; ++i) found = method_getName(methods[i]) == sel;
			free(methods);
			if (found) return c;
		}
		return cls;
	}

	template <typename F> bool swizzle(Class cls, SEL sel, void *replacement, F &original)
	{
		cls = owner_class(cls, sel);
		Method method = class_getInstanceMethod(cls, sel);
		if (method == nullptr) return false;
		original = reinterpret_cast<F>(method_getImplementation(method));
		class_replaceMethod(cls, sel, reinterpret_cast<IMP>(replacement), method_getTypeEncoding(method));
		return true;
	}

	__attribute__((constructor)) void install_metal_hooks()
	{
		if (std::getenv("MACSHADE_DISABLE_METAL_BRIDGE")) return;
		@autoreleasepool
		{
			// concrete command buffer class of this GPU (an AGX... class on Apple silicon)
			id<MTLDevice> device = MTLCreateSystemDefaultDevice();
			if (device == nil) return;
			id<MTLCommandBuffer> sample = [[device newCommandQueue] commandBuffer];
			Class cb_class = object_getClass(sample);
			swizzle(cb_class, @selector(presentDrawable:), (void *)&hooked_present_drawable, s_orig_present);
			swizzle(cb_class, @selector(renderCommandEncoderWithDescriptor:), (void *)&hooked_render_encoder, s_orig_render_encoder);
			swizzle(cb_class, @selector(presentDrawable:atTime:), (void *)&hooked_present_at, s_orig_present_at);
			swizzle(cb_class, @selector(presentDrawable:afterMinimumDuration:), (void *)&hooked_present_after, s_orig_present_after);
			swizzle([CAMetalLayer class], @selector(nextDrawable), (void *)&hooked_next_drawable, s_orig_next_drawable);
		}
	}
}
