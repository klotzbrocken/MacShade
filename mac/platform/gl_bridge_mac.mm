// OpenGL side of the OpenGL/Metal bridge (see vk_bridge_mac.cpp for the idea).
//
// Hooks CGLFlushDrawable, which every OpenGL application on macOS ends up calling once per frame (SDL, GLFW, NSOpenGLContext flushBuffer).
// At that moment the finished frame sits in the back buffer of the default framebuffer:
//   1. blit it (GPU) into a texture that is backed by an IOSurface,                    -- flipped, so that row 0 is the top row
//   2. let ReShade process the IOSurface through its private Vulkan device,
//   3. blit the result back into the default framebuffer and present as usual.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <OpenGL/OpenGL.h>
#define GL_GLEXT_PROTOTYPES 1
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
// core-profile vertex array functions (declared in <OpenGL/gl3.h>, which cannot be mixed with the legacy header)
extern "C" { void glGenVertexArrays(GLsizei, GLuint *); void glBindVertexArray(GLuint); void glDeleteVertexArrays(GLsizei, const GLuint *); }
#define GL_VERTEX_ARRAY_BINDING 0x85B5
#include "dll_log.hpp"
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
#include <cstdlib>
#include <unordered_map>
#include <chrono>
#include <vector>
#include <cstring>

extern bool g_app_uses_vulkan;
bool macshade_bridge_process(uint32_t width, uint32_t height, void *layer, void *io_surface);
void macshade_bridge_reset();
bool macshade_bridge_is_idle(bool *fps_only);
void macshade_frame_limit();
bool macshade_bridge_pipeline_init(uint32_t width, uint32_t height, void *layer, void *const io_surfaces[3], void *const depth_surfaces[3]);
bool macshade_bridge_pipeline_uses_depth();
void macshade_bridge_pipeline_submit(int slot, bool with_depth);
void macshade_bridge_pipeline_wait(int slot);
void macshade_bridge_pipeline_drain();
void macshade_set_window_override(void *surface_handle, void *window);

#define INTERPOSE(replacement, replacee) \
	__attribute__((used)) static struct { const void *r; const void *o; } _interpose_##replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

namespace
{
	struct ContextState
	{
		IOSurfaceRef surface = nullptr;
		CAMetalLayer *layer = nil;
		GLuint texture = 0, fbo = 0, resolve_fbo = 0, resolve_rb = 0, orig_fbo = 0, orig_rb = 0; // orig_*: the unprocessed frame, put back after the swap; // resolve_*: single-sample intermediate for multisampled default framebuffers
		int width = 0, height = 0;
		bool failed = false;
		unsigned frame = 0;
		// pipelined mode: three frames circulate (see pipelined_step)
		IOSurfaceRef ring_surface[3] = {}; GLuint ring_tex[3] = {}, ring_fbo[3] = {}; GLsync ring_sync[3] = {}; GLuint ring_apple_fence[3] = {}; uint64_t ring_n = 0;
		// depth for ReShade's depth effects (pipelined mode): game depth buffer -> depth texture -> (shader) R32F IOSurface
		IOSurfaceRef depth_surface[3] = {}; GLuint depth_tex[3] = {}, depth_fbo[3] = {}, depth_src_tex = 0, depth_src_fbo = 0, depth_prog = 0, depth_vao = 0; bool depth_valid[3] = {}, depth_ok = false, depth_failed = false; GLuint game_depth_fbo = 0; uint64_t depth_probe_at = 0;
		IOSurfaceRef fps_surface = nullptr; GLuint fps_tex = 0, fps_fbo = 0; int fps_shown = -1, fps_w = 0, fps_h = 0; double fps_time = 0; unsigned fps_frames = 0;   // own FPS counter
	};
	std::unordered_map<CGLContextObj, ContextState> s_contexts;
	CGLContextObj s_active_context = nullptr; // only one context is processed (the first one that presents)

	bool bridge_enabled()
	{
		static const bool enabled = std::getenv("MACSHADE_DISABLE_GL_BRIDGE") == nullptr;
		return enabled && !g_app_uses_vulkan;
	}

	void release(ContextState &s)
	{
		for (int i = 0; i < 3; ++i)
		{
			if (s.ring_fbo[i]) glDeleteFramebuffers(1, &s.ring_fbo[i]);
			if (s.ring_tex[i]) glDeleteTextures(1, &s.ring_tex[i]);
			if (s.ring_surface[i]) CFRelease(s.ring_surface[i]);
			if (s.ring_sync[i]) glDeleteSync(s.ring_sync[i]);
			if (s.ring_apple_fence[i]) glDeleteFencesAPPLE(1, &s.ring_apple_fence[i]);
			s.ring_fbo[i] = s.ring_tex[i] = s.ring_apple_fence[i] = 0; s.ring_surface[i] = nullptr; s.ring_sync[i] = nullptr;
		}
		s.ring_n = 0;
		for (int i = 0; i < 3; ++i)
		{
			if (s.depth_fbo[i]) glDeleteFramebuffers(1, &s.depth_fbo[i]);
			if (s.depth_tex[i]) glDeleteTextures(1, &s.depth_tex[i]);
			if (s.depth_surface[i]) CFRelease(s.depth_surface[i]);
			s.depth_fbo[i] = s.depth_tex[i] = 0; s.depth_surface[i] = nullptr; s.depth_valid[i] = false;
		}
		if (s.depth_src_fbo) glDeleteFramebuffers(1, &s.depth_src_fbo);
		if (s.depth_src_tex) glDeleteTextures(1, &s.depth_src_tex);
		if (s.depth_prog) glDeleteProgram(s.depth_prog);
		if (s.depth_vao) glDeleteVertexArrays(1, &s.depth_vao);
		s.depth_src_fbo = s.depth_src_tex = s.depth_prog = s.depth_vao = 0; s.depth_ok = false; s.depth_failed = false;
		if (s.fps_fbo) glDeleteFramebuffers(1, &s.fps_fbo);
		if (s.fps_tex) glDeleteTextures(1, &s.fps_tex);
		if (s.fps_surface) CFRelease(s.fps_surface);
		s.fps_surface = nullptr; s.fps_fbo = s.fps_tex = 0; s.fps_shown = -1;
		if (s.fbo) glDeleteFramebuffers(1, &s.fbo);
		if (s.orig_fbo) glDeleteFramebuffers(1, &s.orig_fbo);
		if (s.orig_rb) glDeleteRenderbuffers(1, &s.orig_rb);
		s.orig_fbo = s.orig_rb = 0;
		if (s.resolve_fbo) glDeleteFramebuffers(1, &s.resolve_fbo);
		if (s.resolve_rb) glDeleteRenderbuffers(1, &s.resolve_rb);
		s.resolve_fbo = s.resolve_rb = 0;
		if (s.texture) glDeleteTextures(1, &s.texture);
		if (s.surface) CFRelease(s.surface);
		s.fbo = s.texture = 0; s.surface = nullptr; s.layer = nil;
	}

	bool setup(CGLContextObj ctx, ContextState &s, int w, int h)
	{
		release(s);
		const int bytes_per_row = (w * 4 + 63) & ~63;
		NSDictionary *props = @{
			(id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(bytes_per_row),
			(id)kIOSurfacePixelFormat: @((uint32_t)'BGRA'),
		};
		s.surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
		if (s.surface == nullptr) return false;

		glGenTextures(1, &s.texture);
		GLint previous_texture = 0;
		glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &previous_texture);
		glBindTexture(GL_TEXTURE_RECTANGLE_ARB, s.texture);
		const CGLError error = CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, s.surface, 0);
		glBindTexture(GL_TEXTURE_RECTANGLE_ARB, previous_texture);
		if (error != kCGLNoError) { reshade::log::message(reshade::log::level::error, "Bridge: CGLTexImageIOSurface2D failed (%d).", (int)error); return false; }

		glGenFramebuffers(1, &s.fbo);
		GLint previous_fbo = 0;
		glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous_fbo);
		glBindFramebuffer(GL_FRAMEBUFFER, s.fbo);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, s.texture, 0);
		const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
		// intermediate for multisampled default framebuffers (a blit from/to those may not flip)
		glGenRenderbuffers(1, &s.resolve_rb);
		glBindRenderbuffer(GL_RENDERBUFFER, s.resolve_rb);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
		glGenFramebuffers(1, &s.resolve_fbo);
		glBindFramebuffer(GL_FRAMEBUFFER, s.resolve_fbo);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, s.resolve_rb);
		glGenRenderbuffers(1, &s.orig_rb);
		glBindRenderbuffer(GL_RENDERBUFFER, s.orig_rb);
		glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, w, h);
		glGenFramebuffers(1, &s.orig_fbo);
		glBindFramebuffer(GL_FRAMEBUFFER, s.orig_fbo);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, s.orig_rb);
		glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo);
		if (status != GL_FRAMEBUFFER_COMPLETE) { reshade::log::message(reshade::log::level::error, "Bridge: framebuffer incomplete (0x%x).", status); return false; }

		// A detached layer: the bridge's Vulkan swap chain is created on it but never shown
		s.layer = [CAMetalLayer layer];
		s.layer.device = MTLCreateSystemDefaultDevice();
		s.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
		s.layer.drawableSize = CGSizeMake(w, h);
		s.layer.frame = CGRectMake(0, 0, w, h);
		s.width = w; s.height = h;

		// Input (overlay clicks, hotkeys) belongs to the game's window
		if (NSOpenGLContext *current = [NSOpenGLContext currentContext])
			if (NSWindow *window = current.view.window)
				macshade_set_window_override((__bridge void *)s.layer, (__bridge void *)window);
		return true;
	}

	/// Copies `src_fbo` -> `dst_fbo` (0 = default framebuffer), optionally flipping vertically.
	void blit(GLuint src_fbo, GLuint dst_fbo, int w, int h, bool flip = true)
	{
		glBindFramebuffer(GL_READ_FRAMEBUFFER, src_fbo);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst_fbo);
		if (src_fbo == 0) glReadBuffer(GL_BACK); else glReadBuffer(GL_COLOR_ATTACHMENT0);
		if (dst_fbo == 0) { GLenum back = GL_BACK; glDrawBuffers(1, &back); } else { GLenum a0 = GL_COLOR_ATTACHMENT0; glDrawBuffers(1, &a0); }
		glBlitFramebuffer(0, 0, w, h, 0, flip ? h : 0, w, flip ? 0 : h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
	}

	/// The FPS counter, drawn by the bridge itself (a small bitmap blitted into the corner) when ReShade has nothing else to show: letting ReShade
	/// draw a single number would cost a full frame hand-over to its Vulkan device. The bitmap lives in an IOSurface (written by the CPU, read as a
	/// texture, the same mechanism as the frame copy), so no texture upload with the game's unpack state is involved.
	CTFontRef s_fps_font = CTFontCreateWithName(CFSTR("Menlo-Bold"), 40, nullptr);

	void draw_fps_counter(CGLContextObj ctx, ContextState &s)
	{
		const double now = CACurrentMediaTime();
		++s.fps_frames;
		if (s.fps_time == 0) s.fps_time = now;
		const int scale = s.width > 2000 ? 2 : 1, w = 132 * scale, h = 34 * scale;
		if (s.fps_surface == nullptr)
		{
			NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(w * 4), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
			s.fps_surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			if (s.fps_surface == nullptr) return;
			GLint previous_texture = 0, previous_fbo = 0;
			glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &previous_texture); glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous_fbo);
			glGenTextures(1, &s.fps_tex); glBindTexture(GL_TEXTURE_RECTANGLE_ARB, s.fps_tex);
			CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, s.fps_surface, 0);
			glGenFramebuffers(1, &s.fps_fbo); glBindFramebuffer(GL_FRAMEBUFFER, s.fps_fbo);
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, s.fps_tex, 0);
			glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo); glBindTexture(GL_TEXTURE_RECTANGLE_ARB, previous_texture);
			s.fps_w = w; s.fps_h = h; s.fps_shown = -1;
		}
		if (now - s.fps_time >= 0.5 || s.fps_shown < 0)
		{
			const int fps = (int)(s.fps_frames / std::max(now - s.fps_time, 0.001) + 0.5);
			s.fps_frames = 0; s.fps_time = now;
			if (fps != s.fps_shown)
			{
				s.fps_shown = fps;
				CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
				CGContextRef c = CGBitmapContextCreate(nullptr, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
				CGContextSetRGBFillColor(c, 0.05, 0.05, 0.05, 1); CGContextFillRect(c, CGRectMake(0, 0, w, h));
				CTFontRef font = CTFontCreateCopyWithAttributes(s_fps_font, 20.0 * scale, nullptr, nullptr);
				NSDictionary *attrs = @{ (id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorFromContextAttributeName: @YES };
				CGContextSetRGBFillColor(c, 1, 1, 1, 1);
				CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%d FPS", fps] attributes:attrs]);
				const CGRect bounds = CTLineGetBoundsWithOptions(line, 0);
				CGContextSetTextPosition(c, w - 8 * scale - bounds.size.width, 9 * scale); CTLineDraw(line, c); CFRelease(line); CFRelease(font);
				// GL row 0 is the bottom: store the bitmap upside down, so the blit below is 1:1 (a multisampled default framebuffer cannot scale or flip)
				IOSurfaceLock(s.fps_surface, 0, nullptr);
				uint8_t *dst = (uint8_t *)IOSurfaceGetBaseAddress(s.fps_surface); const size_t stride = IOSurfaceGetBytesPerRow(s.fps_surface);
				for (int y = 0; y < h; ++y) memcpy(dst + (size_t)y * stride, (const uint8_t *)CGBitmapContextGetData(c) + (size_t)(h - 1 - y) * w * 4, (size_t)w * 4);
				IOSurfaceUnlock(s.fps_surface, 0, nullptr);
				CGContextRelease(c); CGColorSpaceRelease(cs);
			}
		}

		GLint read_fbo, draw_fbo, read_buffer, draw_buffer;
		GLboolean mask[4], scissor = glIsEnabled(GL_SCISSOR_TEST), srgb = glIsEnabled(GL_FRAMEBUFFER_SRGB), blend = glIsEnabled(GL_BLEND);
		glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo);
		glGetIntegerv(GL_READ_BUFFER, &read_buffer); glGetIntegerv(GL_DRAW_BUFFER0, &draw_buffer); glGetBooleanv(GL_COLOR_WRITEMASK, mask);
		glDisable(GL_SCISSOR_TEST); glDisable(GL_FRAMEBUFFER_SRGB); glDisable(GL_BLEND); glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
		const int margin = 12 * scale, x0 = s.width - margin - s.fps_w, y1 = s.height - margin, y0 = y1 - s.fps_h;
		glBindFramebuffer(GL_READ_FRAMEBUFFER, s.fps_fbo); glReadBuffer(GL_COLOR_ATTACHMENT0);
		glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0); { GLenum back = GL_BACK; glDrawBuffers(1, &back); }
		glBlitFramebuffer(0, 0, s.fps_w, s.fps_h, x0, y0, x0 + s.fps_w, y1, GL_COLOR_BUFFER_BIT, GL_NEAREST);
		glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_fbo); glReadBuffer(read_buffer);
		GLenum buf = (GLenum)draw_buffer; glDrawBuffers(1, &buf); glColorMask(mask[0], mask[1], mask[2], mask[3]);
		if (scissor) glEnable(GL_SCISSOR_TEST); if (srgb) glEnable(GL_FRAMEBUFFER_SRGB); if (blend) glEnable(GL_BLEND);
	}

	void dump_surface(IOSurfaceRef surface, const char *name);
	thread_local bool t_in_flush = false;

	/// Runs ReShade on the frame that is about to be presented (does nothing when the bridge is off or unavailable).
	GLuint s_restore_fbo = 0; int s_restore_w = 0, s_restore_h = 0;

	bool pipeline_enabled() { static const bool on = std::getenv("MACSHADE_PIPELINE") != nullptr; return on; }

	// GL fences: glFenceSync in core profiles, GL_APPLE_fence in legacy (2.x) contexts
	bool modern_gl() { static int major = [] { const char *v = (const char *)glGetString(GL_VERSION); return v ? atoi(v) : 2; }(); return major >= 3; }
	void fence_insert(ContextState &s, int i)
	{
		if (modern_gl()) { if (s.ring_sync[i]) glDeleteSync(s.ring_sync[i]); s.ring_sync[i] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0); }
		else { if (!s.ring_apple_fence[i]) glGenFencesAPPLE(1, &s.ring_apple_fence[i]); glSetFenceAPPLE(s.ring_apple_fence[i]); }
		glFlush();
	}
	void fence_wait(ContextState &s, int i)
	{
		if (modern_gl()) { if (s.ring_sync[i]) glClientWaitSync(s.ring_sync[i], GL_SYNC_FLUSH_COMMANDS_BIT, 2000000000ull); }
		else if (s.ring_apple_fence[i]) glFinishFenceAPPLE(s.ring_apple_fence[i]);
	}

	bool setup_ring(CGLContextObj ctx, ContextState &s)
	{
		const int w = s.width, h = s.height, bytes_per_row = (w * 4 + 63) & ~63;
		GLint previous_texture = 0, previous_fbo = 0;
		glGetIntegerv(GL_TEXTURE_BINDING_RECTANGLE_ARB, &previous_texture); glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous_fbo);
		for (int i = 0; i < 3; ++i)
		{
			NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @(bytes_per_row), (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
			s.ring_surface[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			if (s.ring_surface[i] == nullptr) return false;
			glGenTextures(1, &s.ring_tex[i]); glBindTexture(GL_TEXTURE_RECTANGLE_ARB, s.ring_tex[i]);
			if (CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE_ARB, GL_RGBA, w, h, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, s.ring_surface[i], 0) != kCGLNoError) return false;
			glGenFramebuffers(1, &s.ring_fbo[i]); glBindFramebuffer(GL_FRAMEBUFFER, s.ring_fbo[i]);
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, s.ring_tex[i], 0);
			if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;
		}
		// depth (R32F, one component): optional, the pipeline works without it
		static const bool want_depth = std::getenv("MACSHADE_NO_DEPTH") == nullptr;   // depth for ReShade (only converted while an effect reads it)
		bool depth_surfaces = want_depth;
		for (int i = 0; i < 3 && depth_surfaces; ++i)
		{
			NSDictionary *props = @{ (id)kIOSurfaceWidth: @(w), (id)kIOSurfaceHeight: @(h), (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfaceBytesPerRow: @((w * 4 + 63) & ~63), (id)kIOSurfacePixelFormat: @((uint32_t)'L00f') };
			s.depth_surface[i] = IOSurfaceCreate((__bridge CFDictionaryRef)props);
			if (s.depth_surface[i] == nullptr) { depth_surfaces = false; break; }
			glGenTextures(1, &s.depth_tex[i]); glBindTexture(GL_TEXTURE_RECTANGLE_ARB, s.depth_tex[i]);
			if (CGLTexImageIOSurface2D(ctx, GL_TEXTURE_RECTANGLE_ARB, GL_R32F, w, h, GL_RED, GL_FLOAT, s.depth_surface[i], 0) != kCGLNoError) { depth_surfaces = false; break; }
			glGenFramebuffers(1, &s.depth_fbo[i]); glBindFramebuffer(GL_FRAMEBUFFER, s.depth_fbo[i]);
			glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_RECTANGLE_ARB, s.depth_tex[i], 0);
			if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { depth_surfaces = false; break; }
		}
		glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo); glBindTexture(GL_TEXTURE_RECTANGLE_ARB, previous_texture);
		if (depth_surfaces && macshade_bridge_pipeline_init(w, h, (__bridge void *)s.layer, (void *const *)s.ring_surface, (void *const *)s.depth_surface)) { s.depth_ok = true; return true; }
		// without depth
		if (want_depth) { reshade::log::message(reshade::log::level::info, "Bridge: depth buffer not available, continuing without."); macshade_bridge_reset(); }
		for (int i = 0; i < 3; ++i) { if (s.depth_fbo[i]) glDeleteFramebuffers(1, &s.depth_fbo[i]); if (s.depth_tex[i]) glDeleteTextures(1, &s.depth_tex[i]); if (s.depth_surface[i]) CFRelease(s.depth_surface[i]); s.depth_fbo[i] = s.depth_tex[i] = 0; s.depth_surface[i] = nullptr; }
		return macshade_bridge_pipeline_init(w, h, (__bridge void *)s.layer, (void *const *)s.ring_surface, nullptr);
	}

	GLuint compile_program(const char *vs, const char *fs)
	{
		const auto compile = [](GLenum type, const char *src) {
			GLuint sh = glCreateShader(type); glShaderSource(sh, 1, &src, nullptr); glCompileShader(sh);
			GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
			if (!ok) { char log[512] = {}; glGetShaderInfoLog(sh, sizeof log, nullptr, log); reshade::log::message(reshade::log::level::warning, "Bridge: depth shader: %s", log); glDeleteShader(sh); return GLuint(0); }
			return sh;
		};
		GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
		if (!v || !f) return 0;
		GLuint prog = glCreateProgram(); glAttachShader(prog, v); glAttachShader(prog, f); glLinkProgram(prog);
		glDeleteShader(v); glDeleteShader(f);
		GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
		if (!ok) { glDeleteProgram(prog); return 0; }
		return prog;
	}

	/// Which framebuffer object holds the game's scene depth? Games rarely render into the window's own buffer: look for the FBO (not one of ours) whose depth
	/// attachment has the size of the frame; the one with the lowest id wins (the main scene target is created first). Returns 0 for "the default framebuffer".
	GLuint find_game_depth_fbo(ContextState &s)
	{
		GLint saved_rb = 0, saved_tex = 0, saved_read = 0; glGetIntegerv(GL_RENDERBUFFER_BINDING, &saved_rb); glGetIntegerv(GL_TEXTURE_BINDING_2D, &saved_tex); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &saved_read);
		const auto ours = [&](GLuint id) { if (id == s.fbo || id == s.orig_fbo || id == s.resolve_fbo || id == s.depth_src_fbo || id == s.fps_fbo) return true; for (int i = 0; i < 3; ++i) if (id == s.ring_fbo[i] || id == s.depth_fbo[i]) return true; return false; };
		GLuint found = 0;
		for (GLuint id = 1; id < 128 && found == 0; ++id)
		{
			if (ours(id) || !glIsFramebuffer(id)) continue;
			glBindFramebuffer(GL_READ_FRAMEBUFFER, id);
			GLint type = 0, name = 0, w = 0, h = 0;
			glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
			if (!type) { glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type); if (type) glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name); }
			else glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
			if (type == GL_RENDERBUFFER) { glBindRenderbuffer(GL_RENDERBUFFER, name); glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &w); glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &h); }
			else if (type == GL_TEXTURE) { glBindTexture(GL_TEXTURE_2D, name); glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &w); glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &h); }
			if (w == s.width && h == s.height) found = id;
		}
		glBindRenderbuffer(GL_RENDERBUFFER, saved_rb); glBindTexture(GL_TEXTURE_2D, saved_tex); glBindFramebuffer(GL_READ_FRAMEBUFFER, saved_read);
		return found;
	}

	/// Creates what the depth conversion needs: a depth texture of the game's depth format, and a shader that writes it (flipped, row 0 = top) as a float.
	bool setup_depth(ContextState &s)
	{
		GLint bits = 0;
		glBindFramebuffer(GL_READ_FRAMEBUFFER, s.game_depth_fbo);
		if (s.game_depth_fbo == 0) glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_DEPTH, GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, &bits);
		else glGetFramebufferAttachmentParameteriv(GL_READ_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE, &bits);
		if (bits <= 0) { reshade::log::message(reshade::log::level::info, "Bridge: the game has no depth buffer."); return false; }
		const GLenum format = bits <= 16 ? GL_DEPTH_COMPONENT16 : (bits <= 24 ? GL_DEPTH_COMPONENT24 : GL_DEPTH_COMPONENT32);
		GLint previous_texture = 0; glGetIntegerv(GL_TEXTURE_BINDING_2D, &previous_texture);
		glGenTextures(1, &s.depth_src_tex); glBindTexture(GL_TEXTURE_2D, s.depth_src_tex);
		glTexImage2D(GL_TEXTURE_2D, 0, format, s.width, s.height, 0, GL_DEPTH_COMPONENT, GL_UNSIGNED_INT, nullptr);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
		glBindTexture(GL_TEXTURE_2D, previous_texture);
		glGenFramebuffers(1, &s.depth_src_fbo); glBindFramebuffer(GL_FRAMEBUFFER, s.depth_src_fbo);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, s.depth_src_tex, 0);
		glDrawBuffer(GL_NONE); glReadBuffer(GL_NONE);
		const bool complete = glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
		if (!complete) { reshade::log::message(reshade::log::level::warning, "Bridge: depth framebuffer incomplete."); return false; }
		if (modern_gl())
			s.depth_prog = compile_program(
				"#version 150\nout vec2 uv;\nvoid main(){ vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n",
				"#version 150\nuniform sampler2D d; in vec2 uv; out vec4 c;\nvoid main(){ c = vec4(texture(d, vec2(uv.x, 1.0 - uv.y)).r, 0.0, 0.0, 1.0); }\n");
		else
			s.depth_prog = compile_program(
				"#version 120\nvarying vec2 uv;\nvoid main(){ uv = gl_Vertex.xy * 0.5 + 0.5; gl_Position = vec4(gl_Vertex.xy, 0.0, 1.0); }\n",
				"#version 120\nuniform sampler2D d; varying vec2 uv;\nvoid main(){ gl_FragColor = vec4(texture2D(d, vec2(uv.x, 1.0 - uv.y)).r, 0.0, 0.0, 1.0); }\n");
		if (s.depth_prog == 0) return false;
		if (modern_gl()) glGenVertexArrays(1, &s.depth_vao);
		reshade::log::message(reshade::log::level::info, "Bridge: depth buffer supplied to ReShade (%d bit, %s GL).", (int)bits, modern_gl() ? "core" : "legacy");
		return true;
	}

	/// Copies the game's depth buffer of the frame being flushed into depth slot `slot` (R32F IOSurface). Returns false when that is not possible.
	bool convert_depth(ContextState &s, int slot)
	{
		if (!s.depth_ok || s.depth_failed) return false;
		if (s.depth_prog == 0)   // first use: look for the game's scene depth, then set up
		{
			s.game_depth_fbo = find_game_depth_fbo(s);
			reshade::log::message(reshade::log::level::info, "Bridge: depth is read from framebuffer %u%s.", s.game_depth_fbo, s.game_depth_fbo ? "" : " (the default one)");
			if (!setup_depth(s)) { s.depth_failed = true; return false; }
		}
		while (glGetError() != GL_NO_ERROR) {}
		glBindFramebuffer(GL_READ_FRAMEBUFFER, s.game_depth_fbo); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, s.depth_src_fbo);
		glBlitFramebuffer(0, 0, s.width, s.height, 0, 0, s.width, s.height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
		if (GLenum e = glGetError()) { reshade::log::message(reshade::log::level::warning, "Bridge: depth blit failed (0x%x); no depth for ReShade.", e); s.depth_failed = true; return false; }
		// save what the conversion changes
		GLint program = 0, active_texture = 0, texture0 = 0, viewport[4] = {}, vao = 0; GLboolean mask[4];
		glGetIntegerv(GL_CURRENT_PROGRAM, &program); glGetIntegerv(GL_ACTIVE_TEXTURE, &active_texture); glGetIntegerv(GL_VIEWPORT, viewport); glGetBooleanv(GL_COLOR_WRITEMASK, mask);
		glActiveTexture(GL_TEXTURE0); glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture0);
		if (modern_gl()) glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
		const GLenum flags[] = { GL_DEPTH_TEST, GL_CULL_FACE, GL_BLEND, GL_SCISSOR_TEST, GL_STENCIL_TEST, GL_FRAMEBUFFER_SRGB };
		GLboolean was[6]; for (int i = 0; i < 6; ++i) { was[i] = glIsEnabled(flags[i]); glDisable(flags[i]); }
		GLboolean legacy_alpha = GL_FALSE, legacy_fog = GL_FALSE;
		if (!modern_gl()) { legacy_alpha = glIsEnabled(GL_ALPHA_TEST); legacy_fog = glIsEnabled(GL_FOG); glDisable(GL_ALPHA_TEST); glDisable(GL_FOG); glPushAttrib(GL_POLYGON_BIT | GL_TEXTURE_BIT | GL_LIGHTING_BIT); glPolygonMode(GL_FRONT_AND_BACK, GL_FILL); }

		glBindFramebuffer(GL_FRAMEBUFFER, s.depth_fbo[slot]);
		glViewport(0, 0, s.width, s.height); glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
		glUseProgram(s.depth_prog);
		glUniform1i(glGetUniformLocation(s.depth_prog, "d"), 0);
		glBindTexture(GL_TEXTURE_2D, s.depth_src_tex);
		if (modern_gl()) { glBindVertexArray(s.depth_vao); glDrawArrays(GL_TRIANGLES, 0, 3); }
		else { glBegin(GL_TRIANGLES); glVertex2f(-1, -1); glVertex2f(3, -1); glVertex2f(-1, 3); glEnd(); }

		if (!modern_gl()) { glPopAttrib(); if (legacy_alpha) glEnable(GL_ALPHA_TEST); if (legacy_fog) glEnable(GL_FOG); }
		glBindTexture(GL_TEXTURE_2D, texture0); glActiveTexture(active_texture);
		if (modern_gl()) glBindVertexArray(vao);
		glUseProgram(program); glViewport(viewport[0], viewport[1], viewport[2], viewport[3]); glColorMask(mask[0], mask[1], mask[2], mask[3]);
		for (int i = 0; i < 6; ++i) if (was[i]) glEnable(flags[i]);
		if (GLenum e = glGetError()) { reshade::log::message(reshade::log::level::warning, "Bridge: depth conversion error 0x%x; no depth for ReShade.", e); s.depth_failed = true; return false; }
		static const bool debug = std::getenv("MACSHADE_BRIDGE_DEBUG") != nullptr;
		if (debug && s.ring_n % 300 == 5)   // look at what was written: min / max / mean of a sample of the depth values
		{
			glFinish();
			IOSurfaceLock(s.depth_surface[slot], kIOSurfaceLockReadOnly, nullptr);
			const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s.depth_surface[slot]); const size_t stride = IOSurfaceGetBytesPerRow(s.depth_surface[slot]);
			double mn = 1e9, mx = -1e9, sum = 0; unsigned count = 0;
			for (int y = 0; y < s.height; y += 16) for (int x = 0; x < s.width; x += 16) { const float v = *(const float *)(base + y * stride + x * 4); mn = std::min<double>(mn, v); mx = std::max<double>(mx, v); sum += v; ++count; }
			IOSurfaceUnlock(s.depth_surface[slot], kIOSurfaceLockReadOnly, nullptr);
			reshade::log::message(reshade::log::level::info, "Bridge: depth sample min %.5f max %.5f mean %.5f.", mn, mx, sum / std::max(count, 1u));
		}
		return true;
	}

	/// Pipelined flush: ReShade works on a frame two flushes after the game finished it, and the GPU never waits for the CPU or the other way round.
	///   flush n:  copy the game's frame n into slot n%3 and put a fence behind it
	///             frame n-1 (its fence has long passed) is handed to ReShade's GPU queue -- submitted, not awaited
	///             frame n-2 (processed by now) is blitted into the back buffer that is about to be shown
	/// Costs two frames of input latency, saves the wait for the GPU in every frame. Returns true when the back buffer now holds a processed frame.
	bool pipelined_step(CGLContextObj ctx, ContextState &s, bool multisampled)
	{
		if (s.ring_surface[0] == nullptr && !setup_ring(ctx, s)) { reshade::log::message(reshade::log::level::error, "Bridge: could not set up the pipeline."); s.failed = true; return false; }
		const uint64_t n = s.ring_n++;
		const int cur = (int)(n % 3);
		blit(0, s.orig_fbo, s.width, s.height, false);   // the game's own frame, restored after the swap
		if (multisampled) { blit(0, s.resolve_fbo, s.width, s.height, false); blit(s.resolve_fbo, s.ring_fbo[cur], s.width, s.height, true); }
		else blit(0, s.ring_fbo[cur], s.width, s.height);
		s.depth_valid[cur] = macshade_bridge_pipeline_uses_depth() && convert_depth(s, cur);
		fence_insert(s, cur);
		if (n >= 1)
		{
			const int prev = (int)((n - 1) % 3);
			fence_wait(s, prev);
			macshade_bridge_pipeline_submit(prev, s.depth_valid[prev]);
		}
		if (n < 2) return false;
		const int old = (int)((n - 2) % 3);
		macshade_bridge_pipeline_wait(old);
		if (multisampled) { blit(s.ring_fbo[old], s.resolve_fbo, s.width, s.height, true); blit(s.resolve_fbo, 0, s.width, s.height, false); }
		else blit(s.ring_fbo[old], 0, s.width, s.height);
		return true;
	}

	// MACSHADE_BRIDGE_STATS=1: average milliseconds per stage, logged every 300 frames
	struct Stats { double pre = 0, wait = 0, rs = 0, post = 0, flush = 0, interval = 0; unsigned n = 0; std::chrono::steady_clock::time_point last{}; };
	Stats s_stats;
	static const bool s_stats_on = std::getenv("MACSHADE_BRIDGE_STATS") != nullptr;
	using Clock = std::chrono::steady_clock;
	inline double ms(Clock::time_point a, Clock::time_point b) { return std::chrono::duration<double, std::milli>(b - a).count(); }

	void process_frame(CGLContextObj ctx)
	{
		static const bool no_vsync = std::getenv("MACSHADE_NO_VSYNC") != nullptr;   // benchmarking only
		if (no_vsync && ctx) { GLint zero = 0; CGLSetParameter(ctx, kCGLCPSwapInterval, &zero); }
		s_restore_fbo = 0;
		static unsigned s_calls = 0;
		if (++s_calls == 1 || s_calls % 600 == 0) reshade::log::message(reshade::log::level::info, "Bridge: frame hook call #%u (ctx %p).", s_calls, ctx);
		if (t_in_flush || !bridge_enabled() || ctx == nullptr) return;
		if (s_active_context != nullptr && s_active_context != ctx) return;

		ContextState &s = s_contexts[ctx];
		if (s.failed) return;

		const auto t0 = Clock::now();
			@autoreleasepool
		{
			// backing size in pixels of the drawable: CGL first, then the NSView of the context, finally the viewport
			GLint size[2] = {};
			CGLGetParameter(ctx, kCGLCPSurfaceBackingSize, size);
			if (size[0] <= 0 || size[1] <= 0)
			{
				NSOpenGLContext *current = [NSOpenGLContext currentContext];
				if (NSView *view = current.view)
				{
					const NSRect backing = [view convertRectToBacking:view.bounds];
					size[0] = (GLint)backing.size.width; size[1] = (GLint)backing.size.height;
				}
			}
			if (size[0] <= 0 || size[1] <= 0)
			{
				GLint viewport[4] = {}; glGetIntegerv(GL_VIEWPORT, viewport); size[0] = viewport[2]; size[1] = viewport[3];
			}
			if (s.frame == 11) reshade::log::message(reshade::log::level::info, "Bridge: context %p draws %dx%d pixels.", ctx, size[0], size[1]);
			if (size[0] <= 0 || size[1] <= 0) return;

			// Leave the first frames alone: games create and resize windows and contexts while starting up
			if (++s.frame < 10) return;

			if (size[0] != s.width || size[1] != s.height)
			{
				macshade_bridge_reset();
				if (!setup(ctx, s, size[0], size[1])) { s.failed = true; release(s); reshade::log::message(reshade::log::level::error, "Bridge: could not set up the OpenGL side."); return; }
				s_active_context = ctx;
			}

			{ bool fps_only = false; if (macshade_bridge_is_idle(&fps_only)) { if (s.ring_n != 0) { macshade_bridge_pipeline_drain(); s.ring_n = 0; } if (fps_only) draw_fps_counter(ctx, s); return; } }   // nothing to show (apart from the FPS counter): leave the game's frame untouched
			// save the GL state the blits touch
			GLint read_fbo, draw_fbo, read_buffer, draw_buffer;
			GLboolean mask[4], scissor = glIsEnabled(GL_SCISSOR_TEST), srgb = glIsEnabled(GL_FRAMEBUFFER_SRGB), blend = glIsEnabled(GL_BLEND);
			glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo);
			glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo);
			glGetIntegerv(GL_READ_BUFFER, &read_buffer);
			glGetIntegerv(GL_DRAW_BUFFER0, &draw_buffer);
			glGetBooleanv(GL_COLOR_WRITEMASK, mask);
			glDisable(GL_SCISSOR_TEST); glDisable(GL_FRAMEBUFFER_SRGB); glDisable(GL_BLEND);
			glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

			while (glGetError() != GL_NO_ERROR) {}
			// does the default framebuffer have multiple samples? (then it can only be resolved 1:1, so flip in a second step)
			glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
			GLint sample_buffers = 0;
			glGetIntegerv(GL_SAMPLE_BUFFERS, &sample_buffers);
			Clock::time_point t_pre, t1, t_rs0, t2;
			bool processed = false;
			if (pipeline_enabled())
			{
				t_pre = t1 = t_rs0 = Clock::now();
				processed = pipelined_step(ctx, s, sample_buffers > 0);
				t2 = Clock::now();
			}
			else
			{
			blit(0, s.orig_fbo, s.width, s.height, false);   // keep the game's own frame: the back buffer must look untouched after the swap
			if (sample_buffers > 0) { blit(0, s.resolve_fbo, s.width, s.height, false); blit(s.resolve_fbo, s.fbo, s.width, s.height, true); }
			else blit(0, s.fbo, s.width, s.height);   // game frame -> IOSurface (flipped, so that row 0 is the top row)
			t_pre = Clock::now();
				{ static const bool flush_only = std::getenv("MACSHADE_GL_FLUSH_ONLY") != nullptr; if (flush_only) glFlush(); else glFinish(); }
				t1 = Clock::now();
			if (s.frame == 30) dump_surface(s.surface, "frame_in");
			t_rs0 = Clock::now();
				processed = macshade_bridge_process(s.width, s.height, (__bridge void *)s.layer, s.surface);
			t2 = Clock::now();
				if (s.frame == 30) dump_surface(s.surface, "frame_out");
			if (processed) { if (sample_buffers > 0) { blit(s.fbo, s.resolve_fbo, s.width, s.height, true); blit(s.resolve_fbo, 0, s.width, s.height, false); } else blit(s.fbo, 0, s.width, s.height); } // result -> screen
			else s.failed = true;
			}

			glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo);
			glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_fbo);
			glReadBuffer(read_buffer);
			GLenum buf = (GLenum)draw_buffer; glDrawBuffers(1, &buf);
			glColorMask(mask[0], mask[1], mask[2], mask[3]);
			if (scissor) glEnable(GL_SCISSOR_TEST);
			if (srgb) glEnable(GL_FRAMEBUFFER_SRGB);
			if (blend) glEnable(GL_BLEND);
			if (s_stats_on)
				{
					glFlush();
					const auto t3 = Clock::now();
					s_stats.pre += ms(t0, t_pre); s_stats.wait += ms(t_pre, t1); s_stats.rs += ms(t_rs0, t2); s_stats.post += ms(t2, t3);
				}
				if (processed) { s_restore_fbo = s.orig_fbo; s_restore_w = s.width; s_restore_h = s.height; }
		}
	}

	/// After the swap, put the game's own (unprocessed) frame back into the new back buffer, so games that do not redraw everything every frame never see ReShade's output.
	void restore_back_buffer(CGLContextObj ctx)
	{
		if (s_restore_fbo == 0) return;
		GLint read_fbo, draw_fbo, read_buffer, draw_buffer;
		GLboolean mask[4], scissor = glIsEnabled(GL_SCISSOR_TEST), srgb = glIsEnabled(GL_FRAMEBUFFER_SRGB), blend = glIsEnabled(GL_BLEND);
		glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read_fbo); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw_fbo);
		glGetIntegerv(GL_READ_BUFFER, &read_buffer); glGetIntegerv(GL_DRAW_BUFFER0, &draw_buffer); glGetBooleanv(GL_COLOR_WRITEMASK, mask);
		glDisable(GL_SCISSOR_TEST); glDisable(GL_FRAMEBUFFER_SRGB); glDisable(GL_BLEND); glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
		blit(s_restore_fbo, 0, s_restore_w, s_restore_h, false);
		glBindFramebuffer(GL_READ_FRAMEBUFFER, read_fbo); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw_fbo); glReadBuffer(read_buffer);
		GLenum buf = (GLenum)draw_buffer; glDrawBuffers(1, &buf); glColorMask(mask[0], mask[1], mask[2], mask[3]);
		if (scissor) glEnable(GL_SCISSOR_TEST); if (srgb) glEnable(GL_FRAMEBUFFER_SRGB); if (blend) glEnable(GL_BLEND);
		s_restore_fbo = 0;
	}

	/// MACSHADE_BRIDGE_DUMP=<dir>: writes frame 30 (as read from the game, and after ReShade) as PNG files, to see what the bridge sees.
	void dump_surface(IOSurfaceRef surface, const char *name)
	{
		const char *dir = std::getenv("MACSHADE_BRIDGE_DUMP");
		if (!dir) return;
		IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr);
		CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
		CGContextRef c = CGBitmapContextCreate(IOSurfaceGetBaseAddress(surface), IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), 8, IOSurfaceGetBytesPerRow(surface), cs, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
		if (CGImageRef image = CGBitmapContextCreateImage(c))
		{
			NSString *path = [NSString stringWithFormat:@"%s/%s.png", dir, name];
			CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
			CGImageDestinationAddImage(d, image, nullptr); CGImageDestinationFinalize(d); CFRelease(d); CGImageRelease(image);
		}
		CGContextRelease(c); CGColorSpaceRelease(cs);
		IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
	}

	void note_flush(Clock::time_point flush_start)
	{
		if (!s_stats_on) return;
		const auto now = Clock::now();
		s_stats.flush += ms(flush_start, now);
		if (s_stats.last.time_since_epoch().count() != 0) s_stats.interval += ms(s_stats.last, now);
		s_stats.last = now;
		if (++s_stats.n == 300)
		{
			const double n = 300;
			reshade::log::message(reshade::log::level::info, "Bridge stats (ms/frame): frame interval %.2f (%.0f fps) | copy-in %.2f, glFinish wait %.2f, ReShade %.2f, copy-out %.2f | swap+restore %.2f", s_stats.interval / n, 1000.0 * n / s_stats.interval, s_stats.pre / n, s_stats.wait / n, s_stats.rs / n, s_stats.post / n, s_stats.flush / n);
			s_stats = Stats{};
		}
	}

	CGLError my_CGLFlushDrawable(CGLContextObj ctx)
	{
		if (t_in_flush) return CGLFlushDrawable(ctx);   // called from inside flushBuffer: already handled by the outer hook
		macshade_frame_limit();
		process_frame(ctx);
		t_in_flush = true;
		const auto tf = Clock::now();
		const CGLError result = CGLFlushDrawable(ctx);
		t_in_flush = false;
		restore_back_buffer(ctx);
		note_flush(tf);
		return result;
	}
	INTERPOSE(my_CGLFlushDrawable, CGLFlushDrawable);

	// AppKit applications (SDL, GLFW) present through -[NSOpenGLContext flushBuffer], whose internal CGLFlushDrawable call cannot be interposed
	void (*s_original_flush_buffer)(id, SEL) = nullptr;
	void hooked_flush_buffer(id self, SEL cmd)
	{
		macshade_frame_limit();
		process_frame([static_cast<NSOpenGLContext *>(self) CGLContextObj]);
		t_in_flush = true;
		const auto tf = Clock::now();
		s_original_flush_buffer(self, cmd);
		t_in_flush = false;
		restore_back_buffer([static_cast<NSOpenGLContext *>(self) CGLContextObj]);
		note_flush(tf);
	}
	__attribute__((constructor)) void install_flush_hook()
	{
		Method method = class_getInstanceMethod([NSOpenGLContext class], @selector(flushBuffer));
		if (method == nullptr) return;
		s_original_flush_buffer = reinterpret_cast<void (*)(id, SEL)>(method_getImplementation(method));
		method_setImplementation(method, reinterpret_cast<IMP>(&hooked_flush_buffer));
	}
}
