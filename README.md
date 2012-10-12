memtraq
=======

This is memtraq, a Memory Tracking Tool for Embedded Linux Systems.

Why a new tool while valgrind is just excellent?!

Well, some embedded devices do not have the horse power or memory required by
valgrind hence a more lightweight solution was needed. Also many memory leak
detection tools assume or require the program to exit.

Basically the idea behind memtraq is to log the various memory transactions
happening in the system. The created log file can then be processed offline
(i.e., on the host) to check blocks that were allocated but not freed.

The offline memtraq script can also take care of all the backtrace decoding
assuming target binaries are available with debug information. If your
target system was built with bitbake, the staging directory can be used to
that effect.

memtraq is a shared library to be loaded into your application process via
the LD\_PRELOAD mechanism. memtraq provides a small API exported via symbols
declared as weak. This allows your code to be built and shipped with the
memtraq API calls with no (or little overhead).

Functions made available to applications are:

1) MEMTRAQ\_ENABLE()

(Re-)enable logging of memory transactions.

2) MEMTRAQ\_DISABLE()

Disable logging of memory transactions.

3) MEMTRAQ\_TAG(const char \*tagName)

Put a tag into the memtraq log. Tags can be used by the offline memtraq
script to check allocations between two tags.

Build
-----

./configure
make
make install

Usage
-----

LD\_PRELOAD=libmemtraq.so <application>

memtraq behavior can be controlled via environment variables:

1) MEMTRAQ\_ENABLED

If set to 0, memtraq will not log memory transactions until your application
explicitly calls MEMTRAQ\_ENABLE().

2) MEMTRAQ\_LOG

Can be set to redirect the memtraq output to a file. By default, the memtraq
output otherwise goes to stdout!

3) MEMTRAQ\_RESOLVE

If set to 0, memtraq will not try to resolve addresses to symbol names. This
is recommended for slow devices as backtrace\_symbols() is costly operation.

