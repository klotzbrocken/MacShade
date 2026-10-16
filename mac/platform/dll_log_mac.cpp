// macOS replacement for dll_log.cpp (POSIX file + optional stderr echo).
#include "dll_log.hpp"
#include <cstdarg>
#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <pthread.h>
#include <sys/time.h>
#include <unistd.h>

static int s_log_fd = -1;

bool reshade::log::open_log_file(const std::filesystem::path &path, std::error_code &ec)
{
	if (s_log_fd >= 0) ::close(s_log_fd);
	s_log_fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (s_log_fd >= 0) { ec.clear(); return true; }
	ec.assign(errno, std::system_category());
	return false;
}

void reshade::log::message(level level, const char *format, ...)
{
	static constexpr char level_names[][6] = { "ERROR", "WARN ", "INFO ", "DEBUG" };
	if (static_cast<size_t>(level) == 0) level = level::error;
	if (static_cast<size_t>(level) > std::size(level_names)) level = level::debug;

	timeval tv; gettimeofday(&tv, nullptr);
	std::tm tm; localtime_r(&tv.tv_sec, &tm);
	uint64_t tid = 0; pthread_threadid_np(nullptr, &tid);

	std::string line(256, '\0');
	const int meta = std::snprintf(line.data(), line.size(), "%02d:%02d:%02d:%03d [%5llu] | %.5s | ",
		tm.tm_hour, tm.tm_min, tm.tm_sec, static_cast<int>(tv.tv_usec / 1000), static_cast<unsigned long long>(tid), level_names[static_cast<size_t>(level) - 1]);

	va_list args; va_start(args, format);
	const int content = std::vsnprintf(line.data() + meta, line.size() + 1 - meta, format, args);
	va_end(args);
	const bool more = static_cast<size_t>(meta) + static_cast<size_t>(content) > line.size();
	line.resize(static_cast<size_t>(meta) + static_cast<size_t>(content));
	if (more) { va_start(args, format); std::vsnprintf(line.data() + meta, line.size() + 1 - meta, format, args); va_end(args); }
	line += '\n';

	if (s_log_fd >= 0) (void)::write(s_log_fd, line.data(), line.size());
	static const bool echo = std::getenv("MACSHADE_LOG_STDERR") != nullptr;
	if (echo) (void)::write(2, line.data(), line.size());
}
