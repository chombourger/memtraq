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

#define GOOD_MARKER 0x600DBEEF
#define BAD_MARKER  0xBAADBEEF
#define ALIGN(x,a) (((x)+(a)-1UL)&~((a)-1UL))
#define INTERNAL_HEAP_SIZE (1024 * 512)

#define TRACE_CLASS_DEFAULT LMM
#include "internal.h"
#include <stdio.h>

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

static void
check_next_block (clist_t *block) {
   clist_t *next;

   TRACE3 (("called with block=%p", block));

   next = (clist_t*) ((char*) block + block->size + sizeof (clist_t));
   TRACE4 ((
      "%p(%u) => %p(%u) / %p",
      block, block->size, next, next->size, ((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE
   ));

   if ((void*) (next) < (void*) (((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE)) {
      if (next->marker == BAD_MARKER) {
         block->size += next->size + sizeof (clist_t);
         CLIST_REMOVE (next);
         TRACE4 (("block %p was also free! size changed to %u", next, block->size));
      }
      else if (next->marker == GOOD_MARKER) {
         TRACE4 (("block %p is in use!", next));
      }
   }

   TRACE3 (("exiting"));
}

void*
lmm_alloc (size_t s) {
   clist_t* it;

   TRACE3 (("called with s=%u", s));

   s = ALIGN (s, sizeof (clist_t));
   it = CLIST_HEAD (&bss.list);
   while (!CLIST_END (&bss.list, it)) {

      if (it->marker != BAD_MARKER) {
         TRACE1 (("invalid marker in block %p (%08x)", it, it->marker));
      }
      TRACE4 (("free region %p %u", it, it->size));

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

         TRACE4 ((
            "need %u, returning %p-%p (head=%p, chunk size was %u, %u will be left)",
            s, (it + 1), (char*) (it + 1) + s - 1, it, chunk, left
         ));

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

            TRACE4 (("%u bytes left, setup free block at %p", left, it));
         }
         else {

            /* keep the size of the allocated block slightly larger than the
             * amount requested since we do not have enough left to setup a
             * new free block. */
            TRACE4 (("keeping size of block %p to %u since only %u left", it, chunk, left));
         }

         TRACE3 (("exiting with result=%p", result));
         return result;
      }
      it = CLIST_NEXT (it);
   }

   TRACE3 (("exiting with result=0"));
   return 0;
}

void
lmm_free (void *p) {
   clist_t *it;

   TRACE3 (("called with p=%p", p));

   it = (clist_t*) p;
   it --;
   it->marker = BAD_MARKER;
   CLIST_ADDTAIL (&bss.list, it, it->size);

   TRACE4 (("chunk size=%u, head=%p", it->size, it));
   TRACE3 (("exiting"));
}

int
lmm_valid (void *p) {
   int result;

   TRACE3 (("called with p=%p", p));

   result = ((p >= (void*) (&bss.region.bss)) && 
             (p < (void*) (((char*) &bss.region.bss) + INTERNAL_HEAP_SIZE)));

   TRACE3 (("exiting with result=%d", result)); 
   return result;
}

