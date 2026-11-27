/* CPU hog: N busy threads for S seconds, a stand-in for a windowed client's render and worker threads. */
#include <pthread.h>
#include <stdlib.h>
#include <time.h>
static void *spin(void *a) { volatile unsigned long x = 0; time_t end = time(0) + (long)a; while (time(0) < end) x++; return 0; }
int main(int argc, char **argv) {
	int n = argc > 1 ? atoi(argv[1]) : 4; long s = argc > 2 ? atol(argv[2]) : 60;
	pthread_t t[256]; if (n > 256) n = 256;
	for (int i = 0; i < n; i++) pthread_create(&t[i], 0, spin, (void *)s);
	for (int i = 0; i < n; i++) pthread_join(t[i], 0);
	return 0;
}
