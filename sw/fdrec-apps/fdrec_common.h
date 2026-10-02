/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * fdrec_common.h -- small helpers shared by fdrec and fdverify.
 */

#ifndef FDREC_COMMON_H
#define FDREC_COMMON_H

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

extern const char *prog_name;

static inline void err_msg(const char *fmt, ...)
	__attribute__((format(printf, 1, 2)));
static inline void err_msg(const char *fmt, ...)
{
	va_list ap;

	fprintf(stderr, "%s: ", prog_name);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

/* like perror() with a formatted prefix; keeps errno */
static inline void perr(const char *fmt, ...)
	__attribute__((format(printf, 1, 2)));
static inline void perr(const char *fmt, ...)
{
	int e = errno;
	va_list ap;

	fprintf(stderr, "%s: ", prog_name);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, ": %s\n", strerror(e));
	errno = e;
}

static inline int die_usage(const char *fmt, ...)
	__attribute__((format(printf, 1, 2)));
static inline int die_usage(const char *fmt, ...)
{
	va_list ap;

	fprintf(stderr, "%s: ", prog_name);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, " (see --help)\n");
	return -1;
}

/*
 * "123", "8M", "10G", "1.5G", "500MB", "0x1000".
 * K/M/G/T (and KiB/MiB/...) are powers of 1024; KB/MB/GB/TB powers of 1000.
 */
static inline int parse_size(const char *s, uint64_t *out)
{
	char *end;
	double v;
	uint64_t mul = 1;

	if (!s || !*s)
		return -1;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
		unsigned long long x;

		errno = 0;
		x = strtoull(s, &end, 16);
		if (errno || *end)
			return -1;
		*out = x;
		return 0;
	}
	errno = 0;
	v = strtod(s, &end);
	if (errno || end == s || v < 0)
		return -1;
	if (*end) {
		char u = (char)(*end & ~0x20);   /* upper case */
		const char *rest = end + 1;
		int p;

		switch (u) {
		case 'K': p = 1; break;
		case 'M': p = 2; break;
		case 'G': p = 3; break;
		case 'T': p = 4; break;
		default: return -1;
		}
		if (!*rest || !strcasecmp(rest, "i") || !strcasecmp(rest, "iB")) {
			while (p--)
				mul *= 1024;
		} else if (!strcasecmp(rest, "B")) {
			while (p--)
				mul *= 1000;
		} else {
			return -1;
		}
	}
	v *= (double)mul;
	if (v > 1.8e19)
		return -1;
	*out = (uint64_t)(v + 0.5);
	return 0;
}

static inline int parse_double(const char *s, double *out)
{
	char *end;

	errno = 0;
	*out = strtod(s, &end);
	return (errno || end == s || *end) ? -1 : 0;
}

static inline double now_s(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

static inline uint64_t realtime_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_REALTIME, &ts);
	return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

/* HugePages_Free from /proc/meminfo (default hugepage size), 0 if unknown */
static inline unsigned long hugepages_free(void)
{
	char line[256];
	unsigned long v = 0;
	FILE *f = fopen("/proc/meminfo", "r");

	if (!f)
		return 0;
	while (fgets(line, sizeof(line), f))
		if (sscanf(line, "HugePages_Free: %lu", &v) == 1)
			break;
	fclose(f);
	return v;
}

#endif /* FDREC_COMMON_H */
