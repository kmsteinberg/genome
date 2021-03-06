#!/usr/bin/env genome-perl

use strict;
use warnings;

BEGIN {
    $ENV{UR_DBI_NO_COMMIT} = 1;
    $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
};

use above "Genome";
use Test::More tests => 13;

use_ok('Genome::Model::Tools::DetectVariants2::Result::Manual');

my $test_base_dir = File::Temp::tempdir('DetectVariants2-Result-ManualXXXXX', CLEANUP => 1, TMPDIR => 1);

my $test_bed_file = &setup_test_bed_file($test_base_dir);
my $test_samtools_file = &setup_test_samtools_file($test_base_dir);

my $reference = Genome::Model::Build::ReferenceSequence->get_by_name('GRCh37-lite-build37');

my $sample = Genome::Sample->create(
    name => 'test_sample_for_manual_result',
);

my $bed_result = Genome::Model::Tools::DetectVariants2::Result::Manual->create(
    original_file_path => $test_bed_file,
    variant_type => 'snv',
    sample_id => $sample->id,
    reference_build_id => $reference->id,
    format => 'bed',
);
isa_ok($bed_result, 'Genome::Model::Tools::DetectVariants2::Result::Manual', 'created manual result for a bed file');
my $bed_output = $bed_result->output_dir;

my $bed_hq_file = join('/', $bed_output, 'snvs.hq');
my $bed_hq_bed_file = $bed_hq_file . '.bed';

ok(-e $bed_hq_file, 'created hq file for bed');
ok(-e $bed_hq_bed_file, 'created hq.bed file for bed');

my $diff;
$diff = Genome::Sys->diff_file_vs_file($bed_hq_file, $test_bed_file);
ok(!$diff, 'bed file is copied straight as "detector-style" file') or diag('diff: ' . $diff);
$diff = Genome::Sys->diff_file_vs_file($bed_hq_bed_file, $test_bed_file);
ok(!$diff, 'hq.bed file is the same as the original bed file') or diag('diff: ' . $diff);

my %params = (
    original_file_path => $test_samtools_file,
    variant_type => 'snv',
    sample_id => $sample->id,
    reference_build_id => $reference->id,
    format => 'samtools',
);

my $samtools_result = Genome::Model::Tools::DetectVariants2::Result::Manual->create(
    %params,
);
isa_ok($samtools_result, 'Genome::Model::Tools::DetectVariants2::Result::Manual', 'created manual result for a samtools file');
my $samtools_output = $samtools_result->output_dir;

my $samtools_hq_file = join('/', $samtools_output, 'snvs.hq');
my $samtools_hq_bed_file = $samtools_hq_file . '.bed';

ok(-e $samtools_hq_file, 'created hq file for samtools');
ok(-e $samtools_hq_bed_file, 'created hq.bed file for samtools');

$diff = Genome::Sys->diff_file_vs_file($samtools_hq_file, $test_samtools_file);
ok(!$diff, 'samtools file is copied straight as "detector-style" file') or diag('diff: ' . $diff);
$diff = Genome::Sys->diff_file_vs_file($samtools_hq_bed_file, $test_bed_file);
ok(!$diff, 'hq.bed file is appropriately converted from samtools file') or diag('diff: ' . $diff);

is($samtools_result->file_content_hash, Genome::Sys->md5sum($test_samtools_file), 'created hash correctly');

my $get_test = Genome::Model::Tools::DetectVariants2::Result::Manual->get_or_create(
    %params
);
is($get_test, $samtools_result, 'got same result on subsequent get_or_create call');

sub setup_test_bed_file {
    my $dir = shift;

    my $file = join('/', $dir, 'bed.snvs.hq');
    Genome::Sys->write_file($file, <<BEDFILE
1	554425	554426	C/G	5	2
1	3704867	3704868	C/T	30	1
BEDFILE
    );

    return $file;
}

sub setup_test_samtools_file {
    my $dir = shift;

    my $file = join('/', $dir, 'sam.snvs.hq');
    Genome::Sys->write_file($file, <<SAMTOOLSFILE
1	554426	C	G	5	5	0	2	G	'
1	3704868	C	T	30	30	37	1	t	;
SAMTOOLSFILE
    );
}
