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

#ifndef MEMTRAQ_H
#define MEMTRAQ_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __MEMTRAQ__
#ifdef HAVE_VISIBILITY
#define MEMTRAQ_EXPORT __attribute__((visibility("default")))
#else
#define MEMTRAQ_EXPORT
#endif
#else
#define MEMTRAQ_EXPORT __attribute__((weak))
#endif

extern void
memtraq_enable (void) MEMTRAQ_EXPORT;

extern void
memtraq_disable (void) MEMTRAQ_EXPORT;

extern void
memtraq_tag (const char* name) MEMTRAQ_EXPORT;

#define MEMTRAQ_ENABLE() do { \
   if (memtraq_enable) {      \
      memtraq_enable ();      \
   }                          \
} while (0)

#define MEMTRAQ_DISABLE() do { \
   if (memtraq_disable) {      \
      memtraq_disable ();      \
   }                           \
} while (0)

#define MEMTRAQ_TAG(tag) do { \
   if (memtraq_tag) {         \
      memtraq_tag (tag);      \
   }                          \
} while (0)

#ifdef __cplusplus
}
#endif /* __cplusplus */
#endif /* MEMTRAQ_H */

