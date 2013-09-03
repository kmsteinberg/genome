package Genome::Model::Tools::Annotate::TranscriptVariants::Version3;

use strict;
use warnings;

use Data::Dumper;
use Genome;
use File::Temp;
use List::Util qw/ max min /;
use List::MoreUtils qw/ uniq /;
use Bio::Seq;
use Bio::Tools::CodonTable;
use DateTime;
use Carp;

UR::Object::Type->define(
    class_name => __PACKAGE__,
    is => 'Genome::Model::Tools::Annotate::TranscriptVariants::Base',

    has => [
        reference_sequence_id => {
            is => "Text",
        },
        eids => {
            is_transient => 1,
            is_optional => 1,
            doc => "Temporary variable used for intermediate calculation.",
        },
    ],

    doc => q(Do proper intersections between variations and transcript structures by considering both entities' start and stop positions rather than just the start position of the variation.),

);


sub transcript_status_priorities {
    return (
        reviewed            => 1,
        validated           => 2,
        provisional         => 3,
        predicted           => 4,
        putative            => 4,
        model               => 5,
        inferred            => 6,
        known               => 7,
        annotated           => 8,
        known_by_projection => 9,
        novel               => 10,
        unknown             => 11,
    );
}


sub is_mitochondrial {
    my ($self, $chrom_name) = @_;

    #we use the mitochondrial_codon_translator if the chromosome is either the M or MT.  Everything else should use the normal translator
    return $chrom_name =~ /^MT?/;
}


sub cache_gene_names {
    my $self = shift;

    if (!defined $self->{_cached_chromosome}) {
        Genome::ExternalGeneId->get(
            data_directory => $self->data_directory,
            reference_build_id => $self->reference_sequence_id,
            id_type => "ensembl",
        );
        Genome::ExternalGeneId->get(
            data_directory => $self->data_directory,
            reference_build_id => $self->reference_sequence_id,
            id_type => "ensembl_default_external_name",
        );
        Genome::ExternalGeneId->get(
            data_directory => $self->data_directory,
            reference_build_id => $self->reference_sequence_id,
            id_type => "ensembl_default_external_name_db",
        );
    }
}

# Annotates all transcripts affected by a variant
# Corresponds to none filter in Genome::Model::Tools::Annotate::TranscriptVariants
sub transcripts {
    my ($self, %variant) = @_;

    if (!defined $self->{_cached_chromosome} or $self->{_cached_chromosome} ne $variant{chromosome_name}) {
        Genome::InterproResult->unload();
        $self->transcript_structure_class_name->unload();

        Genome::InterproResult->get(
            data_directory => $self->data_directory,
            chrom_name => $variant{chromosome_name},
        );

        $self->cache_gene_names();
        $self->{_cached_chromosome} = $variant{chromosome_name};
    }

    my $variant_start = $variant{'start'};
    my $variant_stop = $variant{'stop'};

    $variant{'type'} = uc($variant{'type'});

    # Make sure variant is set properly
    unless (defined($variant_start) and defined($variant_stop) and defined($variant{variant})
            and defined($variant{reference}) and defined($variant{type})
            and defined($variant{chromosome_name}))
    {
        print Dumper(\%variant);
        confess "Variant is not fully defined: chromosome name, start, stop, variant, reference, and type must be defined.\n";
    }

    # Make sure the sequence on the variant is valid. If not, display a warning and set transcript error
    unless ($self->is_valid_variant(\%variant)) {
        $self->warning_message("The sequence on this variant is not valid! Reference: $variant{reference} Variant: $variant{variant}");

        return { transcript_error => 'invalid_sequence_on_variant' }
    }

    my $windowing_iterator = $self->{'_windowing_iterator'};
    unless ($windowing_iterator) {
        $windowing_iterator = $self->{'_windowing_iterator'} = $self->_create_iterator_for_variant_intersection();
    }
    my $crossing_substructures = $windowing_iterator->(\%variant);

    # Hack to support the old behavior of only annotating against the first structure
    # of a transcript.  We need to keep a list of all the other structures for later
    # listing them in the deletions column of the output
#    my %transcript_substructures;
#    {
#        my @less;
#        foreach my $substructure ( @$crossing_substructures ) {
#            my $transcript_id = $substructure->transcript_transcript_id;
#            if ($substructure->{'structure_start'} <= $variant_start and $substructure->{'structure_stop'} >= $variant_start) {
#                push @less, $substructure;
#            }
#            $transcript_substructures{$transcript_id} ||= [];
#            push @{$transcript_substructures{$transcript_id}}, $substructure;
#        }
#        $crossing_substructures = \@less;
#    }

    return unless @$crossing_substructures;

    my @annotations;
    my $variant_checked = 0;

    Genome::Model::Tools::Annotate::LookupConservationScore->class(); # get it loaded so we can call lookup_sequence

    foreach my $substruct ( @$crossing_substructures ) {
        # If specified, check that the reference sequence stored on the variant correctly matches our reference
        if ($self->check_variants and not $variant_checked) {
            unless ($variant{reference} eq '-') {
                my $chrom = $variant{chromosome_name};
                my $species = $substruct->transcript_species;
                my $ref_seq = Genome::Model::Tools::Sequence::lookup_sequence(
                                  chromosome => $chrom,
                                  start => $variant_start,
                                  stop => $variant_stop,
                                  species => $species,
                              );

                unless ($ref_seq eq $variant{reference}) {
                    $self->warning_message("Sequence on variant on chromosome $chrom between $variant_start and $variant_stop does not match $species reference!");
                    $self->warning_message("Variant sequence : " . $variant{reference});
                    $self->warning_message("$species reference : " . $ref_seq);
                    return;
                }
                $variant_checked = 1;
            }
        }

        my %annotation = $self->_transcript_substruct_annotation($substruct, %variant) or next;

#        # Continuation of the hack above about annotating a deletion
#        if ($variant{'type'} eq 'DEL') {
#            my @del_strings = map { $_->structure_type . '[' . $_->structure_start . ',' . $_->structure_stop . ']' }
#                                  @{$transcript_substructures{$substruct->transcript_transcript_id}};
#            $annotation{'deletion_substructures'} = '(deletion:' . join(', ', @del_strings) . ')';
#        }
        push @annotations, \%annotation;
    }
    return @annotations;
}

# Annotates a single transcript-substructure/variant pair
sub _transcript_substruct_annotation {
    my ($self, $substruct, %variant) = @_;
    # Just an FYI... using a copy of variant here instead of a reference prevents reverse complementing
    # the variant twice, which would occur if the variant happened to touch two reverse stranded transcripts

    # TODO This will need to be coupled with splitting up a variant so it doesn't extend beyond a structure
    # TODO There are various hacks in intron and exon annotation to fix the side effects of only annotating the
    # structure at variant start position that will also need removed once this is fixed, and there is still
    # a definite bias for variant start over variant stop throughout this module

#    # If the variant extends beyond the current substructure, it needs to be resized
#    if ($variant{start} < $substruct->{structure_start}) {
#       my $diff = $substruct->{structure_start} - $variant{start};
#       $variant{start} = $variant{start} + $diff;
#       unless ($variant{type} eq 'DEL') {
#           $variant{variant} = substr($variant{variant}, $diff);
#       }
#       unless ($variant{type} eq 'INS') {
#           $variant{reference} = substr($variant{reference}, $diff);
#       }
#    }
#    elsif ($variant{stop} > $substruct->{structure_stop}) {
#        my $diff = $variant{stop} - $substruct->{structure_stop};
#        $variant{stop} = $variant{stop} - $diff;
#        unless ($variant{type} eq 'DEL') {
#            $variant{variant} = substr($variant{variant}, 0, length($variant{variant}) - $diff);
#        }
#        unless ($variant{type} eq 'INS') {
#            $variant{reference} = substr($variant{reference}, 0, length($variant{reference}) - $diff);
#        }
#    }

    # All sequence stored on the variant is forward stranded and needs to be reverse
    # complemented if the transcript is reverse stranded.
    my $strand = $substruct->transcript_strand;
    if ($strand eq '-1') {
        my ($new_variant, $new_reference);
        unless ($variant{type} eq 'DEL') {
            $new_variant = $self->reverse_complement($variant{variant});
            $variant{variant} = $new_variant;
        }
        unless ($variant{type} eq 'INS') {
            $new_reference = $self->reverse_complement($variant{reference});
            $variant{reference} = $new_reference;
        }
    }

    my $structure_type = $substruct->structure_type;
    my $method = '_transcript_annotation_for_' . $structure_type;
    my %structure_annotation = $self->$method(\%variant, $substruct) or return;

    my $conservation = $self->_ucsc_conservation_score(\%variant, $substruct);

    my $gene_name = $substruct->transcript_gene_name;
    my $dumper_string = $substruct->id;
    unless ($gene_name) {
        $self->warning_message("Gene name missing for substruct: $dumper_string");
        my $gene = Genome::Gene->get(data_directory => $substruct->data_directory,
                                     id => $substruct->transcript_gene_id,
                                     reference_build_id => $self->reference_sequence_id);
        $gene_name = $gene->name;
    }

    my ($default_gene_name, $ensembl_gene_id, $gene_name_source);
    unless ($self->eids) {
        my %new;
        $self->eids(\%new);
    }
    if ($self->eids and $self->eids->{$substruct->transcript_gene_id}) {
        ($default_gene_name,$ensembl_gene_id,$gene_name_source) = split(/,/, $self->eids->{$substruct->transcript_gene_id});
    }
    else {
        my @e1 = Genome::ExternalGeneId->get(data_directory => $substruct->data_directory,
            gene_id => $substruct->transcript_gene_id,
            reference_build_id => $self->reference_sequence_id,
            id_type => "ensembl_default_external_name");
        if ($e1[0]) {
            $default_gene_name = $e1[0]->id_value;
        }
        unless ($default_gene_name) {
            $self->warning_message("Ensembl gene name missing for substruct: $dumper_string");
            $default_gene_name = "Unknown";
        }
        my @e2 = Genome::ExternalGeneId->get(data_directory => $substruct->data_directory,
            gene_id => $substruct->transcript_gene_id,
            reference_build_id => $self->reference_sequence_id,
            id_type => "ensembl");
        if ($e2[0]) {
            $ensembl_gene_id = $e2[0]->id_value;
        }
        unless ($ensembl_gene_id) {
            $self->warning_message("Ensembl stable gene id missing for substruct: $dumper_string");
            $ensembl_gene_id = "Unknown";
        }
        my @e3 = Genome::ExternalGeneId->get(data_directory => $substruct->data_directory,
            gene_id => $substruct->transcript_gene_id,
            reference_build_id => $self->reference_sequence_id,
            id_type => "ensembl_default_external_name_db");
        if ($e3[0]) {
            $gene_name_source = $e3[0]->id_value;
        }
        unless ($gene_name_source) {
            $self->warning_message("Ensembl gene name source missing for substruct: $dumper_string");
            $gene_name_source = "Unknown";
        }
        $self->eids->{$substruct->transcript_gene_id} = join(',',$default_gene_name, $ensembl_gene_id, $gene_name_source);
    }

    return (
        %structure_annotation,
        transcript_error => $substruct->transcript_transcript_error,
        transcript_name => $substruct->transcript_transcript_name,
        transcript_status => $substruct->transcript_transcript_status,
        transcript_source => $substruct->transcript_source,
        transcript_species=> $substruct->transcript_species,
        transcript_version => $substruct->transcript_version,
        strand => $strand,
        gene_name  => $gene_name,
        amino_acid_length => $substruct->transcript_amino_acid_length,
        ucsc_cons => $conservation,
        default_gene_name => $default_gene_name,
        gene_name_source => $gene_name_source,
        ensembl_gene_id => $ensembl_gene_id,
    );
}

sub _transcript_annotation_for_cds_exon {
    my ($self, $variant, $structure) = @_;


    # If the variant continues beyond the stop position of the exon, then the variant sequence
    # needs to be modified to stop at the exon's stop position. The changes after the exon's stop
    # affect the intron, not the coding sequence, and shouldn't be annotated here. Eventually,
    # it's possible that variants may always be split up so they only touch one structure, but for
    # now this will have to do.
    # TODO This can be removed once variants spanning structures are handled properly
    unless ($self->{'get_frame_shift_sequence'}) {
        # If we're inspecting the entire sequence, don't chop the variant down...
        if ($variant->{stop} > $structure->structure_stop and $variant->{type} eq 'DEL') {
            my $bases_beyond_stop = $variant->{stop} - $structure->structure_stop;
            my $new_variant_length = (length $variant->{reference}) - $bases_beyond_stop;
            $variant->{reference} = substr($variant->{reference}, 0, $new_variant_length);
            $variant->{stop} = $variant->{stop} - $bases_beyond_stop;
        }
    }

    my $coding_position = $self->_determine_coding_position($variant, $structure);

    # Grab and translate the codons affected by the variation
    my ($original_seq, $mutated_seq, $protein_position) = $self->_get_affected_sequence($structure, $variant);
    my $chrom_name = $structure->transcript_chrom_name;
    my $original_aa = $self->translate($original_seq, $chrom_name);
    my $mutated_aa = $self->translate($mutated_seq, $chrom_name);

    my ($trv_type, $protein_string);
    my ($reduced_original_aa, $reduced_mutated_aa, $offset) = ($original_aa, $mutated_aa, 0);
    if ($variant->{type} eq 'INS') {
        ($reduced_original_aa, $reduced_mutated_aa, $offset) = $self->_reduce($original_aa, $mutated_aa);
        $protein_position += $offset;

        my $indel_size = length $variant->{variant};
        if ($indel_size % 3 == 0) {
            $trv_type = "in_frame_" . lc $variant->{type};
            $protein_string = "p." . $reduced_original_aa . $protein_position . $trv_type . $reduced_mutated_aa;
        }
        else {
            # In this case, the inserted sequence does not change the amino acids on either side of it (if original is
            # MT and mutated is MRPT, then original sequence is reduced to nothing). The first changed amino acid should
            # be set to the first original amino acid that does not occur in the mutated sequence moving 5' to 3'.
            # In the above example, first changed amino acid would be T.
            $trv_type = "frame_shift_" . lc $variant->{type};
            if ($self->{get_frame_shift_sequence}) {
                my $aa_after_indel = $self->_apply_indel_and_translate($structure, $variant);
                $protein_string = "p." . $aa_after_indel . $protein_position . "fs";
            }
            else {
                if ($reduced_original_aa eq "") {
                    $protein_position -= $offset;
                    for (my $i = 0; $i < (length $original_aa); $i++) {
                        my $original = substr($original_aa, $i, 1);
                        my $mutated = substr($mutated_aa, $i, 1);
                        $protein_position++ and next if $original eq $mutated;
                        $reduced_original_aa = $original;
                        last;
                    }

                    # If the original sequence is STILL reduced to nothing (insertion could occur after original amino acids),
                    # then just use the last amino acid in the unreduced original sequence
                    $reduced_original_aa = substr($original_aa, -1) if $reduced_original_aa eq "";
                }

                $reduced_original_aa = substr($reduced_original_aa, 0, 1);
                $protein_string = "p." . $reduced_original_aa . $protein_position . "fs";
            }
        }
    }
    elsif ($variant->{type} eq 'DEL') {
        ($reduced_original_aa, $reduced_mutated_aa, $offset) = $self->_reduce($original_aa, $mutated_aa);
        $protein_position += $offset;

        my $indel_size = length $variant->{reference};
        if ($indel_size % 3 == 0) {
            $trv_type = "in_frame_" . lc $variant->{type};
            $protein_string = "p." . $reduced_original_aa . $protein_position . $trv_type;
            $protein_string .= $reduced_mutated_aa if defined $reduced_mutated_aa;
        }
        else {
            $trv_type = "frame_shift_" . lc $variant->{type};
            if ($self->{get_frame_shift_sequence}) {
                my $aa_after_indel = $self->_apply_indel_and_translate($structure, $variant);
                $protein_string = "p." . $aa_after_indel . $protein_position . "fs";
            }
            else {
                $reduced_original_aa = substr($reduced_original_aa, 0, 1);
                $protein_string = "p." . $reduced_original_aa . $protein_position . "fs";
            }
        }
    }
    elsif ($variant->{type} eq 'DNP' or $variant->{type} eq 'SNP') {
        if (!defined $mutated_aa or !defined $original_aa) {
            $trv_type = 'silent';
            $protein_string = "NULL";
        }
        elsif ($mutated_aa eq $original_aa) {
            $trv_type = 'silent';
            $protein_string = "p." . $original_aa . $protein_position;
        }
        else {
            ($reduced_original_aa, $reduced_mutated_aa, $offset) = $self->_reduce($original_aa, $mutated_aa);
            $protein_position += $offset;

            if (index($reduced_mutated_aa, '*') != -1) {
                $trv_type = 'nonsense';
            }
            elsif (index($reduced_original_aa, '*') != -1) {
                $trv_type = 'nonstop';
            }
            else {
                $trv_type = 'missense';
            }
            $protein_string = "p." . $reduced_original_aa . $protein_position . $reduced_mutated_aa;
        }
    }
    else {
        $self->warning_message("Unknown variant type " . $variant->{type} .
                " for variant between " . $variant->{start} . " and " . $variant->{stop} .
                " on transcript " . $structure->transcript_transcript_name .
                ", cannot continue annotation of coding exon");
        return;
    }

    # Need to create an amino acid change string for the protein domain method
    my ($protein_domain, $all_protein_domains) = $self->_protein_domain(
        $structure, $variant, $protein_position
    );

    return (
            c_position => "c." . $coding_position,
            trv_type => $trv_type,
            amino_acid_change => $protein_string,
            domain => $protein_domain,
            all_domains => $all_protein_domains,
           );
}


# Taken from Genome::Transcript
# Given a version and species, find the imported reference sequence build
sub get_reference_build_for_transcript {
    my($self, $structure) = @_;

    my ($version) = $structure->transcript_version =~ /^\d+_(\d+)[a-z]/;
    my $species = $structure->transcript_species;

    unless ($self->{'_reference_builds'}->{$version}->{$species}) {
        my $build = Genome::Model::Build->get($self->reference_sequence_id);
        confess "Could not get build version $version" unless $build;

        $self->{'_reference_build'}->{$version}->{$species} = $build;
    }
    return $self->{_reference_build}->{$version}->{$species};
}


sub bound_relative_stop {
    my ($self, $relative_stop, $limit) = @_;

    #it is possible that the variant goes off the end of the transcript.  In this case,
    #we need to adjust the relative stop.

    return min($relative_stop, $limit);
}

1;

=pod
=head1 Name

Genome::Transcript::VariantAnnotator

=head1 Synopsis

Given a variant, all transcripts affected by that variant are annotated and returned

=head1 Usage

# Variant file tab delimited, columns are chromosome, start, stop, reference, variant
# Need to infer variant type (SNP, DNP, INS, DEL) as well
my $variant_file = variants.tsv;
my @headers = qw/ chromosome_name start stop reference variant /;
my $reader = Genome::Utility::IO::SeparatedValueReader->create(
        input => $variant_file,
        headers => \@headers,
        separator => "\t",
        is_regex => 1,
        );

my $model = Genome::Model->get(name => 'NCBI-human.combined-annotation');
my $build = $model->build_by_version('54_36p');
my $iterator = $build->transcript_iterator;
my $window = Genome::Utility::Window::Transcript->create(
        iterator => $iterator,
        range => 50000,
        );
my $annotator = Genome::Transcript::VariantAnnotator->create(
        transcript_window => $window
        );

while (my $variant = $reader->next) {
    my @annotations = annotator->transcripts($variant);
}

=head1 Methods

=head2 transcripts

=over

=item I<Synopsis>   gets all annotations for a variant

=item I<Arguments>  variant (hash; see 'Variant Properites' below)

=item I<Returns>    annotations (array of hash refs; see 'Annotation' below)

=back

=head2 prioritized_transcripts

=over

=item I<Synopsis>   Gets one prioritized annotation per gene for a variant(snp or indel)

    =item I<Arguments>  variant (hash; see 'Variant properties' below)

    =item I<Returns>    annotations (array of hash refs; see 'Annotation' below)

    =back

    =head2 prioritized_transcript

    =over

    =item I<Snynopsis>  Gets the highest priority transcript affected by variant

    =item I<Arguments>  variant (hash, see 'Variant properties' below)

    =item I<Returns>    annotations (array of hash refs; see 'Annotation' below)

    =back

    =head1 Variant Properties

    =over

    =item I<chromosome_name>  The chromosome of the variant

    =item I<start>            The start position of the variant

    =item I<stop>             The stop position of the variant

    =item I<variant>          The snp base

    =item I<reference>        The reference base at the position

    =item I<type>             snp, dnp, ins, or del

    =back

    =head1 Annotation Properties

    =over

    =item I<transcript_name>    Name of the transcript

    =item I<transcript_source>  Source of the transcript

    =item I<strand>             Strand of the transcript

    =item I<c_position>         Relative position of the variant

    =item I<trv_type>           Called Classification of variant

=item I<priority>           Priority of the trv_type (only from get_prioritized_annotations)

    =item I<gene_name>          Gene name of the transcript

    =item I<intensity>          Gene intenstiy

    =item I<detection>          Gene detection

    =item I<amino_acid_length>  Amino acid length of the protein

    =item I<amino_acid_change>  Resultant change in amino acid in snp is in cds_exon

    =item I<variations>         Hashref w/ keys of known variations at the variant position

    =item I<type>               snp, ins, or del

    =back

    =head1 See Also

    B<Genome::Model::Command::Report>

    =head1 Disclaimer

    Copyright (C) 2008 Washington University Genome Sequencing Center

    This module is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY or the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

=head1 Author(s)

    Core Logic:

    B<Xiaoqi Shi> I<xshi@genome.wustl.edu>

    Optimization:

    B<Eddie Belter> I<ebelter@watson.wustl.edu>

    B<Gabe Sanderson> l<gsanders@genome.wustl.edu>

    B<Adam Dukes l<adukes@genome.wustl.edu>

    B<Brian Derickson l<bdericks@genome.wustl.edu>

    =cut

#$HeadURL$
#$Id$
