AM_CPPFLAGS  = -I $(srcdir)/../include
AM_CPPFLAGS += -D __MEMTRAQ__
AM_CFLAGS    = @CFLAG_VISIBILITY@
lib_LTLIBRARIES = libmemtraq.la
libmemtraq_la_SOURCES = memtraq.c cxxsupport.cpp internal.h
libmemtraq_la_LIBADD = -lpthread -ldl
libmemtraq_la_LDFLAGS = -version-info 0:0:0
