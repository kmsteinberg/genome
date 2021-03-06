package Genome::Model::ReferenceAlignment::Command::Downsample;

use strict;
use warnings;
use Genome;
use File::Basename;

class Genome::Model::ReferenceAlignment::Command::Downsample {
    is => 'Command::V2',
    doc => 'Downsample the merged bam for given model(s) into a new instrument data and a new model (or a model group).',
    has => [
        model_group => {
            is => 'Genome::ModelGroup',
            doc => 'Model-Group to operate on... provide this OR model',
            is_optional => 1,
            is_input => 1,
        },
        model => {
            is => 'Genome::Model',
            shell_args_position => 1,
            doc => 'Model to operate on... provide this OR model-group',
            is_optional => 1,
            is_input => 1,
        },
        coverage_in_gb => {
            is => 'Text',
            doc => "Set this to the amount of bases to lower the input to, in GB. 1.5 = 1,500,000,000 bases. Set this or ratio, not both.",
            is_optional => 1,
            is_input => 1,
        },
        coverage_in_ratio => {
            is => 'Text',
            doc => "Set this to the ratio reduction in bases, units should be 0 to 1, where 1 = 100% = whole bam. Set this or gb, not both.",
            is_optional => 1,
            is_input => 1,
        },
        random_seed => {
            is => 'Text',
            doc => 'Set this equal to the reported random seed to reproduce previous results',
            is_optional => 1,
        },
        _new_model => {
            is => 'Genome::Model',
            doc => 'The new model created with the downsampled instrument data assigned',
            is_optional => 1,
        },
        _new_model_group => {
            is => 'Genome::Modelgroup',
            doc => 'The new model group created with the downsampled instrument data assigned',
            is_optional => 1,
        },
    ],
};

sub help_detail {
    return <<EOS
    Downsample the merged bam for given model(s) into a new instrument data and a new model (or a model group).
EOS
}

sub execute {
    my $self = shift;

    unless($self->coverage_in_gb xor $self->coverage_in_ratio){
        die $self->error_message("You must either specify coverage_in_gb or coverage_in_ratio, not both.");
    }
    unless ($self->model xor $self->model_group) {
        die $self->error_message("You must either specify model or model_group, not both.");
    }

    if ($self->model) {
        return $self->_create_downsampled_model($self->model);
    }

    return $self->_create_downsampled_model_group($self->model_group);
}

# Given a model group, downsample each of the models within and add the new models to a new model group
sub _create_downsampled_model_group {
    my $self = shift;
    my $model_group = shift;

    my @models = $model_group->models;
    unless (@models) {
        die $self->error_message("Could not get any models for model group " . $model_group->id);
    }

    my @new_models;
    for my $model (@models) {
        unless ($self->_create_downsampled_model($model) ) {
            die $self->error_message("Could not create a downsampled model for input model " . $model->id);
        }

        my $new_model = $self->_new_model;
        unless ($new_model) {
            die $self->error_message("Failed to get new model for input model " . $model->id);
        }
        push @new_models, $new_model;
    }

    my $new_group_name = $model_group->name . ".downsampled";
    my $new_group = Genome::ModelGroup->create(name => $new_group_name);
    unless ($new_group) {
        die $self->error_message("Could not create new model group with the name $new_group_name");
    }
    print "Assigning " . scalar @new_models. " models\n";
    $new_group->assign_models(@new_models);
    print "The new model group is " . $new_group->id . " " . $new_group->name . "\n";

    $self->_new_model_group($new_group);

    return 1;
}

# Given a single model:
# 1) downsample the merged bam from the last succeeded build
# 2) import the downsampled bam into a new instrument data
# 3) create a new model with that instrument data assigned
sub _create_downsampled_model {
    my $self = shift;
    my $model = shift;

    unless($model){
        die $self->error_message("Could not locate model!");
    }
    my $build = $model->last_succeeded_build;
    unless($build){
        die $self->error_message("Could not locate a succeeded build for model: ".$model->id);
    }

    $self->status_message("Using Build: ".$build->id);

    my $bam_result = $build->merged_alignment_result;
    my $bam = $bam_result->bam_file;

    unless(-e $bam){
        die $self->error_message("Could not locate bam at: ". $bam);
    }

    my $downsample_ratio;
    if ($self->coverage_in_gb) {
        my $new_coverage = $self->coverage_in_gb * 1000000000;  #convert gigabases to bases

        my $total_readcount = $self->_get_readcount($bam);
        $self->status_message("Total read-count in the original bam: ".$total_readcount);

        #TODO this currently assumes homogenous read-length instrument-data
        my $read_length = $self->_get_readlength($model);
        $self->status_message("Read Length: ".$read_length);

        my $total_bases = $read_length * $total_readcount;
        $self->status_message("Total Bases: ".$total_bases);

        #Calculate downsample ratio by taking the ratio of desired coverage to the current total bases,
        # round to 5 decimal places
        $downsample_ratio = sprintf("%.5f", $new_coverage / $total_bases );
        unless($downsample_ratio < 1.0){
            die $self->error_message("The downsample ratio ended up being >= 1. You must specify a coverage_in_gb that is lower than the existing bam.");
        }
        $self->status_message("Downsample ratio = ".$downsample_ratio);
    }
    elsif ($self->coverage_in_ratio) {
            $downsample_ratio = $self->coverage_in_ratio;
    }

    #Place the output of the downsampling into temp
    my $temp = Genome::Sys->create_temp_file_path;

    #Get or create a random seed from combining PID and current time
    my $seed = (defined($self->random_seed)) ? $self->random_seed : ($$ + time);
    $self->status_message("Random Seed: ".$seed);

    my $ds_cmd = Genome::Model::Tools::Picard::Downsample->create(
        input_file => $bam,
        output_file => $temp,
        downsample_ratio => $downsample_ratio,
        random_seed => $seed,
        maximum_memory => 16,
    );
    unless($ds_cmd->execute){
        die $self->error_message("Could not complete picard downsample command.");
    }
    $self->status_message("Downsampled bam has been created at: ".$temp);

    #create an imported instrument-data record
    my $instrument_data = $self->_import_bam($temp, $model, $downsample_ratio);
    unless($instrument_data){
        die $self->error_message("Could not import bam");
    }
    $self->status_message("Your new instrument-data id is: ".join(',', map $_->id, @{$instrument_data}));

    my $new_model = $self->_define_new_model($model, $instrument_data, $downsample_ratio);
    $self->status_message("Your new model id is: ".$new_model->id);

    $self->_new_model($new_model);

    return 1;
}

sub get_or_create_library {
    my ($self, $sample, $lib_name) = @_;
    my $new_library_name = $lib_name . '-extlibs';

    my $library = Genome::Library->get(name => $new_library_name);
    unless ($library) {
        $library = Genome::Library->create(name => $new_library_name, sample => $sample);
    }

    unless($library){
        die $self->error_message("Could not get or create library.");
    }

    return $library;
}

# Given a model and instrument data, copy the model to a new one with only that instrument data assigned
sub _define_new_model {
    my ($self, $model, $instrument_data, $downsample_ratio) = @_;
    my $new_name = $model->name.'_downsample_'.$downsample_ratio;

    my $copy_command = Genome::Model::Command::Copy->create(
        model => $model,
        overrides => ["name=$new_name", map{'instrument_data=' . $_->id}@$instrument_data],
    );
    unless ($copy_command->execute) {
        die $self->error_message("Failed to copy model " . $model->id);
    }

    my $new_model = $copy_command->_new_model;

    return $new_model;
}


sub _import_bam {
    my $self = shift;
    my $bam = shift;
    my $model = shift;
    my $downsample_ratio = shift;

    my $dir = dirname($bam);
    my $filename = $dir."/all_sequences.bam";
    Genome::Sys->rename($bam, $filename);

    my $sample_id = $model->subject->id;
    my $sample = Genome::Sample->get($sample_id);
    unless($sample){
        die $self->error_message("Cannot locate a sample to use for importing downsampled bam!");
    }

    my @i_ds = $model->instrument_data;
    my $lib_name = $i_ds[0]->library->name;

    my $library = $self->get_or_create_library($sample, $lib_name);

    my %params = (
        source_files => [$filename],
        library => $library,
        import_source_name => 'TGI',
        description => "Downsampled bam, ratio=".$downsample_ratio,
        instrument_data_properties => ['reference_sequence_build_id='.$model->reference_sequence_build_id],
    );
    if($model->target_region_set_name) {
        push @{$params{instrument_data_properties}}, 'target_region_set_name=' . $model->target_region_set_name;
    }

    my $import_cmd = Genome::InstrumentData::Command::Import::Basic->execute(
        %params,
    );
    unless($import_cmd){
        die $self->error_message("Could not execute bam import command!");
    }

    my @id = $import_cmd->_new_instrument_data;
    unless(@id){
        die $self->error_message("Could not retrieve newly created instrument-data");
    }
    return \@id;
}

sub _get_or_create_flagstat {
    my $self = shift;
    my $bam = shift;

    my $flagstat_file = $bam.".flagstat";
    unless(-s $flagstat_file){
        $self->status_message("Couldn't locate flagstat file, generating one now");
        my $flag_cmd = Genome::Model::Tools::Sam::Flagstat->create(
            bam_file => $bam,
            output_file => $flagstat_file,
        );
        unless($flag_cmd->execute){
            die $self->error_message("Could not create a flagstat file.");
        }
    }
    return $flagstat_file;
}

# Given a bam, return the total number of reads
sub _get_readcount {
    my $self = shift;
    my $bam = shift;

    my $flagstat_file = $self->_get_or_create_flagstat($bam);
    $self->status_message("Found or created a flagstat file, proceeding to downsampling.");
    my $flagstat = Genome::Model::Tools::Sam::Flagstat->parse_file_into_hashref($flagstat_file);
    return $flagstat->{total_reads};
}

# Given a model, return the read_length of the instrument data assigned to that model. Die if the length differs between instrument data.
sub _get_readlength {
    my $self = shift;
    my $model = shift;
    my @id = grep{ defined($_)} $model->instrument_data;
    $self->status_message("Found ". scalar(@id) . " instrument-data records associated with model ".$model->id);
    my $readlength;
    for my $id (@id){
        if(defined($readlength)){
            unless($id->read_length == $readlength){
                die $self->error_message("Found instrument data with different read lengths: ". $readlength."  and  ".$id->read_length."\n"
                    ."This tool currently works only on homogenous read length models.");
            }
        } else {
            $readlength = $id->read_length;
        }
    }
    unless($readlength){
        die $self->error_message("Could not locate instrument data on the model to determine read-length");
    }
    return $readlength;
}

1;
