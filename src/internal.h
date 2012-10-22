/*
 * memtraq - Memory Tracking for Embedded Linux Systems
 * Copyright (C) 2012 Cedric Hombourger <chombourger@gmail.com>
 * License: GNU GPL (GNU General Public License, see COPYING-GPL)
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 */

#ifndef MEMTRAQ_INTERNAL_H
#define MEMTRAQ_INTERNAL_H

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif

#define _GNU_SOURCE 1

#include <memtraq.h>
#include <stddef.h>

#define  TRACE_ENV_PREFIX "MEMTRAQ_TRACE_"
#define  TRACE_TRC_FILE   "memtraq.trc"
#include "trace.h"

#include "clist.h"
#include "lmm.h"

#define MAX_BT 100
#define DECODE_ADDRESSES 1

#ifdef __cplusplus
extern "C" {
#endif

extern int debug;

extern int
mt_vsnprintf (char *str, size_t size, const char *format, va_list args);

extern void*
malloc (size_t s) __attribute__((visibility("default")));

extern void
free (void* ptr) __attribute__((visibility("default")));

extern void*
realloc (void* ptr, size_t newsize) __attribute__((visibility("default")));

extern void*
calloc (size_t n, size_t size) __attribute__((visibility("default")));

void*
do_malloc (size_t s, int skip);

void
do_free (void* p, int skip);

void*
do_realloc (void* p, size_t s, int skip);

#ifdef __cplusplus
}
#endif

#endif /* MEMTRAQ_INTERNAL_H */

