#!/usr/bin/perl

=head1 saleae-dump.pl

saleae-dump.pl - process data from Saleae csv dumps

=head1 SYNOPSIS

./saleae-dump.pl [options] [file]

    Options (UART):
        --linebreak|lb|l=string
        --breakline|bl|b=string

=head1 OPTIONS

=over 2

=item B<--linebreak|lb|l>

Insert "\n" after every occurence of the string.

=item B<--breakline|lb|l>

Insert "\n" after every occurence of the string.

=back

=head1 DESCRIPTION

This script will take a .csv from Saleae and convert it to something 
useful - like a stream of hex values. Right now it recognises the data 
format by looking at the first line of the file.
B<The source CSV needs to be in HEX format> selected in the Analyzer 
settings in Saleae Logic software.
The data is printed to stdout in hex as a string of [0-9A-F]{2}.

=head2 SPI

The format:
 Time [s],Packet ID,MOSI,MISO
 0.000000000000000,0,0x9F,0x00
 0.000001660000000,0,0xFF,0x1F
 0.000003360000000,0,0xFF,0x06

The Packet ID field is important as it separates SPI transactions. The 
protocol is 'speak when spoken to' by the master, and the transactions are 
separated by a state of /CS line (I haven't checked if Saleae does it 
properly). Using Packet ID fields we are able to display command-response 
pairs.

There is no way to determine which byte is the last byte of a command (on 
MOSI, master out slave in) line, the idle state is high so Saleae will 
interpret it as 0xFF. The same goes for the MISO (master in slave out) - 
there is no clear distinction as to where the response starts. We also know
that only one line is active at a time - and it does happen, depending on 
the wiring, that signals cross over between channels (that is, clock pulses 
can be seen on an idle line) and be interpreted by Saleae as valid bits. 

The active state (that is, commands being either read by slave or sent by 
it) is determined by the clock line (bits are being read on the line 
transition, usually on the leading edge) so Saleae is able to determine 
when 0xFF is a transmission or an idle (high) state.

This script will dump the data in two ways:
 - grouped in command-response sets,
 - whole stream of data from MISO

Since idle bytes on both lines are 0xFF and can pick up noise from other 
lines, as mentioned above, we will:
 - ignore MISO from the start of a packet until 0xFF - this is a first 
   attempt assumption and is most likely wrong;
 - ignore MOSI after the first 0xFF.

 This applies to both modes (we want MISO stream to be free of noise).

=head2 UART

The format:
 Time [s],Value,Parity Error,Framing Error
 6.880548088000000,0x16,,
 6.881669188000000,0x73,,
 6.882801980000000,0x39,,

The format is simple enough, so it's just a matter of merging the bytes 
into one string. We rely on Saleae to do its job.

=head2 i2c

The format:
 Time [s],Packet ID,Address,Data,Read/Write,ACK/NAK
 0.016978560000000,0,0x39,0xAE,Write,ACK
 0.017197840000000,1,0x39,0x20,Read,NAK
 0.017439200000000,2,0x39,0xFC,Write,ACK

The script will group bytes written and read in one line per transaction 
type, dropping 0x:

 Write to  0x39: AE
 Read from 0x39: 20
 Write to  0x39: FC
 Read from 0x39: 1C 0B 13 1C 1C 0B 0E 1E 1B 09 11 1E

=cut

use strict;
use warnings;
use v5.014;
use Getopt::Long;
use Pod::Usage;

$| = 1;
my $bl = 0;
my $lb = 0;
my $help = 0;

GetOptions(
    'linebreak|lb=s' => \$lb,
    'breakline|bl=s' => \$bl,
    'help' => \$help,
) or pod2usage(2);
pod2usage(1) if $help;

my $header = <>;
spi() if ($header =~ /MOSI/);
uart() if ($header =~ /Parity Error,Framing Error/);
i2c() if ($header =~ /Address,Data,Read/);

die "Header format not recognised: $header\n";

sub i2c {
    my ($transactions, @packets, $packets);

    while(<>) {
        chomp;
        my ($ts, $packetId, $address, $data, $read, $ack) = split(/,/);
        $address =~ s/0x(..)/$1/;
        $data =~ s/0x(..)/$1/;
        $read = $read =~ /Read/ ? 'Read from 0x' : 'Write to  0x';

        # This is a Perl hack to make an unique list
        $packets->{$packetId} = 1;

        push(@{$transactions->{$packetId}}, { 
            address => $address, data => $data, read => $read, ack => $ack
        });
    }
    
    @packets = sort ({$a <=> $b} keys(%$packets));

    for my $packetId (@packets) {
        for my $transaction (@{$transactions->{$packetId}}) {
            state $lastType;
            if ($lastType ne $transaction->{'read'}) {
                print "\n$transaction->{'read'}$transaction->{'address'}: ";
                $lastType = $transaction->{'read'};
            } 
            
            print "$transaction->{'data'} ";
        }
    }
}

sub uart {
    my $output;
    while(<>) {
        chomp;
        my ($ts, $value, $parity, $framing) = split(/,/);
        $value =~ s/0x(..)/$1/;
        $output .= $value;
    }

    if ($bl) {
        $output =~ s/$bl/\n$bl/gm;
    }

    if ($lb) {
        $output =~ s/$lb/$lb\n/gm;
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