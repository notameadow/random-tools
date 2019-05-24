#!/usr/bin/perl

=head1 saleae-dump.pl

This script will take a .csv from Saleae and convert it to something useful -
like a stream of hex values. Right now it recognises the data format by looking 
at the first line of the file.
The data is printed to stdout in hex as a string of [0-9A-F]{2}.

=head2 SPI

The format:

Time [s],Packet ID,MOSI,MISO
0.000000000000000,0,0x9F,0x00
0.000001660000000,0,0xFF,0x1F
0.000003360000000,0,0xFF,0x06

The Packet ID field is important as it separates SPI transactions. The protocol
is 'speak when spoken to' by the master, and the transactions are separated by
a state of /CS line (I haven't checked if Saleae does it properly). Using 
Packet ID fields we are able to display command-response pairs.

There is no way to determine which byte is the last byte of a command (on MOSI, 
master out slave in) line, the idle state is high so Saleae will interpret it 
as 0xFF. The same goes for the MISO (master in slave out) - there is no clear 
distinction as to where the response starts. We also know that only one line is 
active at a time - and it does happen, depending on the wiring, that signals 
cross over between channels (that is, clock pulses can be seen on an idle 
line) and be interpreted by Saleae as valid bits. 

The active state (that is, commands being either read by slave or sent by it) is
determined by the clock line (bits are being read on the line transition, 
usually on the leading edge) so Saleae is able to determine when 0xFF is a 
transmission or an idle (high) state.

This script will dump the data in two ways:
 - grouped in command-response sets,
 - whole stream of data from MISO

Since idle bytes on both lines are 0xFF and can pick up noise from other lines,
as mentioned above, we will:
 - ignore MISO from the start of a packet until 0xFF - this is a first attempt
   assumption and is most likely wrong,
 - ignore MOSI after the first 0xFF

 This applies to both modes (we want MISO stream to be free of noise).

=head2 UART

The format:
Time [s],Value,Parity Error,Framing Error
6.880548088000000,0x16,,
6.881669188000000,0x73,,
6.882801980000000,0x39,,

The format is simple enough, so it's just a matter of merging the bytes into
one string. We rely on Saleae to do its job.

=head3 UART options

--linebreak|lb, -l: insert newline *before* this string
--breakline|bl, -b: insert newline *after* this string

=cut

use strict;
use warnings;
use v5.014;
use Getopt::Long;

$| = 1;
my $bl = 0;
my $lb = 0;

GetOptions(
    'linebreak|lb|l=s' => \$lb,
    'breakline|bl|b=s' => \$bl,
) or die "Incorrect options (-l)\n";

my $header = <>;
spi() if ($header =~ /MOSI/);
uart() if ($header =~ /Parity Error,Framing Error/);

die "Header format not recognised: $header\n";

sub uart {
    my $output;
    while(<>) {
        chomp;
        my ($ts, $value, $parity, $framing) = split(/,/);
        $value =~ s/0x(..)/$1/;
        $output .= $value;
    }

    if ($lb) {
        $output =~ s/$lb/\n$lb/gm;
    }

    if ($bl) {
        $output =~ s/$bl/$bl\n/gm;
    }

    say $output;
    exit;
}

sub spi {
    my $transactions;
    my @packets;
    my $packets;

    while (<>) {
        chomp;
        my ($ts, $packetId, $mosi, $miso) = split(/,/);
        next unless ($packetId =~ /^\d+$/);

        $mosi = oct($mosi);
        $miso = oct($miso);

        # We don't know if packets are always consecutive and none are missed
        $packets->{$packetId} = 1;

        push (@{$transactions->{'raw'}->{$packetId}}, 
            {mosi => $mosi, miso => $miso});
    }

    @packets = sort ({$a <=> $b} keys(%$packets));

    for my $packetId (@packets) {
        push (@{$transactions->{'clear'}->{$packetId}}, 
            {metaMosi => 1, packetId => $packetId});
        my $mosiSend = 1;
        for my $transaction (@{$transactions->{'raw'}->{$packetId}}) {
            my $mosi = $transaction->{'mosi'};
            my $miso = $transaction->{'miso'};

            if ($mosiSend && ($mosi != 255)) {
                $miso = 256;
            } elsif ($mosiSend) {
                push (@{$transactions->{'clear'}->{$packetId}}, 
                    {metaMiso => 1});
                $mosiSend = 0;
                $mosi = 256;
            } else {
                $mosi = 256;
            }

            push (@{$transactions->{'clear'}->{$packetId}}, 
                {mosi => $mosi, miso => $miso});

        }
    }

    for my $packetId (@packets) {
        for my $transaction (@{$transactions->{'clear'}->{$packetId}}) {
            if ($transaction->{'metaMosi'}) {
                print "Packet ID: $transaction->{'packetId'}\nMOSI:\n";
            } elsif ($transaction->{'metaMiso'}) {
                print "\nMISO:\n";
            } else {
                # At any moment either mosi or miso has to be 256
                if ($transaction->{'mosi'} == 256) {
                    print sprintf('%02X', $transaction->{'miso'});
                } else {
                    print sprintf('%02X', $transaction->{'mosi'});
                }
            }
        }
        print "\n";
    }
    exit;
}