// Debug aid: MACSHADE_TRACE_THROW=1 prints a backtrace whenever a C++ exception is thrown from a library (e.g. libc++).
#include <cstdio>
#include <cstdlib>
#include <execinfo.h>
#include <unistd.h>

extern "C" void __cxa_throw(void *, void *, void (*)(void *));

#define INTERPOSE(replacement, replacee) \
	__attribute__((used)) static struct { const void *r; const void *o; } _interpose_##replacee \
	__attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&replacement, (const void *)(unsigned long)&replacee }

static void my_cxa_throw(void *exception, void *type, void (*dest)(void *))
{
	static const bool trace = std::getenv("MACSHADE_TRACE_THROW") != nullptr;
	if (trace)
	{
		void *frames[40]; const int n = backtrace(frames, 40);
		dprintf(2, "[macshade] C++ exception thrown:\n");
		backtrace_symbols_fd(frames, n, 2);
	}
	__cxa_throw(exception, type, dest);
}
INTERPOSE(my_cxa_throw, __cxa_throw);

// MACSHADE_CRASH_TRACE=1: print a backtrace on SIGSEGV/SIGBUS even when the game installs its own crash handler (the game's handler still runs afterwards).
#include <signal.h>
#include <dlfcn.h>
#include <string.h>

static struct sigaction s_game_actions[32];
static bool s_game_has_action[32];

static void crash_handler(int sig, siginfo_t *info, void *context)
{
	void *frames[48]; const int n = backtrace(frames, 48);
	dprintf(2, "[macshade] signal %d at address %p, backtrace:\n", sig, info ? info->si_addr : nullptr);
	backtrace_symbols_fd(frames, n, 2);
	const struct sigaction &game = s_game_actions[sig];
	if (s_game_has_action[sig] && (game.sa_flags & SA_SIGINFO) && game.sa_sigaction) game.sa_sigaction(sig, info, context);
	else if (s_game_has_action[sig] && game.sa_handler && game.sa_handler != SIG_DFL && game.sa_handler != SIG_IGN) game.sa_handler(sig);
	else { signal(sig, SIG_DFL); raise(sig); }
}

static void install_crash_handler(int sig)
{
	struct sigaction ours; memset(&ours, 0, sizeof(ours));
	ours.sa_sigaction = crash_handler; ours.sa_flags = SA_SIGINFO | SA_ONSTACK; sigemptyset(&ours.sa_mask);
	sigaction(sig, &ours, nullptr);
}

static int my_sigaction(int sig, const struct sigaction *act, struct sigaction *old)
{
	static const bool trace = std::getenv("MACSHADE_CRASH_TRACE") != nullptr;
	if (trace && (sig == SIGSEGV || sig == SIGBUS) && act != nullptr)
	{
		if (old) { if (s_game_has_action[sig]) *old = s_game_actions[sig]; else memset(old, 0, sizeof(*old)); }
		s_game_actions[sig] = *act; s_game_has_action[sig] = true;
		return 0; // keep ours installed
	}
	return sigaction(sig, act, old);
}
INTERPOSE(my_sigaction, sigaction);

__attribute__((constructor)) static void init_crash_trace()
{
	if (!std::getenv("MACSHADE_CRASH_TRACE")) return;
	install_crash_handler(SIGSEGV); install_crash_handler(SIGBUS);
}
