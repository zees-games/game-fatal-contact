/* LD_PRELOAD shim: sleeps wake only on a coarse timer boundary, like Windows' default 15.625 ms timer tick.
 * Sleep(n) there returns at the first tick boundary at or after the request, so Sleep(15) takes 15.6 to 31 ms.
 * COARSE_US (default 15625) is the tick length. Only nanosleep and clock_nanosleep are rounded (Godot's
 * OS::delay_usec on Linux is nanosleep); threads blocked on futexes are not, which Windows would also round. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdlib.h>
#include <time.h>

static long long coarse_ns(void) {
	const char *e = getenv("COARSE_US");
	long long us = e ? atoll(e) : 15625;
	return (us > 0 ? us : 15625) * 1000LL;
}

static long long now_ns(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec * 1000000000LL + t.tv_nsec;
}

static struct timespec rounded(const struct timespec *req) {
	long long step = coarse_ns();
	long long want = now_ns() + req->tv_sec * 1000000000LL + req->tv_nsec;
	long long wake = (want + step - 1) / step * step;
	long long d = wake - now_ns();
	if (d < 0) d = 0;
	struct timespec r = { d / 1000000000LL, d % 1000000000LL };
	return r;
}

int nanosleep(const struct timespec *req, struct timespec *rem) {
	static int (*real)(const struct timespec *, struct timespec *);
	if (!real) real = dlsym(RTLD_NEXT, "nanosleep");
	struct timespec r = rounded(req);
	return real(&r, rem);
}

int clock_nanosleep(clockid_t clock, int flags, const struct timespec *req, struct timespec *rem) {
	static int (*real)(clockid_t, int, const struct timespec *, struct timespec *);
	if (!real) real = dlsym(RTLD_NEXT, "clock_nanosleep");
	if (flags & TIMER_ABSTIME) {
		long long step = coarse_ns();
		long long t = req->tv_sec * 1000000000LL + req->tv_nsec;
		t = (t + step - 1) / step * step;
		struct timespec a = { t / 1000000000LL, t % 1000000000LL };
		return real(clock, flags, &a, rem);
	}
	struct timespec r = rounded(req);
	return real(clock, flags, &r, rem);
}
