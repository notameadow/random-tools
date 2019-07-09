#!/usr/bin/perl

=head1 TTI PSU CONTROL

This script adds basic output controls to the TTI PSU.
The device uses something resembling SCPI but not quite, hence it 
listens on 9221 and not 5025.
The commands live at L<http://resources.aimtti.com/manuals/MX100T+MX100TP_Instruction_Manual-Iss7.pdf>

=head1 USAGE

./tti-control.pl $hostname $command $arguments

B<$command> and B<$arguments> as below, with the exception of commands starting
with ':' - those will be sent out as-is, for example:

 ./tti-psu.pl 192.168.0.1 :*idn?

will send B<idn*?>

Commands with B<?> will make the script wait for a response for 1s.

=head1 COMMANDS

=head2 powercycle|pc $output $delay

Powercycle: set B<$output> to off, wait B<$delay>, set $output to on. 
Obviously it can be used to switch the output on.

 $output - int, as defined in the manual, default 1
 $delay - int, delay in miliseconds, default 500ms

=head2 on|off $output

on or off, those are two commands but they work in the same way, setting
the B<$output> on or off.

 $output - int, as defined in the manual, default: 1

=cut

use strict;
use warnings;
use v5.014;
use IO::Socket::INET;
use Time::HiRes qw(usleep);

my ($host, @args) = @ARGV;

my $debug = 1;
my $port = 9221;
my $output = 1;
my $delay = 500;
my $tmo = 1;
my $response = 0;

my $scpiCmd;
my $cmd = $args[0] || '';

if ($cmd =~ /^:/) {
    $scpiCmd = "@args";
    $scpiCmd =~ s/^://;
    scpi();

} elsif ($cmd =~ /^powercycle|pc$/) {
    my $output = $args[1] ? $args[1] : $output;
    my $delay = $args[2] ? $args[2] : $delay;
    $delay *= 1000;

    $scpiCmd = "op" . $output . " 0";
    scpi($cmd);

    usleep($delay);    

    $scpiCmd = "op" . $output . " 1";
    scpi($cmd);
} elsif ($cmd =~ /^on|off$/) {
    my $output = $args[1] ? $args[1] : $output;

    my $state = $cmd eq 'on' ? 1 : 0;

    $scpiCmd = "op" . $output . " " . $state;
    scpi($cmd);
} else {
    say "Sorry, didn't catch that.";
}

sub scpi {
    my $socket = new IO::Socket::INET(
        PeerAddr => $host,
        PeerPort => $port,
        Proto => 'tcp',
    ) or die $!;

    my $buffer;
    $response = 1 if ($scpiCmd =~ /\?/);
    say "Sending command: $scpiCmd" if ($debug);


    syswrite($socket, $scpiCmd . "\n");

    if ($response) {
        my $nread;
        eval {
            local $SIG{ALRM} = sub {die "tmo\n"};
            alarm $tmo;
            
            $nread = sysread($socket, $buffer, 255);
            alarm 0;
        };

    if ($@) {
        if ($@ eq "tmo\n") {
            die "Timed out (${tmo}s) waiting for a response from ${host}:${port}\n" if ($@ eq "tmo\n");
        } else {
            die "Died trying to read the response from ${host}:{$port}: $@\n";
        }
    }
    say "Got $nread bytes" if ($debug);

    print $buffer;
    }
}

