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

#define _GNU_SOURCE 1
#define MAX_BT 100
#define INTERNAL_HEAP_SIZE (1024 * 512)
#define DECODE_ADDRESSES 1

#define DEBUG 1

#define GOOD_MARKER 0x600DBEEF
#define BAD_MARKER  0xBAADBEEF

#include <assert.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>

#include "internal.h"

typedef enum {
   false = 0,
   true = 1
} bool;

typedef void* (*malloc_func_t) (size_t s);
static malloc_func_t old_malloc = 0;

typedef void (*free_func_t) (void* p);
static free_func_t old_free = 0;

typedef void* (*realloc_func_t) (void* p, size_t s);
static realloc_func_t old_realloc = 0;

/** Boolean for checking whether memtraq has initialized itself. */
static bool initialized = false;

/** Boolean for memory tracking enabled/disabled (defaults to true). */
static bool enabled = true;

/** Boolean for symbols to be resolved (defaults to true). */
static bool resolve = true;

/** Operation counter, incremented on every memory operation. */
static unsigned long long op_counter = 0;

/** Serial number for tags created with memtraq_tag(). */
static unsigned int tag_serial = 0;

/** Lock for serializing memory requests. */
static pthread_mutex_t lock = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;

/** Boolean indicating whether a memory operation is already in progress. */
static bool in_malloc = false;

/** From which operation index to start tracking memory operations. */
static unsigned int start = 0;

/** File to log transactions to (set on initialization from the MEMTRAQ_LOG
  * environment variable). */
static FILE* logf;

static bool debug = false;

typedef struct {
   clist_t list;
   union {
      clist_t node;
      char bss [INTERNAL_HEAP_SIZE];
   } region;
} bss_t;

static bss_t bss = {
   .list = {
      (clist_t*) (((char*) &bss) + sizeof (clist_t)),
      (clist_t*) (((char*) &bss) + sizeof (clist_t)),
      0,
      0
   },
   .region = {
      .node = {
         .prev   = (clist_t*) (&bss),
         .next   = (clist_t*) (&bss),
         .size   = sizeof (bss.region.bss) - sizeof (clist_t),
         .marker = BAD_MARKER
      }
   }
};

#define ALIGN(x,a) (((x)+(a)-1UL)&~((a)-1UL))

static void
check_next_block (clist_t* block) {
   clist_t* next;

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# check_next_block(%p)\n", block);
   }
#endif

   next = (clist_t*) ((char*) block + block->size + sizeof (clist_t));
#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# check_next_block: %p(%u) => %p(%u) / %p\n",
         block, block->size, next, next->size, ((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE);
   }
#endif
   if ((void*) (next) < (void*) (((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE)) {
      if (next->marker == BAD_MARKER) {
         block->size += next->size + sizeof (clist_t);
         CLIST_REMOVE (next);
#ifdef DEBUG
         if (debug) {
            fprintf (stderr, "# check_next_block: block %p was also free!\n"
               "# check_next_block: size changed to %u\n", next, block->size);
         }
#endif
      }
      else if (next->marker == GOOD_MARKER) {
#ifdef DEBUG
         if (debug) {
            fprintf (stderr, "# check_next_block: block %p is in use!\n", next);
         }
#endif
      }
   }
}

static void*
internal_alloc (size_t s) {
   clist_t* it;

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# internal_alloc(%u)\n", s);
   }
#endif
   s = ALIGN (s, sizeof (clist_t));

   it = CLIST_HEAD (&bss.list);
   while (!CLIST_END (&bss.list, it)) {

#ifdef DEBUG
      if (debug) {
         if (it->marker != BAD_MARKER) {
            fprintf (stderr, "# internal_alloc: invalid marker in block %p (%08x)\n",
               it, it->marker);
         }
         fprintf (stderr, "# internal_alloc: free region %p %u\n", it, it->size);
      }
#endif

      check_next_block (it);

      if (it->size >= s) {
         void* result;
         unsigned int chunk;
         unsigned int left;
         char* remain;

         chunk = it->size;
         it->marker = GOOD_MARKER;
         result = (it + 1);
         CLIST_REMOVE (it);

         left = chunk - s;

#ifdef DEBUG
         if (debug) {
            fprintf (stderr, "# internal_alloc: need %u, returning %p-%p "
               "(head=%p, chunk size was %u, %u will be left)\n",
               s, (it + 1), (char*) (it + 1) + s - 1, it, chunk, left);
         }
#endif

         if (left >= sizeof (clist_t)) {

            /* adjust size of the block found to the size that was requested. */
            it->size = s;

            /* create a new free block with the memory left from the block
             * we selected. */
            remain  = (char*) (it + 1);
            remain += s;
            it = (clist_t*) (remain);
            it->marker = BAD_MARKER;
            CLIST_ADDTAIL (&bss.list, it, left - sizeof (clist_t));

#ifdef DEBUG
            if (debug) {
               fprintf (stderr, "# internal_alloc: %u bytes left, "
                  "setup free block at %p\n", left, it);
            }
#endif
         }
         else {

            /* keep the size of the allocated block slightly larger than the
             * amount requested since we do not have enough left to setup a
             * new free block. */

#ifdef DEBUG
            if (debug) {
               fprintf (stderr, "# internal_alloc: keeping size of block %p "
                  "to %u since only %u left\n", it, chunk, left);
            }
#endif
         }

#ifdef DEBUG
         if (debug) {
            fprintf (stderr, "# internal_alloc: exit=%p\n", result);
         }
#endif

         return result;
      }
      it = CLIST_NEXT (it);
   }
#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# internal_alloc: failed to allocate %u bytes!\n", s);
   }
#endif
   return 0;
}

static void
internal_free (void* p) {
   clist_t* it;

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# internal_free(%p)\n", p);
   }
#endif

   it = (clist_t*) p;
   it --;
   it->marker = BAD_MARKER;
   CLIST_ADDTAIL (&bss.list, it, it->size);

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# internal_free: chunk size=%u, head=%p\n", it->size, it);
   }
#endif
}

static void
check_debug (void) {
   const char* debugv;

   debugv = getenv ("MEMTRAQ_DEBUG");
   if ((debugv != 0) && (strcmp (debugv, "") != 0)) {
      debug = true;
   }
}

static void
log_event (const char* event) {

   struct timeval tv;
   char name [20];
   pthread_t self;
   unsigned long long ts;
   int r;

   /* Compute timestamp */
   gettimeofday (&tv, 0);
   ts = (tv.tv_sec * 1000000ULL) + (unsigned long long) tv.tv_usec;

   /* Get thread name */
   self = pthread_self ();
#ifdef HAVE_PTHREAD_GETNAME_NP
   r = pthread_getname_np (self, name, sizeof (name));
#else
   r = -1;
#endif
   if (r != 0) strcpy (name, "unknown");

   /* Log operation and backtrace */
   fprintf (logf, "%llu;%s;%lu;%s;", ts, name, self, event);
}
 
static bool
do_init (void) {
   FILE* f;
   const char* fn;
   const char* enabled_value;
   const char* resolve_value;

   check_debug ();

   fn = getenv ("MEMTRAQ_LOG");
   if (fn != 0) {
      f = fopen (fn, "w");
      if (f != 0) {
         logf = f;
      }
      else {
         fprintf (stderr, "Failed to open '%s' for writing, memtraq will logf to stdout\n", fn);
         logf = stdout;
      }
   }
   else {
      logf = stdout;
   }

   enabled_value = getenv ("MEMTRAQ_ENABLED");
   if (enabled_value != 0) {
      if (strcmp (enabled_value, "0") == 0) {
         enabled = false;
      }
      else {
         enabled = true;
      }
   }

   resolve_value = getenv ("MEMTRAQ_RESOLVE");
   if (resolve_value != 0) {
      if (strcmp (resolve_value, "0") == 0) {
         resolve = false;
      }
      else {
         resolve = true;
      }
   }

   old_malloc = (malloc_func_t) dlsym (RTLD_NEXT, "__libc_malloc");
   old_realloc = (realloc_func_t) dlsym (RTLD_NEXT, "__libc_realloc");
   old_free = (free_func_t) dlsym (RTLD_NEXT, "__libc_free");
   old_malloc = (malloc_func_t) dlsym (RTLD_NEXT, "__libc_malloc");
   old_realloc = (realloc_func_t) dlsym (RTLD_NEXT, "__libc_realloc");
   old_free = (free_func_t) dlsym (RTLD_NEXT, "__libc_free");

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# do_init: __libc_malloc=%p\n", old_malloc);
      fprintf (stderr, "# do_init: __libc_realloc=%p\n", old_realloc);
      fprintf (stderr, "# do_init: __libc_free=%p\n", old_free);
      fprintf (stderr, "# do_init: enabled=%d\n", enabled);
      fprintf (stderr, "# do_init: resolve=%d\n", resolve);
      fprintf (stderr, "# do_init: log=%s\n", fn);
      fprintf (stderr, "# do_init: exit\n");
   }
#endif

   return (old_malloc != 0) && (old_free != 0) && (old_realloc != 0);
}

static bool
check_initialized (void) {
   bool result;

   pthread_mutex_lock (&lock);
   if (initialized == false) {
      initialized = do_init ();
      if (initialized == true) {
         fprintf (logf, "timestamp;thread-name;thread-id;event;param1;param2;param3;result;callstack\n");
         log_event ("start");
         fprintf (logf, VERSION ";%u;%d;%d\n", INTERNAL_HEAP_SIZE, enabled, resolve);
      }
   }
   result = initialized;
   pthread_mutex_unlock (&lock);

   return result;
}

static void
do_backtrace (int skip) {

   void* buffer[MAX_BT];
   int   i,n;
   bool  resolved = false;

   n = backtrace (buffer, MAX_BT);

#ifdef DECODE_ADDRESSES
   if (resolve == true) {
      char** strings;

#ifdef DEBUG
      if (debug) {
         fprintf (stderr, "# do_backtrace: calling backtrace_symbols()\n");
      }
#endif

      strings = backtrace_symbols (buffer, n);
      if (strings == 0) {
         for (i = skip; i < n; i++) {
            fprintf (logf, ";%p", buffer [i]);
         }
         resolved = true;
      }
   }
#endif /* DECODE_ADDRESSES */

   if (resolved == false) {
      for (i = skip; i < n; i++) {
         fprintf (logf, ";%p", buffer [i]);
      }
   }
}

void*
do_malloc (size_t s, int skip) {

   void* result;

   pthread_mutex_lock (&lock);
   op_counter ++;

   if (in_malloc == true) {
      result = internal_alloc (s);
      pthread_mutex_unlock (&lock);
      return result;
   }

   in_malloc = true;

   if (check_initialized () == false) {
      pthread_mutex_unlock (&lock);
      return 0;
   }

   assert (old_malloc != 0);
   result = old_malloc (s);

   if ((enabled) && (op_counter > start)) {

      /* Log operation and backtrace. */
      log_event ("malloc");
      fprintf (logf, "%u;void;%p", s, result);
      do_backtrace (skip + 2);
      fprintf (logf, "\n");
   }

   in_malloc = false;
   pthread_mutex_unlock (&lock);

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# do_malloc(%u, %d): exit=%p\n", s, skip, result);
   }
#endif

   return result;
}

void
do_free (void* p, int skip) {

   if (p == 0) {
      return;
   }

   if ((p >= (void*) (&bss.region.bss)) && 
       (p < (void*) (((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE))) {
      internal_free (p);
      return;
   }

   if (check_initialized () == false) {
      return;
   }

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# do_free (p=%p, skip=%d)\n", p, skip);
   }
#endif

   pthread_mutex_lock (&lock);
   op_counter ++;
   in_malloc = true;

   assert (old_free != 0);
   old_free (p);

   if ((enabled) && (op_counter > start)) {

      /* Log operation and backtrace. */
      log_event ("free");
      fprintf (logf, "%p;void;void", p);
      do_backtrace (skip + 2);
      fprintf (logf, "\n");
   }

   in_malloc = false;
   pthread_mutex_unlock (&lock);
}

void*
do_realloc (void* p, size_t s, int skip) {

   void* result;

   if ((p >= (void*) (&bss.region.bss)) && 
       (p < (void*) (((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE))) {
      fprintf (logf, "realloc(%p,%u) not supported by internal alloctor (%p-%p)!\n",
         p, s, &bss.region.bss, (((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE));
      return 0;
   }

   if (check_initialized () == false) {
      return 0;
   }

   pthread_mutex_lock (&lock);
   op_counter ++;
   in_malloc = true;

   assert (old_realloc != 0);
   result = old_realloc (p, s);

   if ((enabled) && (op_counter > start)) {

      /* Log event and backtrace. */
      log_event ("realloc");
      fprintf (logf, "%p;%u;%p", p, s, result);
      do_backtrace (skip + 2);
      fprintf (logf, "\n");
   }

   in_malloc = false;
   pthread_mutex_unlock (&lock);

#ifdef DEBUG
   if (debug) {
      fprintf (stderr, "# do_realloc (p=%p, s=%u, skip=%d): exit=%p\n", p, s, skip, result);
   }
#endif

   return result;
}

void
memtraq_enable (void) {
   pthread_mutex_lock (&lock);
   enabled = true;
   pthread_mutex_unlock (&lock);
}

void
memtraq_disable (void) {
   pthread_mutex_lock (&lock);
   enabled = false;
   pthread_mutex_unlock (&lock);
}

void
memtraq_tag (const char* name) {

   if (check_initialized () == false) {
      return;
   }

   pthread_mutex_lock (&lock);
   in_malloc = true;

   if (enabled) {
      tag_serial ++;

      /* Log operation and backtrace. */
      log_event ("tag");
      fprintf (logf, "%s;%u;void", name, tag_serial);
      do_backtrace (2);
      fprintf (logf, "\n");
   }

   in_malloc = false;
   pthread_mutex_unlock (&lock);
}

void*
malloc (size_t s) {
   return do_malloc (s, 1);
}

void*
calloc (size_t n, size_t size) {
   void* result;

   size = size * n;
   result = do_malloc (size, 1);
   if (result != 0) {
      memset (result, 0, size);
   }
   return result;
}

void*
realloc (void* p, size_t s) {
   if (p == 0) {
      return do_malloc (s, 1);
   }
   else if (s == 0) {
      do_free (p, 1);
      return 0;
   }
   else {
      return do_realloc (p, s, 1);
   }
}

void
free (void* p) {
   do_free (p, 1);
}

