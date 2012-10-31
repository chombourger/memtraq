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

use File::Basename;
use FileHandle;
use Getopt::Long;
use IPC::Open2;

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
my $map = '';
my $node_fraction = 0.20;
my $paths = '';
my $show_all = 0;
my $show_grouped = 0;
my $show_unknown = 0;
my $do_debug = 0;

GetOptions(\%opts,
   'before|b=s' => \$before,
   'after|a=s' => \$after,
   'debug|d' => \$do_debug,
   'graph|g=s' => \$graph,
   'map|m=s' => \$map,
   'node-fraction|n=f' => \$node_fraction,
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
open (DMALLOC, $file) or die("Could not open " . $file . "!");

my %maps;
my %syms;

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
            $maps{$start}{'file'}  = $line;
            $maps{$start}{'start'} = hex ($start);
            $maps{$start}{'end'}   = hex ($end);
            debug "added map entry '$line' $start-$end";
         }
      }
   }
   close (MAP);
}

sub object_from_addr {
   my $a = $_[0];
   my $result = "unknown";

   if ($a =~ /^0x[0-9a-f]+$/) {
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

sub offset_from_addr {
   my $a = $_[0];
   my $result = 0;

   if ($a =~ /^0x[0-9a-f]+$/) {
      $a = hex ($a);
      foreach my $m (keys %maps) {
         my $start = $maps{$m}{'start'};
         my $end   = $maps{$m}{'end'};
         if (($start <= $a) && ($a <= $end)) {
            return $a - $start;
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

   if ($a =~ /^0x[0-9a-f]+$/) {
      if (defined ($syms{$a})) {
         $result{'object'} = $syms{$a}{'object'};
         $result{'loc'} = $syms{$a}{'loc'};
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


my %chunks;
my $total = 0;
my $allocs = 0;
my $frees = 0;
my %unknown_frees;
my $reallocs = 0;
my $log = 1;
my %hotspots;
my $lines = 0;

my @heap_history;

if ($after ne '') {
   print "# tracking on hold till tag '" . $after . "' (--after)...\n";
   $log = 0;
}

foreach my $line (<DMALLOC>)  {
   $line =~ s/\n//;

   my $thread_name = "";
   my $thread_id = "";

   # <ts>;<thread-name>
   if ($line =~ /^\d+\;/) {

      $lines = $lines + 1; 

      $ts = $line;
      $ts =~ s/\;.*//g;
      $line =~ s/^\d+\;//;

      # Extract thread-name
      $thread_name = $line;
      $thread_name =~ s/\;.*//;
      $line =~ s/[^;]+\;//;

      # Extract thread-id
      $thread_id = $line;
      $thread_id =~ s/\;.*//;
      $line =~ s/\d++\;//;

      # Initialize ts_min if this is the first log entry
      if ($lines eq 1) {
         $ts_min = $ts;
      }

      # As memtraq logs are ordered chronogically, ts_max is the current ts
      $ts_max = $ts;
   }

   # tag;<name>;<serial>;void;<backtrace>
   if ($line =~ /^tag\;/) {

      # Extract tag name
      my $name = $line;
      $name =~ s/^tag\;//g;
      $name =~ s/\;.*//;

      # Extract tag serial
      my $serial = $line;
      $serial =~ s/^tag\;[^;]+\;//;
      $serial =~ s/\;.*//;

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

   # malloc;<size>;void;<result>;<backtrace>
   if ($line =~ /^malloc\;/) {

      # Extract backtrace
      my $bt = $line;
      $bt =~ s/^malloc\;\d+\;void\;0x[0-9a-f]+\;//;
      $bt =~ s/'.*//g;

      # Extract allocated pointer
      my $ptr = $line;
      $ptr =~ s/^malloc\;\d+\;void\;//;
      $ptr =~ s/\;.*//;

      # Extract buffer size
      my $size = $line;
      $size =~ s/^malloc\;//;
      $size =~ s/\;.*//;

      if ($log != 0) {
         $chunks{$ptr}{'backtrace'} = $bt;
         $chunks{$ptr}{'size'} = $size;
         $chunks{$ptr}{'thread_name'} = $thread_name;
         $chunks{$ptr}{'thread_id'} = $thread_id;
         $chunks{$ptr}{'timestamp'} = $ts;

         $total = $total + $size;
         $allocs ++;
      }
   }
   # free;<ptr>;void;void;<backtrace>
   if ($line =~ /^free\;/) {

      # Extract pointer
      my $ptr = $line;
      $ptr =~ s/^free\;//;
      $ptr =~ s/\;.*//;

      # Extract backtrace
      my $bt = $line;
      $bt =~ s/\(nil\)/0x0/g;
      $bt =~ s/^free\;0x[0-9a-f]+\;void\;void\;//;
      $bt =~ s/'.*//g;

      if ($log != 0) {
         if (defined $chunks{$ptr}) {
            my $size = $chunks{$ptr}{'size'};
            $total = $total - $size;
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
   # realloc;<oldptr>;<size>;<result>;<backtrace>
   if ($line =~ /^realloc\;/) {

      # Extract backtrace
      my $bt = $line;
      $bt =~ s/\(nil\)/0x0/g;
      $bt =~ s/^realloc\;0x[0-9a-f]+\;\d+\;0x[0-9a-f]+\;//;
      $bt =~ s/'.*//g;

      # Extract old pointer
      my $oldptr = $line;
      $oldptr =~ s/^realloc\;//;
      $oldptr =~ s/\;.*//;

      # Extract new size
      my $size = $line;
      $size =~ s/\(nil\)/0x0/g;
      $size =~ s/^realloc\;0x[0-9a-f]+\;//;
      $size =~ s/\;.*//;

      # Extract new ptr
      my $newptr = $line;
      $newptr =~ s/\(nil\)/0x0/g;
      $newptr =~ s/^realloc\;0x[0-9a-f]+\;\d+\;//;
      $newptr =~ s/\;.*//;

      if ($log != 0) {
         if (defined $chunks{$oldptr}) {
            my $size = $chunks{$oldptr}{'size'};
            $total = $total - $size;
         }

         $chunks{$newptr}{'backtrace'} = $bt;
         $chunks{$newptr}{'size'} = $size;
         $chunks{$newptr}{'thread_name'} = $thread_name;
         $chunks{$newptr}{'thread_id'} = $thread_id;
         $chunks{$newptr}{'timestamp'} = $ts;

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
close(DMALLOC);

print "\n";
print "Summary:\n";
print "--------\n";
print "\n";

print $total . " bytes (" . keys(%chunks) . " blocks) in use\n";
print $allocs . " allocs, " . $frees . " frees, " . $reallocs . " reallocs\n";
if (scalar (keys %unknown_frees) > 0) {
   print "Note: " . scalar(%unknown_frees) . " frees for unknown blocks!\n";
}
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

my %objects;

print "\n";

# First pass, get all the addresses we need to decode per object
# Effectively building a hash of hashes where the 1st level are
# the objects and the 2nd level the addresses from that object.
# Also check memory usage on a per object and on a per thread
# basis.
foreach my $ptr (keys %chunks) {
   my $btstr = $chunks{$ptr}{'backtrace'};
   my $thread_name = $chunks{$ptr}{'thread_name'};
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

# Second pass
foreach my $obj (keys %objects) {
   my $file = $obj;
   my @paths_array = split (/:/, $paths);
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
      my $type = `file -L -b $file`;
      my $cmd = sprintf ("addr2line -C -f -p -e %s", $file);
      print "Reading symbols from " . $file . "\n";
      debug $cmd;
      my $pid = open2 (*RP, *WP, $cmd);
      for my $a ( keys %{ $objects{$obj} } ) {
         my $offset = offset_from_addr ($a);
         if ($type =~ / executable,/) {
            $offset = hex($a);
         }
         my $in = sprintf ("0x%x", $offset);
         debug "writing $in to pipe ($a)";
         print WP $in . "\n";
         my $loc = <RP>;
         $loc =~ s/\n//;
         $loc = sprintf ("%s: %s [%s 0x%x]", $a, $loc, basename ($obj), $offset);
         $syms{$a}{'object'} = $obj;
         $syms{$a}{'loc'} = $loc;
         debug ("resolved $a to $loc ('$obj')");
      }
      close (RP);
      close (WP);
   }
   else {
      for my $a ( keys %{ $objects{$obj} } ) {
         my $loc = sprintf ("%s: ??? [%s]", $a, basename ($obj));
         $syms{$a}{'object'} = $obj;
         $syms{$a}{'loc'} = $loc;
         debug "$a => $loc ($obj not found)"
      }
   }
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
    my $thread_name = $chunks{$ptr}{'thread_name'};
    my $thread_id = $chunks{$ptr}{'thread_id'};

    if(!defined($chunks{$ptr}{'size'})) {
       print "warn: $ptr does not have size!\n";
    }

    if ($show_all) {
        print "\nblock #" . $idx . ": block of " . $chunks{$ptr}{'size'} . " bytes not freed\n";
        print "\taddress  : " . $ptr . "\n";
        print "\ttimestamp: " . $chunks{$ptr}{'timestamp'} . "\n";
        print "\tthread   : " . $thread_name . " (" . $thread_id . ")\n";
        print "\tcallstack:\n";
    }

    my $btstr = $chunks{$ptr}{'backtrace'};
    my $count = 1;
    my $size = 0;
    if (defined ($hotspots{$btstr}{'count'})) {
       $count = $hotspots{$btstr}{'count'} + 1;
       $size  = $hotspots{$btstr}{'size'} + $chunks{$ptr}{'size'};
    }
    $hotspots{$btstr}{'count'} = $count;
    $hotspots{$btstr}{'size'}  = $size;

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
printf ("%-40s %24u (100%%)\n", "total", $total);

print "\n";
print "Current heap utilization by threads:\n";
print "------------------------------------\n";
print "\n";

foreach my $thr (keys %usage_by_threads) {
   my $sz = $usage_by_threads{$thr};
   printf ("%-40s %24u (%3d%%)\n", $thr, $sz, ($sz * 100) / $total);
}
printf ("%-40s %24u (100%%)\n", "total", $total);

if ($show_grouped) {

    print "\n";
    print "Allocated blocks grouped by callstacks:\n";
    print "---------------------------------------\n";

    foreach my $btstr (sort {$hotspots{$b}{'size'} <=> $hotspots{$a}{'size'} } keys %hotspots) {
        print "\n";
        print $hotspots{$btstr}{'count'} . " allocation(s) for a total of " . 
            $hotspots{$btstr}{'size'} . " bytes from:\n";
        my @bt = split (/\;/, $btstr);
        foreach my $a (@bt) {
            my %result = decode ($a);
            print "\t\t" . $result{'loc'} . "\n";
        }
    }
}

#----------------------------------------------------------------------------
# Dump unknown frees
#----------------------------------------------------------------------------

if (($show_unknown) && (scalar (%unknown_frees) > 0)) {

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
      $label =~ s/^0x[0-9a-f]+: //;
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

