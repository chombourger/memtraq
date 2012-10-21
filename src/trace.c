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

#include "internal.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>

static pthread_mutex_t trace_lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
static char trace_buf [256];

void trace_start (const char *file, int line, const char *func) {
   pthread_mutex_lock (&trace_lock);
   trace ("# %s (%s:%d) [thread %p]\n# ", func, file, line, pthread_self ());
}

void trace_end () {
   fputc ('\n', stderr);
   pthread_mutex_unlock (&trace_lock);
}

void trace (const char* fmt, ...) {
   va_list args;

   va_start (args, fmt);
   mt_vsnprintf (trace_buf, sizeof (trace_buf), fmt, args);
   trace_buf [sizeof (trace_buf) - 1] = '\0';
   va_end (args);

   fputs (trace_buf, stderr);
}

