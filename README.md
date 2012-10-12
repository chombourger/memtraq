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

./configure --prefix=/usr --host=arm-unknown-linux-gnu
make
make install DESTDIR=$PWD/memtraq-arm-install

Usage
-----

LD\_PRELOAD=libmemtraq.so.0.0 <application>

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

Processing memtraq log files
----------------------------

The log file created on target by memtraq can be processed on the host (development)
machine with memtraq.pl script:

./memtraq.pl memtraq.log

The script will go through all the transactions found in the provided log file and
keep a list of blocks still allocated. After parsing all the log entries, the non
freed blocks are dumped as follow:

1: block of 160 bytes not freed
        address  : 0xecda70
        timestamp: 1297835547165449
        thread   : unknown (720887808)
        callstack:
                0x8afd64
                0xc28084
                0x4c3c5084
2: block of 108 bytes not freed
        address  : 0xe91080
        timestamp: 1297835423882082
        thread   : unknown (720887808)
        callstack:
                0x545268
                0xc28084
                0x4c3c5084
3: block of 50 bytes not freed
        address  : 0xec3088
        timestamp: 1297835535973513
        thread   : unknown (720887808)
        callstack:
                0x88e24c
                0xc28084
                0x4c3c5084

where:

   - address is the location of the allocated block
   - timestamp is when it was allocated (memtraq uses gettimeofday())
   - thread is the name (if supported) and id of the thread that allocated
   - callstack is the backtrace of the allocation call

So now that we know that our application leaks, we may want to know where
allocations were made!

The above log was created by memtraq having MEMTRAQ\_RESOLVE set to 0 hence
no calls to backtrace\_symbols() were made to decode the addresses.

To decode the addresses offline we need:

   1) the /proc/pid/maps file from the target where pid is the process ID of
      your application (so you somehow need to copy that file while your
      system is running).

   2) unstripped binaries (your embedded system is most likely running stripped
      versions of the libraries and executables).

You can then run memtraq.pl again:

./memtraq.pl --paths /home/john/oe/tmp/staging/armv6-linux:/home/john/myapp \\
   --map myapp.maps myapp.log

where:

   - the paths option is used to provide a column separated list of paths
     where to get unstripped binaries from

   - the map option is used to provide memtraq.pl with the /proc/pid/maps
     file from the target so that memtraq.pl can find out where shared
     libraries have been loaded
 
