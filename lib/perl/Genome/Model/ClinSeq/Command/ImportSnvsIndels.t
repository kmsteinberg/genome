#!/usr/bin/env genome-perl

#Written by Malachi Griffith

use strict;
use warnings;
use File::Basename;
use Cwd 'abs_path';

BEGIN {
  $ENV{UR_DBI_NO_COMMIT} = 1;
  $ENV{UR_USE_DUMMY_AUTOGENERATED_IDS} = 1;
  $ENV{NO_LSF} = 1;
};

use above "Genome";
use Test::More tests=>8; #One per 'ok', 'is', etc. statement below
use Genome::Model::ClinSeq::Command::ImportSnvsIndels;
use Data::Dumper;

use_ok('Genome::Model::ClinSeq::Command::ImportSnvsIndels') or die;

#Define the test where expected results are stored
my $expected_output_dir = $ENV{"GENOME_TEST_INPUTS"} . "/Genome-Model-ClinSeq-Command-ImportSnvsIndels/2013-02-26/";
ok(-e $expected_output_dir, "Found test dir: $expected_output_dir") or die;

#Create a temp dir for results
my $temp_dir = Genome::Sys->create_temp_directory();
ok($temp_dir, "created temp directory: $temp_dir") or die;

#Get a wgs somatic variation build
my $wgs_build_id = 129396794;
my $wgs_build = Genome::Model::Build->get($wgs_build_id);
ok ($wgs_build, "obtained wgs somatic variation build from db for id: $wgs_build_id") or die;

my $exome_build_id = 129396799;
my $exome_build = Genome::Model::Build->get($exome_build_id);
ok ($exome_build, "obtained exome somatic variation build from db for id: $exome_build_id") or die;

#Create import-snvs-indels command and execute
#genome model clin-seq import-snvs-indels --outdir=/tmp/ --wgs-build=129396794 --exome-build=129396799  --filter-mt
my $cancer_annotation_db = Genome::Db->get("tgi/cancer-annotation/human/build37-20130401.1"); # cancer_annotation_db => $cancer_annotation_db
my $import_snvs_indels_cmd = Genome::Model::ClinSeq::Command::ImportSnvsIndels->create(outdir=>$temp_dir, wgs_build=>$wgs_build, exome_build=>$exome_build, filter_mt=>1, cancer_annotation_db => $cancer_annotation_db);
$import_snvs_indels_cmd->queue_status_messages(1);
my $r1 = $import_snvs_indels_cmd->execute();
is($r1, 1, 'Testing for successful execution.  Expecting 1.  Got: '.$r1);

#Dump the output to a log file
my @output1 = $import_snvs_indels_cmd->status_messages();
my $log_file = $temp_dir . "/ImportSnvsIndels.log.txt";
my $log = IO::File->new(">$log_file");
$log->print(join("\n", @output1));
ok(-e $log_file, "Wrote messages from import-snvs-indels to a log file: $log_file");

#The first time we run this we will need to save our initial result to diff against
#Genome::Sys->shellcmd(cmd => "cp -r -L $temp_dir/* $expected_output_dir");

#Perform a diff between the stored results and those generated by this test
my @diff = `diff -r -x '*.log.txt' $expected_output_dir $temp_dir`;
ok(@diff == 0, "Found only expected number of differences between expected results and test results")
or do {
  diag("expected: $expected_output_dir\nactual: $temp_dir\n");
  diag("differences are:");
  diag(@diff);
  my $diff_line_count = scalar(@diff);
  print "\n\nFound $diff_line_count differing lines\n\n";
  Genome::Sys->shellcmd(cmd => "rm -fr /tmp/last-import-snvs-indels-result/");
  Genome::Sys->shellcmd(cmd => "mv $temp_dir /tmp/last-import-snvs-indels-result");
};



