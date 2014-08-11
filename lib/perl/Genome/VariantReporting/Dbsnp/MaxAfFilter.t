#!/usr/bin/env genome-perl

BEGIN { 
    $ENV{UR_DBI_NO_COMMIT} = 1;
    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
}

use strict;
use warnings;

use above "Genome";
use Test::More;
use Test::Exception;
use Genome::File::Vcf::Entry;

my $pkg = "Genome::VariantReporting::Dbsnp::MaxAfFilter";
use_ok($pkg);
my $factory = Genome::VariantReporting::Framework::Factory->create();
isa_ok($factory->get_class('filters', $pkg->name), $pkg);

subtest "One passes, one fails" => sub {
    my $filter = $pkg->create(
        max_af => ".1",
    );
    lives_ok(sub {$filter->validate}, "Filter validates ok");

    my $entry = create_entry('['.join(",",0.7,0.1,0.2).']');

    my %expected_return_values = (
        C => 1,
        G => 0,
    );
    is_deeply({$filter->filter_entry($entry)}, \%expected_return_values);
};

subtest "No frequency for allele" => sub {
    my $filter = $pkg->create(
        max_af => ".1",
    );
    lives_ok(sub {$filter->validate}, "Filter validates ok");

    my $entry = create_entry('['.join(",",0.7,".",".").']');

    my %expected_return_values = (
        C => 1,
        G => 1,
    );
    is_deeply({$filter->filter_entry($entry)}, \%expected_return_values);
};
subtest "No CAF for entry" => sub {
    my $filter = $pkg->create(
        max_af => ".1",
    );
    lives_ok(sub {$filter->validate}, "Filter validates ok");

    my $entry = create_entry();

    my %expected_return_values = (
        C => 1,
        G => 1,
    );
    is_deeply({$filter->filter_entry($entry)}, \%expected_return_values);
};

subtest "Malformed CAF" => sub {
    my $filter = $pkg->create(
        max_af => ".1",
    );
    lives_ok(sub {$filter->validate}, "Filter validates ok");

    my $entry = create_entry(".");

    throws_ok(sub {$filter->filter_entry($entry)}, qr(Invalid CAF entry));
};

sub create_vcf_header {
    my $header_txt = <<EOS;
##fileformat=VCFv4.1
##INFO=<ID=CAF,Number=.,Type=Float,Description="CAF">
#CHROM	POS	ID	REF	ALT	QUAL	FILTER	INFO
EOS
    my @lines = split("\n", $header_txt);
    my $header = Genome::File::Vcf::Header->create(lines => \@lines);
    return $header
}

sub create_entry {
    my $caf = shift;
    my @fields = (
        '1',            # CHROM
        10,             # POS
        '.',            # ID
        'A',            # REF
        'C,G',            # ALT
        '10.3',         # QUAL
        'PASS',         # FILTER
    );
    if (defined $caf) {
        push @fields, "CAF=$caf";
    }
    else {
        push @fields, ".";
    }

    my $entry_txt = join("\t", @fields);
    my $entry = Genome::File::Vcf::Entry->new(create_vcf_header(), $entry_txt);
    return $entry;
}
done_testing;

