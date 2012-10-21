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

#ifndef MEMTRAQ_TRACE_H
#define MEMTRAQ_TRACE_H

#include <pthread.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

extern int trace_level;
extern void trace_start (const char *file, int line, const char *func);
extern void trace (const char *fmt, ...);
extern void trace_end ();

#define TRACE(x) do {						\
   if (trace_level) {							\
      trace_start (__FILE__, __LINE__, __PRETTY_FUNCTION__);	\
      trace x;							\
      trace_end ();						\
   }								\
} while (0)

#ifdef __cplusplus
}
#endif

#endif /* MEMTRAQ_TRACE_H */

