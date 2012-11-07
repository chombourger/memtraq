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

#define TRACE_CLASS_DEFAULT MEMTRAQ
#include "internal.h"

#include <assert.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include <netinet/in.h>

#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>

typedef enum {
   false = 0,
   true = 1
} bool;

typedef enum {
   INIT = 0,
   MALLOC = 1,
   FREE = 2,
   REALLOC = 3,
   TAG = 4
} ev_t;

/** Boolean for checking whether memtraq has initialized itself. */
static bool initialized = false;

/** Boolean for memory tracking enabled/disabled (defaults to true). */
static bool enabled = false;

/** Boolean for backtrace to be emitted for free() (defaults to false). */
static bool backtrace_free = false;

/** Serial number for tags created with memtraq_tag(). */
static unsigned int tag_serial = 0;

/** Lock for serializing memory requests. */
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;

/** TLS to detect recursion in malloc/free/realloc operations. */
static pthread_key_t nested_level_key;

/** File to log transactions to (set on initialization from the MEMTRAQ_LOG
  * environment variable). */
static FILE *logf;

static int sock = -1;
static struct sockaddr_in sa;
static struct sockaddr_in ra;

extern void *__libc_malloc  (size_t);
extern void  __libc_free    (void *);
extern void *__libc_realloc (void *, size_t);

#define DEFAULT_DST_PORT 6001
#define DEFAULT_SRC_PORT 8000

static char log_buffer [1024];

static char *
log_ptr (char *buffer, void *ptr) {

   memcpy (buffer, &ptr, sizeof (ptr));
   buffer += sizeof (ptr);
   return buffer;
}

static char *
log_u32 (char *buffer, unsigned int v) {

   memcpy (buffer, &v, sizeof (v));
   buffer += sizeof (v);
   return buffer;
}

static char *
log_u64 (char *buffer, unsigned long long v) {

   memcpy (buffer, &v, sizeof (v));
   buffer += sizeof (v);
   return buffer;
}

static char *
log_str (char *buffer, const char *str) {

   size_t sz;

   sz = strlen (str);
   memcpy (buffer, str, sz);
   buffer += sz;

   return buffer;
}

static char *
log_event (char *buffer, ev_t event) {

   struct timeval tv;
   pthread_t self;
   unsigned long long ts;
   int r;

   /* Compute timestamp */
   gettimeofday (&tv, 0);
   ts = (tv.tv_sec * 1000000ULL) + (unsigned long long) tv.tv_usec;

   self = pthread_self ();

   buffer = log_u32 (buffer, event);
   buffer = log_u64 (buffer, ts);
   buffer = log_u32 (buffer, self);

   return buffer;
}

static void
log_write (char *buffer) {

   unsigned int sz;

   sz = buffer - log_buffer;
   log_u32 (log_buffer, sz);

   if (logf != NULL) {
      fwrite (log_buffer, sz, 1, logf);
   }

   if (sock >= 0) {
      sendto (sock, log_buffer, sz, 0, (struct sockaddr *) &ra, sizeof (ra));
   }
}

static bool
do_init (void) {
   FILE *f;
   const char *fn;
   const char *backtrace_free_value;
   const char *tgt_value;
   bool result = true;

   /* Create TLS and set level to 1. */
   (void) pthread_key_create (&nested_level_key, NULL);
   pthread_setspecific (nested_level_key, (void *) 1);

   /* Initialize tracing. */
   trace_init ();

   fn = getenv ("MEMTRAQ_LOG");
   if (fn != 0) {
      f = fopen (fn, "w");
      if (f != 0) {
         logf = f;
      }
      else {
         fprintf (stderr, "Failed to open '%s' for writing!\n", fn);
      }
   }

   /* Setup sender address. */
   memset (&sa, 0, sizeof (struct sockaddr_in));
   sa.sin_family = AF_INET;
   sa.sin_addr.s_addr = htonl (INADDR_ANY);
   sa.sin_port = htons (DEFAULT_SRC_PORT);

   tgt_value = getenv ("MEMTRAQ_TARGET");
   if (tgt_value != 0) {
      sock = socket (PF_INET, SOCK_DGRAM, 0);
      if (sock >= 0) {
         int r = bind (sock, (struct sockaddr *) &sa, sizeof (struct sockaddr_in));
         if (r < 0) {
            close (sock);
            sock = -1;
         }
      }
      /* Setup receiver address. */
      memset (&ra, 0, sizeof(struct sockaddr_in));
      ra.sin_family = AF_INET;
      ra.sin_addr.s_addr = inet_addr (tgt_value);
      ra.sin_port = htons (DEFAULT_DST_PORT);
   }

   /* Check whether to backtrace() calls to free(). */
   backtrace_free_value = getenv ("MEMTRAQ_BACKTRACE_FREE");
   if (backtrace_free_value != 0) {
      if (strcmp (backtrace_free_value, "0") == 0) {
         backtrace_free = false;
      }
      else {
         backtrace_free = true;
      }
   }

   TRACE3 (("exiting with result=%d", result));
   return result;
}

static bool
check_initialized (void) {
   const char *enabled_value;
   bool result;

   if (initialized == false) {
      initialized = do_init ();
      if (initialized == true) {
         char *buffer;

         pthread_mutex_lock (&log_lock);

         /* memtraq is initialized, check whether to enable logging. */
         enabled_value = getenv ("MEMTRAQ_ENABLED");
         if (enabled_value != 0) {
            if (strcmp (enabled_value, "0") != 0) {
               enabled = true;
            }
         }
         else {
            enabled = true;
         }

         buffer = log_buffer + 4;
         buffer = log_event (buffer, INIT);
         buffer = log_u32 (buffer, enabled);
         log_write (buffer);

         pthread_mutex_unlock (&log_lock);
      }
   }
   result = initialized;

   return result;
}

/**
  * Make the calling thread enter a memory operation. Increment the
  * nested level so that memtraq does not record inner operations.
  *
  * @return the current nesting level for the calling thread.
  *
  */
static unsigned int
enter (void) {

   unsigned int level;

   if (initialized == true) {
      level = (unsigned int) pthread_getspecific (nested_level_key);
      level ++;
      pthread_setspecific (nested_level_key, (void *) level);
   }
   else {
      level = 2;
   }

   return level;
}

/**
  * Make the calling thread leave a memory operation. Decrement the
  * nested level so that memtraq knows when the calling thread is
  * no longer within a memory transaction.
  *
  */
static void
leave (void) {

   unsigned int level;

   if (initialized == true) {
      level = (unsigned int) pthread_getspecific (nested_level_key);
      assert (level > 0);
      level --;
      pthread_setspecific (nested_level_key, (void *) level);
   }
}

void *
do_malloc (size_t s, int skip) {

   unsigned int nested_level;
   void* result;

   TRACE3 (("called with s=%u, skip=%d", s, skip));

   /* Get nesting level, if a memory allocation is already in
    * progress, get the requested memory from the internal
    * pool. This is required as some operations such as backtrace()
    * use malloc() themselves. */
   nested_level = enter ();
   if (nested_level > 1) {
      result = lmm_alloc (s);
   }
   else {

      if (check_initialized ()) {

         result = __libc_malloc (s);

         /* Check if logging is enabled. */
         pthread_mutex_lock (&log_lock);
         if (enabled) {
            int   i,n;
            char *buffer;
            void *bt [MAX_BT];

            /* Get backtrace */
            pthread_mutex_unlock (&log_lock);
            n = backtrace (bt, MAX_BT);
            pthread_mutex_lock (&log_lock);

            /* Log operation and backtrace. */
            buffer = log_buffer + 4;
            buffer = log_event (buffer, MALLOC);
            buffer = log_u32 (buffer, s);
            buffer = log_ptr (buffer, result);
            for (i = (skip + 1); i < n; i++) {
               buffer = log_ptr (buffer, bt [i]);
            }
            log_write (buffer);
         }
         pthread_mutex_unlock (&log_lock);
      }
      else {
         result = 0;
      }
   }

   leave ();
   TRACE3 (("exiting with result=%p", result));
   return result;
}

void
do_free (void *p, int skip) {

   unsigned int nested_level;

   /* Do not bother doing anything if called with a null pointer! */
   if (p == 0) {
      return;
   }

   TRACE3 (("called with p=%p, skip=%d", p, skip));

   nested_level = enter ();
   if (lmm_valid (p)) {
      lmm_free (p);
   }
   else {
      if (check_initialized ()) {

         __libc_free (p);

         pthread_mutex_lock (&log_lock);
         if (enabled) {
            int   i,n;
            char *buffer;
            void *bt [MAX_BT];

            /* Get backtrace */
            if (backtrace_free == true) {
               pthread_mutex_unlock (&log_lock);
               n = backtrace (bt, MAX_BT);
               pthread_mutex_lock (&log_lock);
            }

            /* Log operation and backtrace. */
            buffer = log_buffer + 4;
            buffer = log_event (buffer, FREE);
            buffer = log_ptr (buffer, p);

            if (backtrace_free == true) {
               for (i = (skip + 1); i < n; i++) {
                  buffer = log_ptr (buffer, bt [i]);
               }
            }

            log_write (buffer);
         }
         pthread_mutex_unlock (&log_lock);
      }
   }

   leave ();
   TRACE3 (("exit"));
}

void *
do_realloc (void *p, size_t s, int skip) {

   unsigned int nested_level;
   void *result;

   if (lmm_valid (p)) {
      fprintf (logf, "realloc(%p,%u) not supported by internal alloctor!\n", p, s);
      return 0;
   }

   TRACE3 (("called with p=%p, s=%u, skip=%d", p, s, skip));

   nested_level = enter ();
   if (check_initialized () == true) {

      result = __libc_realloc (p, s);

      pthread_mutex_lock (&log_lock);
      if (enabled) {
         int   i,n;
         char *buffer;
         void *bt [MAX_BT];

         /* Get backtrace */
         pthread_mutex_unlock (&log_lock);
         n = backtrace (bt, MAX_BT);
         pthread_mutex_lock (&log_lock);

         /* Log operation and backtrace. */
         buffer = log_buffer + 4;
         buffer = log_event (buffer, REALLOC);
         buffer = log_ptr (buffer, p);
         buffer = log_u32 (buffer, s);
         buffer = log_ptr (buffer, result);
         for (i = (skip + 1); i < n; i++) {
            buffer = log_ptr (buffer, bt [i]);
         }
         log_write (buffer);
      }
      pthread_mutex_unlock (&log_lock);
   }
   else {
      result = 0;
   }

   leave ();
   TRACE3 (("exiting with result=%p", result));
   return result;
}

void
memtraq_enable (void) {
   pthread_mutex_lock (&log_lock);
   enabled = true;
   pthread_mutex_unlock (&log_lock);
}

void
memtraq_disable (void) {
   pthread_mutex_lock (&log_lock);
   enabled = false;
   if (logf != 0) {
      fflush (logf);
   }
   pthread_mutex_unlock (&log_lock);
}

void
memtraq_tag (const char *name) {

   char *buffer;
   unsigned int nested_level;

   nested_level = enter ();
   if (check_initialized ()) {

      pthread_mutex_lock (&log_lock);
      if (enabled) {
         tag_serial ++;

         /* Insert tag into log. */
         buffer = log_buffer + 4;
         buffer = log_event (buffer, TAG);
         buffer = log_str (buffer, name);
         buffer = log_u32 (buffer, tag_serial);
         log_write (buffer);
      }
      pthread_mutex_unlock (&log_lock);
   }

   leave ();
}

