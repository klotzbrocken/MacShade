// macOS implementation of ReShade's input manager (keyboard, mouse, cursor handling, gamepad).
//
// Windows ReShade hooks the message queue (GetMessage/PeekMessage, raw input). Here we swizzle -[NSApplication sendEvent:],
// which every AppKit based game (SDL, GLFW, native) pumps events through, translate the events into ReShade's
// Windows-style virtual-key state, and swallow them while the overlay wants the input.
#include <bitset>
#include <fstream>
#include <string>
#include <sys/stat.h>
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "input.hpp"
#include "dll_log.hpp"
#include <algorithm>
#include <cmath>
#include <atomic>
#include <mutex>
#include <shared_mutex>
#include <unordered_map>
#include <vector>
#include <cstdlib>

#define INTERPOSE(replacement, replacee) \
	__attribute__((used)) static struct { const void *r; const void *o; } _interpose_##replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

/// Counts keyboard events; the OpenGL/Metal bridge processes a frame when it changed, even if ReShade has nothing to draw (shortcuts).
unsigned g_input_activity = 0;

/// Is `vk` one of ReShade's configured shortcuts ([INPUT] Key* in ReShade.ini)? Only those keys need the bridge to process a frame while idle; counting every key (WASD ...) would flash ReShade's own FPS counter over the bridge's.
static bool is_shortcut_key(unsigned vk)
{
	static std::string path; static bool init = false; static time_t mtime = 0; static std::bitset<256> keys;
	if (!init) { init = true; if (const char *b = std::getenv("MACSHADE_BASE")) path = std::string(b) + "/ReShade.ini"; }
	struct stat st;
	if (path.empty() || stat(path.c_str(), &st) != 0) return true;   // unknown: be safe, count it
	if (st.st_mtime != mtime)
	{
		mtime = st.st_mtime; keys.reset();
		std::ifstream in(path); std::string line; bool input = false;
		while (std::getline(in, line))
		{
			if (!line.empty() && line[0] == '[') { input = line.rfind("[INPUT]", 0) == 0; continue; }
			if (!input || line.rfind("Key", 0) != 0) continue;
			const size_t eq = line.find('='); if (eq == std::string::npos) continue;
			const int code = std::atoi(line.c_str() + eq + 1);
			if (code > 0 && code < 256) keys.set(code);
		}
		keys.set(0x24); keys.set(0x23);   // Home / End: ReShade's defaults for overlay and effect toggle
	}
	return keys.test(vk);
}

namespace
{
	std::shared_mutex s_windows_mutex;
	std::unordered_map<void *, std::weak_ptr<reshade::input>> s_windows;
	std::atomic<bool> s_block_mouse = false, s_block_keyboard = false, s_block_cursor_warping = false;

	// state of the cursor as the game wants it, so that it can be restored after the overlay closes
	std::atomic<bool> s_game_dissociated = false; // game called CGAssociateMouseAndMouseCursorPosition(false)
	int s_extra_cursor_shows = 0;
	bool s_cursor_taken_over = false;

	// macOS key code -> Windows virtual key code
	const uint8_t kKeyMap[128] = {
		/*0x00*/ 0x41, 0x53, 0x44, 0x46, 0x48, 0x47, 0x5A, 0x58, 0x43, 0x56, 0xE2, 0x42, 0x51, 0x57, 0x45, 0x52,
		/*0x10*/ 0x59, 0x54, 0x31, 0x32, 0x33, 0x34, 0x36, 0x35, 0xBB, 0x39, 0x37, 0xBD, 0x38, 0x30, 0xDD, 0x4F,
		/*0x20*/ 0x55, 0xDB, 0x49, 0x50, 0x0D, 0x4C, 0x4A, 0xDE, 0x4B, 0xBA, 0xDC, 0xBC, 0xBF, 0x4E, 0x4D, 0xBE,
		/*0x30*/ 0x09, 0x20, 0xC0, 0x08, 0x00, 0x1B, 0x5C, 0x5B, 0xA0, 0x14, 0xA4, 0xA2, 0xA1, 0xA5, 0xA3, 0x00,
		/*0x40*/ 0x80, 0x6E, 0x00, 0x6A, 0x00, 0x6B, 0x00, 0x90, 0x00, 0x00, 0x00, 0x6F, 0x0D, 0x00, 0x6D, 0x81,
		/*0x50*/ 0x82, 0x00, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x83, 0x68, 0x69, 0x00, 0x00, 0x00,
		/*0x60*/ 0x74, 0x75, 0x76, 0x72, 0x77, 0x78, 0x00, 0x7A, 0x00, 0x2C, 0x7F, 0x91, 0x00, 0x79, 0x00, 0x7B,
		/*0x70*/ 0x00, 0x13, 0x2D, 0x24, 0x21, 0x2E, 0x73, 0x23, 0x71, 0x22, 0x70, 0x25, 0x27, 0x28, 0x26, 0x00,
	};

	// Handles of surfaces that do not belong to a window of their own (see gl_bridge_mac.mm) -> the game window they stand for
	std::unordered_map<void *, void *> s_window_overrides;
	std::mutex s_window_overrides_mutex;

	NSWindow *resolve_window(void *handle)
	{
		{
			std::lock_guard<std::mutex> lock(s_window_overrides_mutex);
			if (const auto it = s_window_overrides.find(handle); it != s_window_overrides.end())
				handle = it->second;
		}
		id object = (__bridge id)handle;
		if ([object isKindOfClass:[NSWindow class]])
			return object;
		if ([object isKindOfClass:[NSView class]])
			return static_cast<NSView *>(object).window;
		if ([object isKindOfClass:[CALayer class]])
		{
			CALayer *layer = object;
			if ([layer.delegate isKindOfClass:[NSView class]])
				return static_cast<NSView *>(layer.delegate).window;
			for (NSWindow *window in NSApp.windows)
			{
				NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:window.contentView];
				while (stack.count)
				{
					NSView *view = stack.lastObject; [stack removeLastObject];
					if (view == nil) continue;
					if (view.layer == layer) return window;
					[stack addObjectsFromArray:view.subviews];
				}
			}
		}
		return nil;
	}

	/// Window client area size in pixels (matches the swapchain size on Retina displays).
	void client_size_pixels(NSWindow *window, unsigned int out[2])
	{
		const NSSize size = window.contentView.bounds.size;
		const CGFloat scale = window.backingScaleFactor;
		out[0] = static_cast<unsigned int>(std::max<CGFloat>(size.width * scale, 1));
		out[1] = static_cast<unsigned int>(std::max<CGFloat>(size.height * scale, 1));
	}

	void restore_cursor_to_game()
	{
		if (!s_cursor_taken_over) return;
		s_cursor_taken_over = false;
		for (int i = 0; i < s_extra_cursor_shows; ++i)
			CGDisplayHideCursor(kCGDirectMainDisplay);
		s_extra_cursor_shows = 0;
		if (s_game_dissociated)
			CGAssociateMouseAndMouseCursorPosition(false);
	}
	void take_over_cursor()
	{
		if (s_cursor_taken_over) return;
		s_cursor_taken_over = true;
		CGAssociateMouseAndMouseCursorPosition(true);
		s_extra_cursor_shows = 0;
		while (!CGCursorIsVisible() && s_extra_cursor_shows < 16)
		{
			CGDisplayShowCursor(kCGDirectMainDisplay);
			++s_extra_cursor_shows;
		}
	}

	// --- interposed CoreGraphics cursor functions: keep the game from fighting the overlay for the cursor ---
	CGError my_CGAssociateMouseAndMouseCursorPosition(boolean_t connected)
	{
		s_game_dissociated = !connected;
		if (s_block_cursor_warping.load()) return kCGErrorSuccess; // applied when the overlay closes
		return CGAssociateMouseAndMouseCursorPosition(connected);
	}
	CGError my_CGWarpMouseCursorPosition(CGPoint p)
	{
		if (s_block_cursor_warping.load()) return kCGErrorSuccess;
		return CGWarpMouseCursorPosition(p);
	}
	void my_CGGetLastMouseDelta(int32_t *dx, int32_t *dy)
	{
		CGGetLastMouseDelta(dx, dy);
		if (s_block_mouse.load()) { if (dx) *dx = 0; if (dy) *dy = 0; }
	}
	INTERPOSE(my_CGAssociateMouseAndMouseCursorPosition, CGAssociateMouseAndMouseCursorPosition);
	INTERPOSE(my_CGWarpMouseCursorPosition, CGWarpMouseCursorPosition);
	INTERPOSE(my_CGGetLastMouseDelta, CGGetLastMouseDelta);

	// --- -[NSApplication sendEvent:] swizzle ---
	void (*s_original_send_event)(id, SEL, NSEvent *) = nullptr;

	void hooked_send_event(id self, SEL cmd, NSEvent *event)
	{
		if (reshade::input::handle_window_message((__bridge const void *)event))
			return; // overlay consumed this event
		s_original_send_event(self, cmd, event);
	}

	__attribute__((constructor)) void install_event_hook()
	{
		if (std::getenv("MACSHADE_DISABLE_INPUT")) return;
		Method method = class_getInstanceMethod([NSApplication class], @selector(sendEvent:));
		if (method == nullptr) return;
		s_original_send_event = reinterpret_cast<void (*)(id, SEL, NSEvent *)>(method_getImplementation(method));
		method_setImplementation(method, reinterpret_cast<IMP>(&hooked_send_event));

		// Forget all key states when the application loses focus, so that no key stays "pressed" in the overlay
		[[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *) {
			std::shared_lock<std::shared_mutex> lock(s_windows_mutex);
			for (auto &entry : s_windows)
				if (auto input = entry.second.lock())
					input->reset_all_keys();
		}];
	}
}

// ---------------------------------------------------------------------------------------------------------------------
// reshade::input
// ---------------------------------------------------------------------------------------------------------------------

void reshade::input::register_window_with_raw_input(window_handle, bool, bool) {}

std::shared_ptr<reshade::input> reshade::input::register_window(window_handle window)
{
	const std::unique_lock<std::shared_mutex> lock(s_windows_mutex);

	for (auto it = s_windows.begin(); it != s_windows.end();)
		if (it->second.expired()) it = s_windows.erase(it); else ++it;

	if (const auto it = s_windows.find(window); it != s_windows.end())
		if (auto existing = it->second.lock())
			return existing;

	const auto instance = std::make_shared<input>(window);
	s_windows[window] = instance;
	log::message(log::level::info, "Registered input window %p.", window);
	return instance;
}

bool reshade::input::is_keyboard_layout_german() { return false; }

void reshade::input::reset_all_keys()
{
	const std::unique_lock<std::recursive_mutex> lock(_mutex);
	for (unsigned int i = 0; i < 256; ++i)
		if (_keys[i] & 0x80) _keys[i] = 0x08;
}

void reshade::input::max_mouse_position(unsigned int position[2]) const
{
	position[0] = position[1] = 1;
	@autoreleasepool
	{
		if (NSWindow *window = resolve_window(_window)) client_size_pixels(window, position);
	}
}

void reshade::input::next_frame()
{
	_frame_count++;

	// Backup key states from the last processed frame so that state transitions can be identified
	std::copy_n(_keys, 256, _last_keys);
	for (uint8_t &state : _keys)
		state &= ~0x08;

	_text_input.clear();
	_mouse_wheel_delta = 0;
	_last_mouse_position[0] = _mouse_position[0];
	_last_mouse_position[1] = _mouse_position[1];

	// Reset keys that were released while no event reached us (e.g. while another window had focus)
	const uint32_t now = static_cast<uint32_t>(CACurrentMediaTime() * 1000.0);
	for (unsigned int vk = 8; vk < 256; ++vk)
	{
		if ((_keys[vk] & 0x80) == 0 || (now - _keys_time[vk]) <= 5000)
			continue;
		bool still_down = false;
		for (unsigned int code = 0; code < 128; ++code)
			if (kKeyMap[code] == vk && CGEventSourceKeyState(kCGEventSourceStateCombinedSessionState, static_cast<CGKeyCode>(code)))
				still_down = true;
		if (!still_down) _keys[vk] = 0x08;
	}

	// Test hook: MACSHADE_TEST_KEYS="<frame>:<vk>[,<frame>:<vk>...]" synthesizes key presses (for automated checks)
	static const std::vector<std::pair<uint64_t, unsigned int>> test_keys = [] {
		std::vector<std::pair<uint64_t, unsigned int>> keys;
		if (const char *env = std::getenv("MACSHADE_TEST_KEYS"))
			for (const char *p = env; *p;)
			{
				char *end = nullptr; const uint64_t frame = std::strtoull(p, &end, 10);
				if (*end != ':') break;
				const unsigned int vk = static_cast<unsigned int>(std::strtoul(end + 1, &end, 0));
				keys.push_back({ frame, vk });
				p = (*end == ',') ? end + 1 : end;
			}
		return keys;
	}();
	for (const auto &[frame, vk] : test_keys)
		if (_frame_count == frame && vk < 256) { _keys[vk] = 0x88; _keys_time[vk] = now; }
		else if (_frame_count == frame + 1 && vk < 256) { _keys[vk] = 0x08; }

	// Caps lock is a toggle
	if ([NSEvent modifierFlags] & NSEventModifierFlagCapsLock) _keys[key_caps_lock] |= 0x1; else _keys[key_caps_lock] &= ~0x1;

	// Run through all forms of input blocking for all windows and establish whether any of them are blocking input
	const std::shared_lock<std::shared_mutex> lock(s_windows_mutex);
	const auto any = [](auto predicate) {
		return std::any_of(s_windows.cbegin(), s_windows.cend(), [&](const auto &entry) {
			const auto input = entry.second.lock();
			return input != nullptr && predicate(*input);
		});
	};
	s_block_mouse.store(any([](const input &i) { return i.is_blocking_mouse_input(); }));
	s_block_keyboard.store(any([](const input &i) { return i.is_blocking_keyboard_input(); }));
	s_block_cursor_warping.store(any([](const input &i) { return i.is_blocking_mouse_cursor_warping(); }));
}

void reshade::input::block_mouse_cursor_warping(bool enable)
{
	if (enable == _block_cursor_warping)
		return;
	_block_cursor_warping = enable;
	s_block_cursor_warping.store(enable);

	// Cursor calls must happen on the main thread
	dispatch_async(dispatch_get_main_queue(), ^{
		if (s_block_cursor_warping.load()) take_over_cursor(); else restore_cursor_to_game();
	});
}

bool reshade::input::is_blocking_any_mouse_input(window_handle target)
{
	if (target != nullptr)
	{
		const std::shared_lock<std::shared_mutex> lock(s_windows_mutex);
		const auto it = s_windows.find(target);
		if (it == s_windows.end()) return false;
		const auto input = it->second.lock();
		return input != nullptr && input->is_blocking_mouse_input();
	}
	return s_block_mouse.load();
}
bool reshade::input::is_blocking_any_keyboard_input(window_handle target)
{
	if (target != nullptr)
	{
		const std::shared_lock<std::shared_mutex> lock(s_windows_mutex);
		const auto it = s_windows.find(target);
		if (it == s_windows.end()) return false;
		const auto input = it->second.lock();
		return input != nullptr && input->is_blocking_keyboard_input();
	}
	return s_block_keyboard.load();
}
bool reshade::input::is_blocking_any_mouse_cursor_warping() { return s_block_cursor_warping.load(); }

bool reshade::input::handle_window_message(const void *message_data)
{
	@autoreleasepool
	{
		NSEvent *event = (__bridge NSEvent *)message_data;
		const NSEventType type = event.type;

		bool is_mouse_message = false, is_keyboard_message = false;
		switch (type)
		{
		case NSEventTypeKeyDown: case NSEventTypeKeyUp: case NSEventTypeFlagsChanged:
			is_keyboard_message = true; break;
		case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseDown: case NSEventTypeRightMouseUp:
		case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp: case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged:
		case NSEventTypeRightMouseDragged: case NSEventTypeOtherMouseDragged: case NSEventTypeScrollWheel:
			is_mouse_message = true; break;
		default:
			return false;
		}

		// Find the input object that belongs to the window this event is for (or the most active one)
		std::shared_ptr<input> target;
		{
			std::shared_lock<std::shared_mutex> lock(s_windows_mutex);
			uint64_t best_frames = 0;
			for (auto &entry : s_windows)
			{
				const auto candidate = entry.second.lock();
				if (candidate == nullptr) continue;
				NSWindow *window = resolve_window(candidate->_window);
				if (window != nil && event.window != nil && window == event.window) { target = candidate; break; }
				if (target == nullptr || candidate->_frame_count > best_frames) { target = candidate; best_frames = candidate->_frame_count; }
			}
		}
		if (target == nullptr)
			return false;

		const std::unique_lock<std::recursive_mutex> input_lock(target->_mutex);

		// Mouse position in client pixels, top-left origin
		if (NSWindow *window = resolve_window(target->_window))
		{
			// events without a window carry the location in screen coordinates
			const NSPoint location = event.window != nil ? event.locationInWindow : [window convertPointFromScreen:event.locationInWindow];
			const CGFloat scale = window.backingScaleFactor;
			const NSSize size = window.contentView.bounds.size;
			target->_mouse_position[0] = static_cast<unsigned int>(std::max<CGFloat>(location.x * scale, 0));
			target->_mouse_position[1] = static_cast<unsigned int>(std::max<CGFloat>((size.height - location.y) * scale, 0));
		}

		const uint32_t time = static_cast<uint32_t>(event.timestamp * 1000.0);
		const auto set_key = [&](unsigned int vk, bool down) {
			if (vk == 0 || vk >= 256) return;
			if (down)
			{
				target->_keys[vk] = 0x88;
				target->_keys_time[vk] = time;
				if (target->is_blocking_keyboard_input()) target->_keys[vk] |= 0x04;
			}
			else
			{
				// Do not block key up messages if the key down one was not blocked previously (so the key does not get stuck for the application)
				if (target->is_blocking_keyboard_input() && (target->_keys[vk] & 0x04) == 0) is_keyboard_message = false;
				target->_keys[vk] = 0x08;
				target->_keys_time[vk] = time;
			}
		};

		if ((type == NSEventTypeKeyDown || type == NSEventTypeKeyUp) && event.keyCode < 128 && is_shortcut_key(kKeyMap[event.keyCode])) ++g_input_activity;
		switch (type)
		{
		case NSEventTypeKeyDown:
		case NSEventTypeKeyUp:
		{
			const unsigned int vk = event.keyCode < 128 ? kKeyMap[event.keyCode] : 0;
			if (vk == 0) { is_keyboard_message = false; break; }
			set_key(vk, type == NSEventTypeKeyDown);
			if (type == NSEventTypeKeyDown)
			{
				NSString *chars = event.characters;
				const NSEventModifierFlags mods = event.modifierFlags;
				if (chars != nil && (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) == 0)
					for (NSUInteger i = 0; i < chars.length; ++i)
					{
						const unichar c = [chars characterAtIndex:i];
						if (c >= 0x20 && c != 0x7F && !(c >= 0xF700 && c <= 0xF8FF))
							target->_text_input += static_cast<wchar_t>(c);
					}
			}
			break;
		}
		case NSEventTypeFlagsChanged:
		{
			const unsigned int vk = event.keyCode < 128 ? kKeyMap[event.keyCode] : 0;
			const NSEventModifierFlags f = event.modifierFlags;
			bool down = false;
			switch (event.keyCode)
			{
			case kVK_Shift: case kVK_RightShift: down = (f & NSEventModifierFlagShift) != 0; break;
			case kVK_Control: case kVK_RightControl: down = (f & NSEventModifierFlagControl) != 0; break;
			case kVK_Option: case kVK_RightOption: down = (f & NSEventModifierFlagOption) != 0; break;
			case kVK_Command: case kVK_RightCommand: down = (f & NSEventModifierFlagCommand) != 0; break;
			case kVK_CapsLock: down = (f & NSEventModifierFlagCapsLock) != 0; break;
			default: is_keyboard_message = false; break;
			}
			if (!is_keyboard_message || vk == 0) break;
			set_key(vk, down);
			// Windows also reports the generic modifier keys; shortcuts are tested against those
			const bool any_shift = (f & NSEventModifierFlagShift) != 0, any_ctrl = (f & NSEventModifierFlagControl) != 0, any_alt = (f & NSEventModifierFlagOption) != 0;
			if (vk == 0xA0 || vk == 0xA1) set_key(0x10, any_shift);
			if (vk == 0xA2 || vk == 0xA3) set_key(0x11, any_ctrl);
			if (vk == 0xA4 || vk == 0xA5) set_key(0x12, any_alt);
			break;
		}
		case NSEventTypeLeftMouseDown: target->_keys[key_button_left] = 0x88; break;
		case NSEventTypeLeftMouseUp: target->_keys[key_button_left] = 0x08; break;
		case NSEventTypeRightMouseDown: target->_keys[key_button_right] = 0x88; break;
		case NSEventTypeRightMouseUp: target->_keys[key_button_right] = 0x08; break;
		case NSEventTypeOtherMouseDown:
		case NSEventTypeOtherMouseUp:
		{
			const unsigned int vk = event.buttonNumber == 2 ? key_button_middle : event.buttonNumber == 3 ? key_button_xbutton1 : event.buttonNumber == 4 ? key_button_xbutton2 : 0;
			if (vk != 0) target->_keys[vk] = type == NSEventTypeOtherMouseDown ? 0x88 : 0x08;
			break;
		}
		case NSEventTypeScrollWheel:
		{
			// One wheel notch is 1 on Windows; precise (trackpad) deltas are scaled down accordingly
			const CGFloat delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10.0 : event.scrollingDeltaY;
			target->_mouse_wheel_delta += static_cast<short>(std::lround(delta));
			break;
		}
		default:
			break;
		}

		return (is_mouse_message && target->is_blocking_mouse_input()) || (is_keyboard_message && target->is_blocking_keyboard_input());
	}
}

// ---------------------------------------------------------------------------------------------------------------------
// reshade::input_gamepad (GameController framework, mapped to the XInput layout ReShade expects)
// ---------------------------------------------------------------------------------------------------------------------

std::shared_ptr<reshade::input_gamepad> reshade::input_gamepad::load()
{
	static std::shared_ptr<input_gamepad> instance = std::make_shared<input_gamepad>();
	return instance;
}

void reshade::input_gamepad::next_frame()
{
	_last_buttons = _buttons;
	@autoreleasepool
	{
		GCExtendedGamepad *pad = nil;
		for (GCController *controller in [GCController controllers])
			if (controller.extendedGamepad != nil) { pad = controller.extendedGamepad; break; }
		if (pad == nil)
		{
			_buttons = 0; _last_packet_num = 0;
			_left_trigger = _right_trigger = _left_thumb_axis_x = _left_thumb_axis_y = _right_thumb_axis_x = _right_thumb_axis_y = 0.0f;
			return;
		}
		uint16_t b = 0;
		const auto set = [&](bool pressed, uint16_t flag) { if (pressed) b |= flag; };
		set(pad.buttonA.pressed, button_a); set(pad.buttonB.pressed, button_b); set(pad.buttonX.pressed, button_x); set(pad.buttonY.pressed, button_y);
		set(pad.dpad.up.pressed, button_dpad_up); set(pad.dpad.down.pressed, button_dpad_down);
		set(pad.dpad.left.pressed, button_dpad_left); set(pad.dpad.right.pressed, button_dpad_right);
		set(pad.buttonOptions.pressed, button_back); set(pad.buttonMenu.pressed, button_start);
		set(pad.leftThumbstickButton.pressed, button_left_thumb); set(pad.rightThumbstickButton.pressed, button_right_thumb);
		set(pad.leftShoulder.pressed, button_left_shoulder); set(pad.rightShoulder.pressed, button_right_shoulder);
		_buttons = b;
		_left_trigger = pad.leftTrigger.value; _right_trigger = pad.rightTrigger.value;
		_left_thumb_axis_x = pad.leftThumbstick.xAxis.value; _left_thumb_axis_y = pad.leftThumbstick.yAxis.value;
		_right_thumb_axis_x = pad.rightThumbstick.xAxis.value; _right_thumb_axis_y = pad.rightThumbstick.yAxis.value;
		_last_packet_num++;
		if (_last_packet_num == 0) _last_packet_num = 1;
	}
}

void macshade_set_window_override(void *surface_handle, void *window)
{
	std::lock_guard<std::mutex> lock(s_window_overrides_mutex);
	s_window_overrides[surface_handle] = window;
}
