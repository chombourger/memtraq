#!/usr/bin/perl
# memtraq - Memory Tracking for Embedded Linux Systems
# Copyright (C) 2012 Cedric Hombourger <chombourger@gmail.com>
# License: GNU GPL (GNU General Public License, see COPYING-GPL)
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

use strict;
use warnings;

use Cwd 'abs_path';
use File::Basename;
use FileHandle;
use Getopt::Long;
use IPC::Open2;
use POSIX;

my $EV_START   = 0;
my $EV_MALLOC  = 1;
my $EV_FREE    = 2;
my $EV_REALLOC = 3;
my $EV_TAG     = 4;

my %opts;

# Current timestamp
my $ts = 0;
# Lowest timestamp
my $ts_min;
# Greatest timestamp
my $ts_max;

my $heap_max = 0;

my %usage_by_objects;
my %usage_by_threads;

# Graph output file (--graph)
my $graph = '';
# Number of columns for graphs 
my $graph_cols = 80;
# Number of rows for graphs 
my $graph_rows = 40;

my $before = '';
my $after = '';
my $gdb = 'gdb';
my $map = '';
my $node_fraction = 0.20;
my $objdump = 'objdump';
my $paths = '';
my $show_all = 0;
my $show_grouped = 0;
my $show_unknown = 0;
my $do_debug = 0;
my $live_report = '';

GetOptions(\%opts,
   'before|b=s' => \$before,
   'after|a=s' => \$after,
   'debug|d' => \$do_debug,
   'gdb-tool=s' => \$gdb,
   'graph|g=s' => \$graph,
   'live-report=s' => \$live_report,
   'map|m=s' => \$map,
   'node-fraction|n=f' => \$node_fraction,
   'objdump-tool=s' => \$objdump,
   'paths|p=s' => \$paths,
   'show-all|A' => \$show_all,
   'show-grouped|G' => \$show_grouped,
   'show-unknown|U' => \$show_unknown,
);

sub debug {
   my $msg = $_[0];
   if ($do_debug) {
      print STDERR "DEBUG " . $msg . "\n";
   }
}

my $file=$ARGV[0];
open (LOG, '<', $file) or die("Could not open " . $file . "!");

my %maps;
my %objects;
my %hsyms;
my $exec = '';

# Load provided map file into the 'maps' array
if ($map ne '') {
   open (MAP, $map) or die("Could not open map " . $map . "!");
   debug ("reading map file '$map'...");
   foreach my $line (<MAP>)  {
      $line =~ s/\n//;
      # Executable regions only
      if ($line =~ / r-xp /) {

         # Extract start address
         my $start =  $line;
         $start    =~ s/-[0-9a-f]+ .*//;
         $line     =~ s/^[0-9a-f]+-//;

         # Extract end address
         my $end =  $line;
         $end    =~ s/ .*//;
         $line   =~ s/^[0-9a-f]+ +//;

         # Extract path (eat everything up to the leading /)
         $line =~ s/[^\/]+//;

         if ($line) {
            $maps{$start}{'file'}    = $line;
            $maps{$start}{'start'}   = hex ($start);
            $maps{$start}{'end'}     = hex ($end);
            $objects{$line}{'start'} = hex($start);
            debug "added map entry '$line' $start-$end";
         }
      }
   }
   close (MAP);
}

sub object_from_addr {
   my $a = $_[0];
   my $result = "unknown";

   if ($a =~ /^[0-9a-f]+$/) {
      $a = hex ($a);
      foreach my $m (keys %maps) {
         my $start = $maps{$m}{'start'};
         my $end   = $maps{$m}{'end'};
         if (($start <= $a) && ($a <= $end)) {
            $result = $maps{$m}{'file'};
            return $result;
         }
      }
   }
   return $result;
}

sub decode {
   my $a = $_[0];
   my $loc = $a;
   my %result;

   # Default values
   $result{'object'} = "unknown";
   $result{'loc'}    = $a;
   $result{'dir'}    = '';
   $result{'file'}   = '';
   $result{'line'}   = '';
   $result{'method'} = '';

   if ($a =~ /^[0-9a-f]+$/) {
      if (defined ($hsyms{$a})) {
         $result{'object'} = $hsyms{$a}{'object'};
         $result{'loc'}    = $hsyms{$a}{'loc'};
         $result{'dir'}    = $hsyms{$a}{'dir'};
         $result{'file'}   = $hsyms{$a}{'file'};
         $result{'line'}   = $hsyms{$a}{'line'};
         $result{'method'} = $hsyms{$a}{'method'};
      }
   }
   return %result;
}

sub max_label_2($$)
{
    my ($szB, $szB_scaled) = @_;

    # For the label, if $szB is 999B or below, we print it as an integer.
    # Otherwise, we print it as a float with 5 characters (including the '.').
    # Examples (for bytes):
    #       1 -->     1  B
    #     999 -->   999  B
    #    1000 --> 0.977 KB
    #    1024 --> 1.000 KB
    #   10240 --> 10.00 KB
    #  102400 --> 100.0 KB
    # 1024000 --> 0.977 MB
    # 1048576 --> 1.000 MB
    #
    if    ($szB < 1000)        { return sprintf("%5d",   $szB);        }
    elsif ($szB_scaled < 10)   { return sprintf("%5.3f", $szB_scaled); }
    elsif ($szB_scaled < 100)  { return sprintf("%5.2f", $szB_scaled); }
    else                       { return sprintf("%5.1f", $szB_scaled); }
}

# Work out the units for the max value, measured in bytes.
sub B_max_label($)
{
    my ($szB) = @_;

    # We repeat until the number is less than 1000, but we divide by 1024 on
    # each scaling.
    my $szB_scaled = $szB;
    my $unit = "B";
    # Nb: 'K' or 'k' are acceptable as the "binary kilo" (1024) prefix.
    # (Strictly speaking, should use "KiB" (kibibyte), "MiB" (mebibyte), etc,
    # but they're not in common use.)
    if ($szB_scaled >= 1000) { $unit = "KB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "MB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "GB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "TB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "PB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "EB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "ZB"; $szB_scaled /= 1024; }
    if ($szB_scaled >= 1000) { $unit = "YB"; $szB_scaled /= 1024; }

    return (max_label_2($szB, $szB_scaled), $unit);
}

# Work out the units for the max value, measured in ms/s/h.
sub t_max_label($)
{
    my ($szB) = @_;

    # We scale from microseconds to seconds to hours.
    my $szB_scaled = $szB;
    my $unit = "us";
    if ($szB_scaled >= 1000) { $unit = "ms"; $szB_scaled /= 1000; }
    if ($szB_scaled >= 1000) { $unit = "s"; $szB_scaled /= 1000; }
    if ($szB_scaled >= 3600) { $unit = "h"; $szB_scaled /= 3600; }

    return (max_label_2($szB, $szB_scaled), $unit);
}

sub is_alloc_wrapper {

   my $name = $_[0];

   return (($name eq 'WTF::fastMalloc(size_t)')
        || ($name eq 'WTF::fastZeroedMalloc(size_t)')
        || ($name eq 'WTF::tryFastMalloc(size_t)')
        || ($name eq 'WTF::tryFastRealloc(void*, size_t)'));
}

# provide call info on who called malloc (or alike)
sub get_caller_info {

   my $btstr = $_[0];

   my @bt = split (/\;/, $btstr);
   my $i  = 0;

   foreach my $a (@bt) {
      if ($i > 0) {
         my %result = decode ($a);
         if (defined $bt[$i]) {
            if ((!is_alloc_wrapper ($result{'method'})) || (!defined ($bt[$i+1]))) {
               return %result;
            }
         }
      }
      $i = $i + 1;
   }
   return undef;
}

my %chunks;
my $total = 0;
my $allocs = 0;
my $frees = 0;
my %unknown_frees;
my $reallocs = 0;
my $log = 1;
my %hotspots;
my $lines = 0;
my $current_serial = 0;
my $logs_lost = 0;

my @heap_history;

if ($after ne '') {
   print "# tracking on hold till tag '" . $after . "' (--after)...\n";
   $log = 0;
}

binmode (LOG);
while (read (LOG, my $data, 28)) {

   my ($sz, $serial, $ev, $ts, $thread_id) = unpack 'IQIQI', $data;
   $sz = $sz - 4 - 8 - 4 - 8 - 4;

   debug "LOG HEADER sz=$sz, serial=$serial, ev=$ev, ts=$ts, thread_id=$thread_id";

   # Initialize ts_min if this is the first log entry
   $lines = $lines + 1;
   if ($lines eq 1) {
      $ts_min = $ts;
   }

   if ($current_serial != 0) {
      $current_serial = $current_serial + 1;
      if ($serial > $current_serial) {
         debug "received log #$serial, $current_serial expected!\n";
         $logs_lost = $logs_lost + 1;
      }
   }
   else {
      $current_serial = $serial;
   }

   # As memtraq logs are ordered chronogically, ts_max is the current ts
   $ts_max = $ts;

   # START event
   if ($ev == $EV_START) {
      read (LOG, $data, 4);
   }

   # TAG event
   if ($ev == $EV_TAG) {

      # Extract tag name
      read (LOG, $data, $sz);
      my ($name, $serial) = unpack 'ZI', $sz;

      debug "LOG TAG name=$name, serial=$serial";

      if ($before ne '') {
         if ($before =~ /:\d+$/) {
            my $before_name = $before;
            $before_name =~ s/:\d+$//;
            my $before_serial = $before;
            $before_serial =~ s/[^:]+://;
            if (($name eq $before_name) && ($serial == $before_serial)) {
               print "# reached tag '" . $before . "' (--before), no longer tracking...\n";
               $log = 0;
            }
         }
         else {
            if ($name eq $before) {
               print "# reached tag '" . $before . "' (--before), no longer tracking...\n";
               $log = 0;
            }
         }
      }
      if ($after ne '') {
         if ($after =~ /:\d+$/) {
            my $after_name = $after;
            $after_name =~ s/:\d+$//;
            my $after_serial = $after;
            $after_serial =~ s/[^:]+://;
            if (($name eq $after_name) && ($serial == $after_serial)) {
               print "# reached tag '" . $after . "' (--after), tracking resumed...\n";
               $log = 1;
            }
         }
         else {
            if ($name eq $after) {
               print "# reached tag '" . $after . "' (--after), tracking resumed...\n";
               $log = 1;
            }
         }
      }
   }

   # MALLOC event
   if ($ev == $EV_MALLOC) {

      read (LOG, $data, 8);
      my ($size, $ptr) = unpack 'II', $data;
      $sz = $sz - 4 - 4;

      debug "LOG MALLOC size=$size, ptr=$ptr";

      my $bt = "";
      while ($sz > 0) {
         read (LOG, $data, 4);
         my ($ra) = unpack 'I', $data;
         $sz = $sz - 4;
         $bt = $bt . sprintf ("%x;", $ra);
      }
      $bt =~ s/;$//;

      if ($log != 0) {
         $chunks{$ptr}{'backtrace'} = $bt;
         $chunks{$ptr}{'size'} = $size;
         $chunks{$ptr}{'thread_id'} = $thread_id;
         $chunks{$ptr}{'timestamp'} = $ts;

         if (!defined ($hotspots{$bt}{'size'})) {
            $hotspots{$bt}{'allocs'} = 0;
            $hotspots{$bt}{'frees'}  = 0;
            $hotspots{$bt}{'size'}   = 0;
         }
         $hotspots{$bt}{'allocs'} = $hotspots{$bt}{'allocs'} + 1;
         $hotspots{$bt}{'size'}   = $hotspots{$bt}{'size'} + $size;

         $total = $total + $size;
         $allocs ++;
      }
   }

   # FREE event
   if ($ev == $EV_FREE) {

      read (LOG, $data, 4);
      my ($ptr) = unpack 'I', $data;
      $sz = $sz - 4;

      debug "LOG FREE ptr=$ptr";

      my $bt = "";
      while ($sz > 0) {
         read (LOG, $data, 4);
         my ($ra) = unpack 'I', $data;
         $sz = $sz - 4;
         $bt = $bt . sprintf ("%x;", $ra);
      }
      $bt =~ s/;$//;

      if ($log != 0) {
         if (defined $chunks{$ptr}) {
            my $size = $chunks{$ptr}{'size'};
            $total = $total - $size;

            my $bt = $chunks{$ptr}{'backtrace'};
            $hotspots{$bt}{'frees'} = $hotspots{$bt}{'frees'} + 1;
            $hotspots{$bt}{'size'}  = $hotspots{$bt}{'size'} - $size;
         }
         else {
            my $count = 1;
            if (defined $unknown_frees{$bt}) {
               $count = $count + $unknown_frees{$bt} 
            }
            $unknown_frees{$bt} = $count;
         }

         $frees ++;
         delete $chunks{$ptr};
      }
   }

   # REALLOC event
   if ($ev == $EV_REALLOC) {

      read (LOG, $data, 12);
      my ($oldptr, $size, $newptr) = unpack 'III', $data;
      $sz = $sz - 4 - 4 - 4;

      debug "LOG REALLOC oldptr=$oldptr, $size=$size, newptr=$newptr";

      my $bt = "";
      while ($sz > 0) {
         read (LOG, $data, 4);
         my ($ra) = unpack 'I', $data;
         $sz = $sz - 4;
         $bt = $bt . sprintf ("%x;", $ra);
      }
      $bt =~ s/;$//;

      if ($log != 0) {
         if (defined $chunks{$oldptr}) {
            my $old_size = $chunks{$oldptr}{'size'};
            my $old_bt   = $chunks{$oldptr}{'backtrace'};
            $total = $total - $old_size;
            $hotspots{$old_bt}{'size'} = $hotspots{$old_bt}{'size'} - $old_size;
            $hotspots{$old_bt}{'frees'} = $hotspots{$old_bt}{'frees'} + 1;
         }

         $chunks{$newptr}{'backtrace'} = $bt;
         $chunks{$newptr}{'size'} = $size;
         $chunks{$newptr}{'thread_id'} = $thread_id;
         $chunks{$newptr}{'timestamp'} = $ts;

         if (!defined ($hotspots{$bt}{'size'})) {
            $hotspots{$bt}{'allocs'} = 0;
            $hotspots{$bt}{'frees'}  = 0;
            $hotspots{$bt}{'size'}   = 0;
         }
         $hotspots{$bt}{'allocs'} = $hotspots{$bt}{'allocs'} + 1;
         $hotspots{$bt}{'size'}   = $hotspots{$bt}{'size'} + $size;

         $total = $total + $size;
         $reallocs ++;
      }
   }

   if ($total > $heap_max) {
      $heap_max = $total;
   }

   $heap_history[$lines]{'timestamp'} = $ts;
   $heap_history[$lines]{'heap'} = $total;
}
close(LOG);

print "\n";
print "Summary:\n";
print "--------\n";
print "\n";

print $total . " bytes (" . keys(%chunks) . " blocks) in use\n";
print $allocs . " allocs, " . $frees . " frees, " . $reallocs . " reallocs\n";
if (scalar (keys %unknown_frees) > 0) {
   print "Note: " . scalar(keys %unknown_frees) . " frees for unknown blocks!\n";
}
print "$logs_lost log entries lost!\n";
print "\n";

my $time_total = $ts_max - $ts_min;
my $time_incr = $time_total / $graph_cols;
my $heap_incr = $heap_max / $graph_rows;

my @graph;
my $x;
my $y;

my ($y_label, $y_unit) = B_max_label ($heap_max);
my ($x_label, $x_unit) = t_max_label ($ts_max - $ts_min);

# Initialize (erase) graph
for ($x = 1; $x <= $graph_cols; $x++) {
   for ($y = 1; $y <= $graph_rows; $y++) {
      $graph[$x][$y] = ' ';
   }
}

# Fill heap history graph
my $samples = scalar (@heap_history);
for (my $i = 1; $i < $samples; $i ++) {
   my $ts = $heap_history[$i]{'timestamp'};
   my $heap = $heap_history[$i]{'heap'};
   $ts = $ts - $ts_min;
   $x = $ts / $time_incr;
   $y = $heap / $heap_incr;
   for (my $j = 1; $j <= $y; $j ++) {
      $graph[$x][$j] = ':';
   }
}
undef @heap_history;

# Print X and Y axis
$graph[0][0] = '+';                                            # axes join point
for ($x = 1; $x <= $graph_cols; $x++) { $graph[$x][0] = '-'; } # X-axis
for ($y = 1; $y <= $graph_rows; $y++) { $graph[0][$y] = '|'; } # Y-axis
$graph[$graph_cols][0] = '>';                                  # X-axis arrow
$graph[0][$graph_rows] = '^';                                  # Y-axis arrow 

printf("    %2s\n", $y_unit);
for ($y = $graph_rows; $y >= 0; $y--) {
   if ($graph_rows == $y) {          # top row
      print($y_label);
    } elsif (0 == $y) {              # bottom row
       print("   0 ");
    } else {                         # anywhere else
        print("     ");
    }

    # Axis and data for the row.
    for ($x = 0; $x <= $graph_cols; $x++) {
       printf("%s", $graph[$x][$y]);
    }
    if (0 == $y) {
       print("$x_unit\n");
    } else {
       print("\n");
    }
}
printf("     0%s%5s\n", ' ' x ($graph_cols-5), $x_label);
undef @graph;

#----------------------------------------------------------------------------
# Decode all addresses
#----------------------------------------------------------------------------

print "\n";

# First pass, get all the addresses we need to decode per object
# Effectively building a hash of hashes where the 1st level are
# the objects and the 2nd level the addresses from that object.
# Also check memory usage on a per object and on a per thread
# basis.
foreach my $ptr (keys %chunks) {
   my $btstr = $chunks{$ptr}{'backtrace'};
   my $thread_id = $chunks{$ptr}{'thread_id'};
   my @bt = split (/\;/, $btstr);
   if (defined $bt[1]) {
      my $obj = object_from_addr ($bt[1]);
      if (defined ($obj)) {
         if (defined ($usage_by_objects{$obj})) {
            $usage_by_objects{$obj} += $chunks{$ptr}{'size'};
         }
         else {
            $usage_by_objects{$obj} = $chunks{$ptr}{'size'};
         }
      }
      if (defined ($usage_by_threads{$thread_id})) {
         $usage_by_threads{$thread_id} += $chunks{$ptr}{'size'};
      }
      else {
         $usage_by_threads{$thread_id} = $chunks{$ptr}{'size'};
      }
   }
   foreach $a (@bt) {
      my $obj = object_from_addr ($a);
      if ($obj ne "unknown") {
         $objects{$obj}{$a} = "???";
      }
   }
}

# Decode addresses from callstacks collected for unknown_frees
foreach my $btstr (keys %unknown_frees) {
   my @bt = split (/\;/, $btstr);
   foreach $a (@bt) {
      my $obj = object_from_addr ($a);
      if ($obj ne "unknown") {
         $objects{$obj}{$a} = "???";
      }
   }
}

# Find files and their load offsets
foreach my $obj (keys %objects) {
   my $file = $obj;
   my @paths_array = split (/:/, $paths);
   $objects{$obj}{'file'} = '';
   foreach my $p (@paths_array) {
      if (-e $p . $obj) {
         $file = $p . $obj;
      }
      elsif (-e $p . "/" . basename ($obj)) {
         $file = $p . "/" . basename ($obj);
      }
   }
   debug "Checking for $file...";
   if (-e $file) {
      $objects{$obj}{'file'} = $file;
      my $type = `file -L -b $file`;
      if ($type =~ / executable,/) {
         $exec = $file;
         $objects{$obj}{'offset'} = 0;
      }
      else {
         my $offset = `$objdump -h $file |grep ' .text '|awk '{ print \$4; }'`;
         $offset =~ s/\n//g;
         $objects{$obj}{'offset'} = hex ($offset);
      }
   }
}

if (-e $exec) {
   my $cmd = "$gdb --quiet";
   debug "gdb command = $cmd";
   my $pid = open2 (*RP, *WP, $cmd);
   my $line;
   foreach my $obj (keys %objects) {
      my $file   = $objects{$obj}{'file'};
      my $start  = $objects{$obj}{'start'};
      my $offset = $objects{$obj}{'offset'};
      if ((defined ($start)) && (defined ($offset))) {
         # the parent process has an offset of zero
         if ($offset > 0) {
            my $a = $start + $offset;
            debug ">gdb: " . sprintf ("add-symbol-file $file 0x%x", $a);
            print WP sprintf ("add-symbol-file $file 0x%x\n", $a);
            #$line = <RP>; # skip "add symbol table from file..."
            #$line = <RP>; # skip ".text_addr = ..."
            #$line = <RP>; # skip "(y or n)..."
            #$line = <RP>; # skip "Reading symbols from..."
         }
         else {
            debug ">gdb: symbol-file $file";
            print WP "symbol-file $file\n";
         }

         # Skip all messages printed by gdb until "Reading symbols from"
         do {
            $line = <RP>;
            $line =~ s/\n//;
            debug ">gdb: $line";
         } while ($line !~ /Reading symbols from/);

         # Loop for decoding all addresses we need from that object
         for my $a ( keys %{ $objects{$obj} } ) {

            # Skip special entries from the objects hash
            next if ($a eq "file");
            next if ($a eq "start");
            next if ($a eq "offset");

            # Get gdb to resolve this address
            debug ">gdb: info line *0x$a";
            print WP "info line *0x$a\n";
            $line = <RP>;
            $line =~ s/\n//g;
            debug "<gdb: '$line'";

            my $method = '';
            my $file   = '';
            my $dir    = '';
            my $num    = '';
            my $loc    = sprintf ("%s: ??? [%s]", $a, basename ($obj));

            # No debugging information but the symbol could be resolved
            if ($line =~ /No line number information available for address 0x[0-9a-f]+ <([A-Za-z0-9_:, ()<>&*]+)\+\d+>/) {
               $method = $1;
               $loc    = $method;
               $loc    = sprintf ("%s: %s [%s]", $a, $method, basename ($obj));
               debug "matched to symbol $method";
            }
            # File & line information found
            elsif ($line =~ /Line (\d+) of "([^"]+)" starts at address 0x[0-9a-f]+ <([A-Za-z0-9_:, ()<>&*]+)\+\d+>/) {
               $num    = $1;
               $file   = $2;
               $method = $3;
               $loc    = sprintf ("%s: %s <%s:%u> [%s]", $a, $method, $file, $num, basename ($obj));
               debug "matched to $file:$line ($method)";
            }
            elsif ($line =~ /A problem internal to GDB has been detected,/) {
               $line = <RP>; # skip "further debugging may prove unreliable."
               $line = <RP>; # skip "Quit this debugging session? (y or n)..."
               $line = <RP>;
               $line =~ s/\n//g;
            }
 
            if ($file ne '') {
               $dir  = dirname ($file);
               $file = basename ($file);
            }
 
            $hsyms{$a}{'object'} = $obj;
            $hsyms{$a}{'loc'}    = $loc;
            $hsyms{$a}{'dir'}    = $dir;
            $hsyms{$a}{'file'}   = $file;
            $hsyms{$a}{'line'}   = $num;
            $hsyms{$a}{'method'} = $method;
         }

         # unload symbol file(s)
         print WP "symbol-file\n";
      }
      # File could not be loaded
      else {
         for my $a ( keys %{ $objects{$obj} } ) {

            # Skip special entries from the objects hash
            next if ($a eq "file");
            next if ($a eq "start");
            next if ($a eq "offset");

            my $loc = sprintf ("%s: ??? [%s]", $a, basename ($obj));

            $hsyms{$a}{'object'} = $obj;
            $hsyms{$a}{'loc'}    = $loc;
            $hsyms{$a}{'dir'}    = '';
            $hsyms{$a}{'file'}   = '';
            $hsyms{$a}{'line'}   = '';
            $hsyms{$a}{'method'} = '';
         }
      }
   }
   print WP "quit\n";
   close (RP);
   close (WP);
}

#----------------------------------------------------------------------------
# Dump all blocks still in memory
#----------------------------------------------------------------------------

if ($show_all) {
    print "\n";
    print "Listing of all memory blocks still allocated:\n";
    print "---------------------------------------------\n";
}

my $idx = 1;
foreach my $ptr (keys %chunks) {
    my $thread_id = $chunks{$ptr}{'thread_id'};

    if(!defined($chunks{$ptr}{'size'})) {
       print "warn: $ptr does not have size!\n";
    }

    if ($show_all) {
        print "\nblock #" . $idx . ": block of " . $chunks{$ptr}{'size'} . " bytes not freed\n";
        print "\taddress  : " . $ptr . "\n";
        print "\ttimestamp: " . $chunks{$ptr}{'timestamp'} . "\n";
        print "\tthread   : " . $thread_id . "\n";
        print "\tcallstack:\n";
    }

    my $btstr = $chunks{$ptr}{'backtrace'};
    my @bt = split (/\;/, $btstr);
    if ($show_all) {
       foreach $a (@bt) {
           my %result = decode ($a);
           print "\t\t" . $result{'loc'} . "\n";
       }
    }
    $idx = $idx + 1;
}

print "\n";
print "Current heap utilization by modules:\n";
print "------------------------------------\n";
print "\n";

foreach my $obj (keys %usage_by_objects) {
   my $sz = $usage_by_objects{$obj};
   printf ("%-40s %24u (%3d%%)\n", basename ($obj), $sz, ($sz * 100) / $total);
}
printf ("%-40s %24u (100%%)\n", "TOTAL", $total);

print "\n";
print "Current heap utilization by threads:\n";
print "------------------------------------\n";
print "\n";

foreach my $thr (keys %usage_by_threads) {
   my $sz = $usage_by_threads{$thr};
   printf ("%-40s %24u (%3d%%)\n", "thread " . $thr, $sz, ($sz * 100) / $total);
}
printf ("%-40s %24u (100%%)\n", "TOTAL", $total);

if ($show_grouped) {

    if ($live_report ne '') {
       open (REPORT, '>', $live_report);
    }

    print "\n";
    print "Allocated blocks grouped by callstacks:\n";
    print "---------------------------------------\n";

    foreach my $btstr (sort {$hotspots{$b}{'size'} <=> $hotspots{$a}{'size'} } keys %hotspots) {
        next if ($hotspots{$btstr}{'size'} == 0);
        my $allocs = $hotspots{$btstr}{'allocs'};
        my $frees  = $hotspots{$btstr}{'frees'};
        my $size   = $hotspots{$btstr}{'size'};
        my $total  = $allocs + $frees;
        my $ratio  = floor ($allocs * 100 / $total);
        print "\n";
        print $allocs . " allocation(s) ($ratio% alive) for a total of " . 
            $size . " bytes from:\n";
        my @bt = split (/\;/, $btstr);
        foreach my $a (@bt) {
            my %result = decode ($a);
            print "\t\t" . $result{'loc'} . "\n";
        }
        if ($live_report ne '') {
           my %result = get_caller_info ($btstr);
	   if (%result) {
              my $obj    = $result{'object'};
              my $loc    = $result{'loc'};
              my $dir    = $result{'dir'};
              my $file   = $result{'file'};
              my $line   = $result{'line'};
              my $method = $result{'method'};
              print REPORT "$obj;$dir;$file;$line;$method;$allocs;$frees;$size\n";
           }
        }
    }
    if ($live_report ne '') {
       close (REPORT);
    }
}

#----------------------------------------------------------------------------
# Dump unknown frees
#----------------------------------------------------------------------------

if (($show_unknown) && (scalar (keys %unknown_frees) > 0)) {

    print "\n";
    print "Free operations without a matching allocation:\n";
    print "----------------------------------------------\n";

    foreach my $btstr (sort {$unknown_frees{$b} <=> $unknown_frees{$a}} keys %unknown_frees) {
       print "\n";
       print $unknown_frees{$btstr} . " free(s) from:\n";
       my @bt = split (/\;/, $btstr);
       foreach my $a (@bt) {
          my %result = decode ($a);
          print "\t\t" . $result{'loc'} . "\n";
       }
   }
}

#----------------------------------------------------------------------------
# Create graph via dot
#----------------------------------------------------------------------------

if ($graph ne '') {

   my %nodes;
   my %links;
   
   foreach my $ptr (keys %chunks) {
      my $btstr = $chunks{$ptr}{'backtrace'};
      my $sz = $chunks{$ptr}{'size'};
      my @bt = split (/\;/, $btstr);
      my $level = 0;
      my $previous;
      foreach $a (@bt) {
         # Create a new node
         if (not defined $nodes{$a}) {
            my %result = decode ($a);
            $nodes{$a}{'loc'}  = $result{'loc'};
            $nodes{$a}{'size'} = 0;
         }
         # Create a link
         if ($level > 0) {
            if ($previous ne $a) {
               if (not defined $links{$a}{$previous}) {
                  $links{$a}{$previous} = 0;
               }
               debug "adding $sz bytes to link $a -> $previous";
               $links{$a}{$previous} += $sz;
            }
         }
         # Add allocated memory to this node
         # FIXME: check for recursive functions
         debug "adding $sz bytes to node $a (" . $nodes{$a}{'loc'} . ")";
         $nodes{$a}{'size'} += $sz;
         $level ++;
         $previous = $a;
      }
   }

   open (GRAPH, ">" . $graph);
   print GRAPH "digraph live_objects {\n";
   print GRAPH "   size=\"10,10\"\n";
   foreach my $n (keys %nodes) {
      my $sz = $nodes{$n}{'size'};
      my $f = $sz / $total;
      if ($f < $node_fraction) {
         debug "not creating node $n (" . $nodes{$n}{'loc'} . "): $sz / $total ($f)";
         next;
      }
      my $label = $nodes{$n}{'loc'};
      $label =~ s/^[0-9a-f]+: //;
      $label =~ s/ at /\\n/;
      print GRAPH "   F$n [shape=box,label=\"" . $label . "\"];\n";
   }
   # create link in dot output
   foreach my $n (keys %nodes) {
      debug "process links originating from $n";
      my $f = $nodes{$n}{'size'} / $total;
      # if the source node has been filtered out, skip all its links
      next if ($f < $node_fraction);
      foreach my $t (keys %{$links{$n}}) {
         debug "considering target node $t";
         $f = $nodes{$t}{'size'} / $total;
         if ($f < $node_fraction) {
            debug "skipping link " . $nodes{$n}{'loc'} . " -> " . $nodes{$t}{'loc'};
            debug "source node: " . $nodes{$n}{'size'} . " / " . $total;
            debug "target node: " . $nodes{$t}{'size'} . " / " . $total;
            next;
         }
         print GRAPH "   F$n -> F$t [label=\"" . $links{$n}{$t} . "\"];\n";
      }
   }
   print GRAPH "}\n";
   close (GRAPH);
}

