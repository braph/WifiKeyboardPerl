#!/usr/bin/env perl

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

=begin COPYRIGHT

	WifiKeyboardPerl - Client for wifikeyboard written in perl
	Copyright (C) 2016 Benjamin Abendroth
	
	This program is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.
	
	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.
	
	You should have received a copy of the GNU General Public License
	along with this program.  If not, see <http://www.gnu.org/licenses/>.

=end COPYRIGHT

=begin DESCRIPTION

   WifiKeyboardPerl is a client for the wifikeyboard App for
   Android (https://github.com/IvanVolosyuk/wifikeyboard).

   See also: 
      DesktopKeyboard2Android - Client written in Java: https://github.com/dportabella/DesktopKeyboard2Android

=end DESCRIPTION

=cut

# TODO:
# - add configuration file??
# - make this thing working with unicode characters in readline mode
# - cmd_edit_text without wget

use 5.010001;
use strict;
use warnings;

use utf8;
use LWP::Simple;
use LWP::UserAgent;
use Term::TermKey;
use Term::ReadLine;
use File::Temp qw(tempfile);
use Getopt::Long qw(:config gnu_getopt auto_version);

my $PROGNAME = 'WifiKeyboardPerl';
$main::VERSION = 0.1;

my %options = (
   host   => 0,
   port   => 7777,
   mode   => 'raw',
   prefix => 'C-g',
   editor => $ENV{EDITOR},
);

# global variables
my ($seqConfirmed, $base_url, $readline, $termkey);

# forward declarations
sub send_key;
sub send_codes;
sub send_string;
sub cmd_edit_text;
sub cmd_send_prefix;
sub cmd_read_command;

my $WIFI_CNTRL = 17;
my $WIFI_ALT   = 18;
# keycodes mapped to wifi keyboard's one
my %wifi_keyboard_mapping = (
   'DEL'        =>  8,        # Backspace
   'Tab'        =>  9,
   'Escape'     =>  'C27',    
   'Enter'      =>  13,       # 10?

   'Up'         =>  38,
   'Down'       =>  40,
   'Right'      =>  39,
   'Left'       =>  37,

   'Home'       =>  36,
   'Insert'     =>  155,   
   'Delete'     =>  'C127',
   'End'        =>  35,
   'PageUp'     =>  33,
   'PageDown'   =>  34,
);

# Global keybindings
my %global_keymap = (
   # key => command_name
);

# Keybindings with prefixx
my %prefix_keymap = (
   # key => command_name
   ':'      =>  'read_command',
   'g'      =>  'send_prefix',
   'Q'      =>  'quit',
   'e'      =>  'edit_text',
   'r'      =>  'raw',
   'l'      =>  'readline',
   '?'      =>  'help',

   'DEL'    =>  'phone_back',
   's'      =>  'phone_search',
   'm'      =>  'phone_menu',
   'v'      =>  'phone_vol_down',
   'V'      =>  'phone_vol_up',
);

# Commands available for keybinding or in command mode (":")
my %commands = (
   'raw'             =>  sub { $options{mode} = 'raw';  },
   'readline'        =>  sub { $options{mode} = 'readline'; },
   'exit'            =>  sub { exit(0); },
   'quit'            =>  sub { exit(0); },
   'phone_back'      =>  sub { send_codes 'D27', 'U27' },
   'phone_center'    =>  sub { send_codes 'D112', 'U112' },
   'phone_menu'      =>  sub { send_codes 'D113', 'U113' },
   'phone_search'    =>  sub { send_codes 'D114', 'U114' },
   'phone_vol_up'    =>  sub { send_codes 'D121', 'U121' },
   'phone_vol_down'  =>  sub { send_codes 'D120', 'U120' },
   'seq_confirmed'   =>  sub { print "seqConfirmed = $seqConfirmed\n" },
   'help'            =>  \&cmd_show_help,
   'read_command'    =>  \&cmd_read_command,
   'send_prefix'     =>  \&cmd_send_prefix,
   'edit_text'       =>  \&cmd_edit_text,
   'send_codes'      =>  \&send_codes
);

# Send ^C/^Z instead of killing/suspending process
$SIG{INT}  = sub { send_codes("D$WIFI_CNTRL", "D".ord('C'), "U".ord('C'), "U$WIFI_CNTRL"); };
$SIG{STOP} = sub { send_codes("D$WIFI_CNTRL", "D".ord('Z'), "U".ord('Z'), "U$WIFI_CNTRL"); };

sub normalize_keycode {
   my $code = $termkey->parse_key($_[0], 0) or 
      die "Invalid key: $_[0]\n";
   return $termkey->format_key($code, 0);
}

sub init {
   $base_url = "http://$options{host}:$options{port}";

   my $src = get($base_url) || die "Could not connect to host: $!";
   $src =~ /seqConfirmed = ([0-9]+)/ or die "Could not extract seqConfirmed";
   $seqConfirmed = $1;

   $readline = Term::ReadLine->new('');
   $termkey = Term::TermKey->new(\*STDIN);
   $termkey->stop(); # display prompt in read_raw()

   # normalize (and check) keymap
   %wifi_keyboard_mapping = map {
      normalize_keycode($_) => $wifi_keyboard_mapping{$_};
   } keys %wifi_keyboard_mapping;

   # same for raw keymap ...
   %global_keymap = map {
      normalize_keycode($_) => $global_keymap{$_};
   } keys %global_keymap;

   # ... and prefix keymap ...
   %prefix_keymap = map {
      normalize_keycode($_) => $prefix_keymap{$_};
   } keys %prefix_keymap;

   # ... and prefix key
   $options{prefix} = normalize_keycode($options{prefix});

   # check if commands given in keymaps exist
   for (values(%global_keymap), values(%prefix_keymap)) {
      die "Unknown command: $_\n" if not exists $commands{$_};
   }
}

sub get_key_obj {
   return $termkey->parse_key($_[0], 0);
}

sub send_code {
   head("$base_url/key?$seqConfirmed,$_[0],"); # trailing comma needed!
   ++$seqConfirmed;
}

sub send_codes {
   send_code($_) for (@_);
}

sub send_key {
   my ($key) = @_;
   my $keycode = $termkey->format_key($key, 0);

   if (exists($wifi_keyboard_mapping{$keycode})) {
      if (substr($wifi_keyboard_mapping{$keycode}, 0, 1) eq 'C') {
         # send as character
         send_codes($wifi_keyboard_mapping{$keycode});
      }
      else {
         # send as key press
         send_codes('D'.$wifi_keyboard_mapping{$keycode},
                    'U'.$wifi_keyboard_mapping{$keycode});
     }
   }
   else {
      if ($key->modifier_ctrl) {
         send_codes("D$WIFI_CNTRL");
      }
      if ($key->modifier_alt) {
         send_codes("D$WIFI_ALT");
      }

      if ($key->modifier_ctrl) {
         send_codes('C'.($key->codepoint - 96));
      }
      else {
         send_codes('C'.($key->codepoint));
      }

      if ($key->modifier_alt) {
         send_codes("U$WIFI_ALT");
      }
      if ($key->modifier_ctrl) {
         send_codes("U$WIFI_CNTRL");
      }
   }
}

sub send_string {
   for (split(//, $_[0])) {
      send_codes('C'.ord($_));
   }
}

sub read_with_readline {
   if ($termkey->is_started()) {
      print "\n\nReadline mode.\nIf you want to insert a newline, write '\\n'.\n";
      print "If you want so send the message (e.g. in messenger) press enter on empty line.\n\n";
      $termkey->stop();
   }

   my $line = $readline->readline("$PROGNAME [readline] > ");

   if (! $line) {
      send_codes('D13', 'U13');
   }
   elsif ($line =~ /^:([a-zA-Z_-]+)(.*)$/) {
      my @args = grep { $_ } split(/ /, $2);
      ($commands{$1} || sub { print "Command not found: $1\n" })->(@args);
   }
   else {
      $line =~ s/\\n/\n/g;
      send_string($line);
   }
}

sub find_binding {
   my ($keymap, $key_obj) = @_;
   my $keycode = $termkey->format_key($key_obj, 0);

   for my $key (keys %$keymap) {
      return $keymap->{$key} if ($key eq $keycode);
   }

   return undef;
}

sub read_raw {
   my $key;
   my $prefix_mode = 0;

   while ($options{mode} eq 'raw') {
      $termkey->is_started() or do { 
         $termkey->start();
         select(STDOUT); $|++;
         print "\r$PROGNAME [raw] > ";
      };

      $termkey->waitkey($key);

      if ($prefix_mode) {
         $prefix_mode = 0;

         my $command_name = find_binding(\%prefix_keymap, $key);
         if ($command_name) {
            $commands{$command_name}->();
         } else {
            print("Unknown key in prefix_keymap: ", $termkey->format_key($key, 0), "\n");
         }

         $termkey->stop();
      }
      elsif ($termkey->format_key($key, 0) eq $options{prefix}) {
         $prefix_mode = 1;
      }
      elsif ((my $command_name = find_binding(\%global_keymap, $key))) {
         $commands{$command_name}->();
      }
      else {
         send_key($key);
      }
   }
}

sub cmd_show_help {
   print "\n";
   print "\nPrefix key is: $options{prefix}\n";
   print "\nGlobal keys\n";
   print "\t$_: $global_keymap{$_}\n" for (keys %global_keymap);
   print "\nPrefix keys\n";
   print "\t$_: $prefix_keymap{$_}\n" for (keys %prefix_keymap);
   print "\nAvailable commands\n";
   print "\t:$_\n" for (sort keys %commands);
   print "\n";
   $termkey->stop(); # redraw prompt
}

sub cmd_read_command {
   $termkey->is_started() and $termkey->stop();
   my $command = $readline->readline("$PROGNAME [command]: ");
   ($commands{$command} || sub { print "Command not found: $command\n" })->();
}

sub cmd_send_prefix {
   send_key($termkey->parse_key($options{prefix}, 0));
}

sub cmd_edit_text {
   `wget -qO- "$base_url/text" | vipe | wget --save-headers O- "$base_url/form" --post-data "\$(cat)"`;
   ++$seqConfirmed;
   return;

   my $text = get("$base_url/text");
   my ($fh, $filename) = tempfile();
   print $fh $text;
   close $fh;
   system($options{cmd_edit_textor}, $filename);
   open($fh, '<', $filename) or do { print "opening file failed"; return; };
   $text = do {
      local $/ = undef;
      <$fh>;
   };
   my $ua = LWP::UserAgent->new();
   my $res = $ua->post("$base_url/form", $text => '');
   say $res->decoded_content();
}

# === main ====

GetOptions(\%options,
   'host|h=s',
   'port|p=i',
   'mode|m=s',
   'prefix|p=s',
   'help' => sub {
      require Pod::Usage;
      Pod::Usage::pod2usage(-exitstatus => 0, -verbose => 2)
   }
) or exit 1;

die "Missing --host\n" unless $options{host};
die "Option --mode must be either 'raw' or 'readline'" 
   unless ($options{mode} eq 'raw' or $options{mode} eq 'readline');

init();

print "\nType keys '$options{prefix}' + '$_' for help\n\n"
   for (grep { $prefix_keymap{$_} eq 'help' } keys %prefix_keymap);

while () {
   if ($options{mode} eq 'raw') {
      read_raw();
   }
   elsif ($options{mode} eq 'readline') {
      read_with_readline();
   }
}

__END__

=pod

=head1 NAME

WifiKeyboardPerl - Client for wifikeyboard written in perl

=head1 SYNOPSIS

=over 8

WifiKeyboardPerl
[B<--host|-h>=I<host>]
[B<--port|-p>=I<port>]
[B<--mode|-m>=I<mode>]
[B<--prefix|-p>=I<prefix>]

=back

=head1 OPTIONS

=head2 Basic Startup Options

=over

=item B<--help>

Display this help text and exit.

=item B<--version>

Display the script version and exit.

=back

=head1 Options

=over

=item B<--host|-h> I<HOST>

Host to connect to.

=item B<--port|-p> I<PORT>

Port to connect to.

=item B<--mode|-m> I<MODE>

Start in I<MODE>. Either 'raw' or 'readline'.

=item B<--prefix|-p> I<PREFIX>

Set prefix key to I<PREFIX>

=back

=head1 AUTHOR

Written by Benjamin Abendroth.

=cut

