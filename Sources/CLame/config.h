/* Hand-written replacement for the config.h LAME's ./configure would
 * generate. Ata builds LAME with SwiftPM on arm64 macOS only, so the answers
 * are fixed: a modern C library, IEEE floats, no decoder, no x86 assembly. */
#ifndef ATA_LAME_CONFIG_H
#define ATA_LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STRCHR 1
#define HAVE_MEMCPY 1

#define SIZEOF_SHORT 2
#define SIZEOF_UNSIGNED_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_UNSIGNED_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_UNSIGNED_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_UNSIGNED_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8

typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

/* Encoder only: Ata decodes with AVFoundation. */
#undef HAVE_MPGLIB
#undef DECODE_ON_THE_FLY

/* Upstream LAME 3.100 trips these on a modern clang; the code is taken
 * unchanged, so silence them here rather than patch it. Every LAME source
 * includes this file first, so the pragmas cover the whole file. */
#pragma clang diagnostic ignored "-Wshift-negative-value"
#pragma clang diagnostic ignored "-Wabsolute-value"
#pragma clang diagnostic ignored "-Wtautological-pointer-compare"

#define PACKAGE "lame"
#define VERSION "3.100"

#endif
