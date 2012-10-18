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
use Getopt::Long;

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

# Number of columns for graphs 
my $graph_cols = 80;
# Number of rows for graphs 
my $graph_rows = 40;

my $before = '';
my $after = '';
my $map = '';
my $paths = '';
my $svg = '';

GetOptions(\%opts,
   'before|b=s' => \$before,
   'after|a=s' => \$after,
   'map|m=s' => \$map,
   'paths|p=s' => \$paths,
   'svg|s=s' => \$svg,
);

my $file=$ARGV[0];
open (DMALLOC, $file) or die("Could not open " . $file . "!");

my %maps;
my %syms;

# Load provided map file into the 'maps' array
if ($map ne '') {
   open (MAP, $map) or die("Could not open map " . $map . "!");
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
         }
      }
   }
   close (MAP);
}

sub decode {
   my $a = $_[0];
   my $loc = $a;
   my %result;

   if ($a =~ /^0x[0-9a-f]+$/) {
      $a = hex ($a);
      if (defined ($syms{$a})) {
         $result{'object'} = $syms{$a}{'object'};
         $result{'loc'} = $syms{$a}{'loc'};
      }
      else {
         foreach my $m (keys %maps) {
            my $start = $maps{$m}{'start'};
            my $end   = $maps{$m}{'end'};
            my $obj   = $maps{$m}{'file'};
            if (($start <= $a) && ($a <= $end)) {
               my @paths_array = split (/:/, $paths);
               foreach my $p (@paths_array) {
                  if (-e $p . $obj) {
                     $obj = $p . $obj;
                  }
                  elsif (-e $p . "/" . basename ($obj)) {
                     $obj = $p . "/" . basename ($obj);
                  }
               }
               if (-e $obj) {
                  my $offset = $a - $start;
                  my $type = `file -L -b $obj`;
                  if ($type =~ / executable,/) {
                     $offset = $a;
                  }
                  my $cmd = sprintf ("addr2line -i -p -C -f -e %s 0x%x", $obj, $offset);
                  $loc = `$cmd`;
                  $loc =~ s/\n//g;
                  $loc = sprintf ("0x%08x: %s [%s]", $a, $loc, basename ($obj));
               }
               else {
                  $loc = sprintf ("0x%08x: [%s]", $a, $obj);
               }
               $result{'object'} = $obj;
               $result{'loc'} = $loc;
               $syms{$a}{'object'} = $obj;
               $syms{$a}{'loc'} = $loc;
            }
         }
      }
   }
   return %result;
}

my %chunks;
my $total = 0;
my $allocs = 0;
my $frees = 0;
my $unknown_frees = 0;
my $reallocs = 0;
my $log = 1;
my %hotspots;
my $lines = 0;

my @fields;
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
      $bt =~ s/^free\;void\;void\;0x[0-9a-f]+\;//;
      $bt =~ s/'.*//g;

      if ($log != 0) {
         if (defined $chunks{$ptr}) {
            my $size = $chunks{$ptr}{'size'};
            $total = $total - $size;
         }
         else {
            $unknown_frees ++;
         }

         $frees ++;
         delete $chunks{$ptr};
      }
   }
   # realloc;<oldptr>;<size>;<result>;<backtrace>
   if ($line =~ /^realloc\;/) {

      # Extract backtrace
      my $bt = $line;
      $bt =~ s/^realloc\;0x[0-9a-f]+\;\d+\;0x[0-9a-f]+\;//;
      $bt =~ s/'.*//g;

      # Extract old pointer
      my $oldptr = $line;
      $oldptr =~ s/^realloc\;//;
      $oldptr =~ s/\;.*//;

      my $ptr = $line;
      $ptr =~ s/^realloc\;\d+\;void\;//;
      $ptr =~ s/\;.*//;

      # Extract new size
      my $size = $line;
      $size =~ s/^realloc\;0x[0-9a-f]+\;//;
      $size =~ s/\;.*//;

      # Extract new ptr
      my $newptr = $line;
      $newptr =~ s/^realloc\;0x[0-9a-f]+\;\d+\;//;
      $newptr =~ s/\;.*//;

      if ($log != 0) {
         if (defined $chunks{$oldptr}) {
            my $size = $chunks{$oldptr}{'size'};
            $total = $total - $size;
         }

         $chunks{$newptr}{'backtrace'} = $bt;
         $chunks{$newptr}{'size'} = $size;
         $chunks{$ptr}{'thread_name'} = $thread_name;
         $chunks{$ptr}{'thread_id'} = $thread_id;
         $chunks{$ptr}{'timestamp'} = $ts;

         $total = $total + $size;
         $reallocs ++;
      }
   }

   if ($total > $heap_max) {
      $heap_max = $total;
   }

   push (@fields, $ts);
   push (@heap_history, $total);
}
close(DMALLOC);

print "\n";
print "Summary:\n";
print "--------\n";
print "\n";

print $total . " bytes (" . keys(%chunks) . " blocks) in use\n";
print $allocs . " allocs, " . $frees . " frees, " . $reallocs . " reallocs\n";
if ($unknown_frees > 0) {
   print "Note: " . $unknown_frees . " frees for unknown blocks!\n";
}

my $time_total = $ts_max - $ts_min;
my $time_incr = $time_total / $graph_cols;
my $heap_incr = $heap_max / $graph_rows;

print "\n";
print "Listing of all memory blocks still allocated:\n";
print "---------------------------------------------\n";

my $idx = 1;
foreach my $ptr (keys %chunks) {
    my $thread_name = $chunks{$ptr}{'thread_name'};
    my $thread_id = $chunks{$ptr}{'thread_id'};

    print "\nblock #" . $idx . ": block of " . $chunks{$ptr}{'size'} . " bytes not freed\n";
    print "\taddress  : " . $ptr . "\n";
    print "\ttimestamp: " . $chunks{$ptr}{'timestamp'} . "\n";
    print "\tthread   : " . $thread_name . " (" . $thread_id . ")\n";
    print "\tcallstack:\n";

    my $btstr = $chunks{$ptr}{'backtrace'};
    my @bt = split (/\;/, $btstr);
    my $count = 1;
    my $size = 0;
    if (defined ($hotspots{$btstr}{'count'})) {
       $count = $hotspots{$btstr}{'count'} + 1;
       $size  = $hotspots{$btstr}{'count'} + $chunks{$ptr}{'size'};
    }
    $hotspots{$btstr}{'count'} = $count;
    $hotspots{$btstr}{'size'}  = $size;
    my $level = 0;
    foreach $a (@bt) {
       my %result = decode ($a);
       print "\t\t" . $result{'loc'} . "\n";
       my $obj = $result{'object'};
       if ((defined ($obj)) && ($level == 0)) {
          if (defined ($usage_by_objects{$obj})) {
             $usage_by_objects{$obj} += $chunks{$ptr}{'size'};
          }
          else {
             $usage_by_objects{$obj} = $chunks{$ptr}{'size'};
          }
       }
       if ($level == 0) {
          if (defined ($usage_by_threads{$thread_id})) {
             $usage_by_threads{$thread_id} += $chunks{$ptr}{'size'};
          }
          else {
             $usage_by_threads{$thread_id} = $chunks{$ptr}{'size'};
          }
       }
       $level = $level + 1;
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

if ($svg ne '') {

   use SVG::TT::Graph::Line;

   my $graph = SVG::TT::Graph::Line->new ({
      'height'           => '1024',
      'width'            => '768',
      'fields'           => \@fields,
      'stagger_x_labels' => 0,
      'show_data_values' => 0,
      'show_x_labels'    => 0,
      'scale_integers'   => 1,
      'area_fill'        => 0,
   });

   $graph->add_data({
     'data'  => \@heap_history,
     'title' => 'Heap',
   });

   open (MEMTRAQ_SVG, '>' . $svg);
   print MEMTRAQ_SVG $graph->burn ();
   close (MEMTRAQ_SVG);
}

