#!/usr/bin/env perl

use strict;
use warnings;
use v5.014;
use Getopt::Long;
use Pod::Usage;
use Data::Dumper;

$| = 1;

my $csvfn = $ARGV[0];
open (my $csvfh, '<', $csvfn);

my @transactions;
my @lines = <$csvfh>;
chomp @lines;
my $length = @lines;

for (my $id = 0; $id < $length; $id++) {
    my ($ts, undef, $data) = split(/,/, $lines[$id]);
    if ($data =~ /PID (IN|OUT)/) {
        my $direction = $data =~ /IN/ ? ' IN' : 'OUT';
        my $byteBuf;
        $id++;
        last unless ($lines[$id]);

        ($ts, undef, $data) = split(/,/, $lines[$id]);
        my ($address, $endpoint) = split(/ /, $data);
        $address =~ s/Address=0x(.*)/$1/;
        $endpoint =~ s/Endpoint=0x(.*)/$1/;
        do {
            $id++;
            last unless ($lines[$id]);
            ($ts, undef, $data) = split(/,/, $lines[$id]);
        } while !($data =~ /\AByte/);

        while ($data =~ /\AByte/) {
            my (undef, $byte) = split(/ /, $data);
            $byte =~ s/0x//;
            $byteBuf .= $byte;
            $id++;
            ($ts, undef, $data) = split(/,/, $lines[$id]);
        }

        push(@transactions, {
            ts => sprintf("%.2f", $ts),
            direction => $direction, 
            address => $address, 
            endpoint => $endpoint,
            bytes => $byteBuf,
        });
    }
}

for (@transactions) {
    say "$_->{ts}: $_->{direction}, Address: $_->{address}, Endpoint: $_->{endpoint}";
    say $_->{bytes};
}

