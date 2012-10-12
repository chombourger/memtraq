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

# Load provided map file into the 'maps' array
my %maps;
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

my %chunks;
my $total = 0;
my $allocs = 0;
my $frees = 0;
my $reallocs = 0;
my $ts = 0;
my $log = 1;

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

   push (@fields, $ts);
   push (@heap_history, $total);
}
close(DMALLOC);

my $idx = 1;
foreach my $ptr (keys %chunks) {
    my $thread_name = $chunks{$ptr}{'thread_name'};
    my $thread_id = $chunks{$ptr}{'thread_id'};

    print $idx . ": block of " . $chunks{$ptr}{'size'} . " bytes not freed\n";
    print "\taddress  : " . $ptr . "\n";
    print "\ttimestamp: " . $chunks{$ptr}{'timestamp'} . "\n";
    print "\tthread   : " . $thread_name . " (" . $thread_id . ")\n";
    print "\tcallstack:\n";

    my @bt = split (/\;/, $chunks{$ptr}{'backtrace'});
    foreach $a (@bt) {
       my $loc = $a;
       if ($a =~ /^0x[0-9a-f]+$/) {
       $a = hex ($a);
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
                   $obj = $p . "/" . basename($obj);
                }
             }
             if (-e $obj) {
                my $offset = $a - $start;
                my $type = `file -b $obj`;
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
          }
       }
       }
       print "\t\t" . $loc . "\n";
    }
    $idx = $idx + 1;
}

print $allocs . " allocs, " . $frees . " frees, " . $reallocs . " reallocs\n";
print $total . " bytes in use\n";

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

