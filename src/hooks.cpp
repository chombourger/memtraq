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

#define TRACE_CLASS_DEFAULT HOOKS
#include "internal.h"

#include <new>
#include <string.h>

void *
malloc (size_t s) {
   void *result;

   TRACE3 (("called with s=%u", s));

   result = do_malloc (s, 1);

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void *
calloc (size_t n, size_t size) {
   void *result;

   TRACE3 (("called with n=%u, size=%u", n, size));

   size = size * n;
   result = do_malloc (size, 1);
   if (result != 0) {
      memset (result, 0, size);
   }

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void *
realloc (void* p, size_t s) {
   void *result;

   TRACE3 (("called with p=%p, s=%u", p, s));

   if (p == 0) {
      result = do_malloc (s, 1);
   }
   else if (s == 0) {
      do_free (p, 1);
      result = 0;
   }
   else {
      result = do_realloc (p, s, 1);
   }

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void
free (void* p) {

   if (p == 0) {
      return;
   }

   TRACE3 (("called with p=%p", p));

   do_free (p, 1);

   TRACE3 (("exiting"));
}

void *
operator new (size_t size) {

   void *result;
   TRACE3 (("called with size=%u", size));

   result = do_malloc (size, 1);

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void *
operator new[] (size_t size) {

   void *result;
   TRACE3 (("called with size=%u", size));

   result = do_malloc (size, 1);

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void *
operator new (std::size_t size, std::nothrow_t const&) {

   void *result;
   TRACE3 (("called with size=%u", size));

   result = do_malloc (size, 1);

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void *
operator new[] (std::size_t size, std::nothrow_t const&) {

   void *result;
   TRACE3 (("called with size=%u", size));

   result = do_malloc (size, 1);

   TRACE3 (("exiting with result=%p", result));
   return result;
}

void
operator delete (void *ptr) {

   TRACE3 (("called with ptr=%p", ptr));
   do_free (ptr, 1);
   TRACE3 (("exiting"));
}

void
operator delete[] (void *ptr) {
   TRACE3 (("called with ptr=%p", ptr));
   do_free (ptr, 1);
   TRACE3 (("exiting"));
}

void
operator delete (void *ptr, const std::nothrow_t&) {
   TRACE3 (("called with ptr=%p", ptr));
   do_free (ptr, 1);
   TRACE3 (("exiting"));
}

void
operator delete[] (void *ptr, const std::nothrow_t&) {
   TRACE3 (("called with ptr=%p", ptr));
   do_free (ptr, 1);
   TRACE3 (("exiting"));
}
 
