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

use warnings;
use strict;

use subs "FIONREAD";
require "sys/ioctl.ph";
use IO::Select;
use IO::Socket::INET;

my $s = IO::Socket::INET->new (Proto => "udp", LocalPort => 6001)
  or die "$0: can't connect: $@";

my $file=$ARGV[0];
open (OUT, '>', $file) or die("Could not open " . $file . "!");
binmode (OUT);

while (1) {

   my @ready = IO::Select->new($s)->can_read;
   if ($ready [0] == $s) {
      # Get number of bytes received
      my $size = pack "L", 0;
      ioctl $s, FIONREAD, $size or next;

      # Read bytes from socket
      sysread $s, my $buf, unpack "L", $size or next;

      # Write packet to output file and flush
      print OUT $buf;
      OUT->autoflush(1);
   }
}

