// macOS implementation of reshade::utils (platform_utils.hpp).
#import <AppKit/AppKit.h>
#include "platform_utils.hpp"
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

bool reshade::utils::open_explorer(const std::filesystem::path &path)
{
	@autoreleasepool
	{
		NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
		if (url == nil) return false;
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
		return true;
	}
}

bool reshade::utils::execute_command(const std::string &command_line, const std::filesystem::path &working_directory, bool)
{
	// Runs the command line through the shell, detached from the game
	pid_t pid = 0;
	std::string command = command_line;
	if (!working_directory.empty())
		command = "cd '" + working_directory.string() + "' && " + command_line;
	const char *argv[] = { "/bin/sh", "-c", command.c_str(), nullptr };
	return posix_spawn(&pid, "/bin/sh", nullptr, nullptr, const_cast<char *const *>(argv), environ) == 0;
}

void reshade::utils::play_sound_async(const std::filesystem::path &audio_file)
{
	@autoreleasepool
	{
		NSSound *sound = [[NSSound alloc] initWithContentsOfFile:[NSString stringWithUTF8String:audio_file.c_str()] byReference:YES];
		[sound play]; // NSSound keeps itself alive while playing
	}
}
