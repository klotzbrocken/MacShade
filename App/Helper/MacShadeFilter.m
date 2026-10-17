// Starter of the screen filter mode: loads libmacshade.dylib (path in MACSHADE_LIB, default: ../Resources next to this program) and runs its filter.
// Usage: MacShadeFilter --pid <game pid> [--overlay <key>:<mods>] [--effects <key>:<mods>]   (environment: MACSHADE_BASE, MACSHADE_MOLTENVK)
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <stdio.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		NSString *lib = [NSString stringWithUTF8String:getenv("MACSHADE_LIB") ?: ""];
		if (lib.length == 0) lib = [[NSBundle.mainBundle.executablePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../Resources/libmacshade.dylib"];
		void *handle = dlopen(lib.UTF8String, RTLD_NOW | RTLD_LOCAL);
		if (handle == NULL) { fprintf(stderr, "cannot load %s: %s\n", lib.UTF8String, dlerror()); return 1; }
		int (*run)(int, char **) = (int (*)(int, char **))dlsym(handle, "macshade_filter_main");
		if (run == NULL) { fprintf(stderr, "macshade_filter_main not found\n"); return 1; }
		return run(argc, argv);
	}
}
