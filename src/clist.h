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

#ifndef MEMTRAQ_CLIST_H
#define MEMTRAQ_CLIST_H

typedef struct clist {
   struct clist* next;
   struct clist* prev;
   unsigned int size;
   unsigned int marker;
} clist_t;

# define CLIST_HEAD(l)  (((clist_t*)(l))->next)
# define CLIST_END(l,n) (((clist_t*)(l)) == ((clist_t*)(n)))
# define CLIST_NEXT(n)  (((clist_t*)(n))->next)

# define CLIST_ADDTAIL(l,n,s) do { \
   clist_t* __n = (clist_t*) (n);  \
   clist_t* __t = (l)->prev;       \
   unsigned int __s = (s);         \
                                   \
   __n->next = (l);                \
   __n->prev = __t;                \
   __n->size = __s;                \
                                   \
   (l)->prev = __n;                \
   __t->next = __n;                \
} while (0)

# define CLIST_REMOVE(n) do {     \
   clist_t* __n = (clist_t*) (n); \
   clist_t* __t = __n->prev;      \
                                  \
   __n = __n->next;               \
   __t->next = __n;               \
   __n->prev = __t;               \
} while (0)

#endif /* MEMTRAQ_CLIST_H */

