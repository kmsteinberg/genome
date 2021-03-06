package Genome::Sys::FileLock;

use strict;
use warnings;

use Carp qw(carp croak);
use File::Basename;
use File::Temp;
use MIME::Lite;
use Sys::Hostname qw(hostname);
use Time::HiRes;

use Genome;
use base 'UR::ModuleBase';   # *_message methods, but no constructor
use Genome::Utility::Instrumentation;

my %SYMLINKS_TO_REMOVE;

sub lock {
    my($class, %args) = @_;

    @args{'resource_lock', 'parent_dir'} = _resolve_resource_lock_and_parent_dir_for_lock_resource(%args);

    my $total_lock_start_time = Time::HiRes::time();

    my($resource_lock, $parent_dir)
        = delete @args{'resource_lock','parent_dir'};
    unless ($resource_lock) {
        croak('resource_lock not set');
    }
    unless ($parent_dir) {
        croak('parent_dir not set');
    }

    my $basename = File::Basename::basename($resource_lock);

    my $block_sleep = delete $args{block_sleep};
    unless (defined $block_sleep) {
        croak('block_sleep not defined');
    }

    my $max_try = delete $args{max_try};
    unless (defined $max_try) {
        croak('max_try not defined');
    }

    my $wait_announce_interval = delete $args{wait_announce_interval};
    unless (defined $wait_announce_interval) {
        croak('wait_announce_interval not defined');
    }

    my $owner_details = $class->_resolve_lock_owner_details;
    my $lock_dir_template = sprintf("lock-%s--%s_XXXX",$basename,$owner_details);
    my $tempdir =  File::Temp::tempdir($lock_dir_template, DIR=>$parent_dir, CLEANUP=>1);

    unless (-d $tempdir) {
        Carp::croak("Failed to create temp lock directory ($tempdir)");
    }

    # make this readable for everyone
    chmod(0770, $tempdir) or Carp::croak("Can't chmod 0770 path ($tempdir): $!");

    # drop an info file into here for compatibility's sake with old stuff.
    # put a "NOKILL" here on LSF_JOB_ID so an old process doesn't try to snap off the job ID and kill me.
    my $lock_info = IO::File->new("$tempdir/info", ">");
    unless ($lock_info) {
        Carp::croak("Can't create info file $tempdir/info: $!");
    }

    my ($my_host, $my_pid, $my_lsf_id, $my_user) = (hostname, $$, ($ENV{'LSB_JOBID'} || 'NONE'), Genome::Sys->username);
    my $job_id = (defined $ENV{'LSB_JOBID'} ? $ENV{'LSB_JOBID'} : "NONE");
    $lock_info->printf("HOST %s\nPID $$\nLSF_JOB_ID_NOKILL %s\nUSER %s\n",
                       $my_host,
                       $ENV{'LSB_JOBID'},
                       $ENV{'USER'},
                     );
    $lock_info->close();

    my $initial_time = time;
    my $last_wait_announce_time = $initial_time;

    my $lock_attempts = 1;
    my $ret;
    while(!($ret = symlink($tempdir,$resource_lock))) {
        # TONY: The only allowable failure is EEXIST, right?
        # If any other error comes through, we end up in bigger trouble.
        use Errno qw(EEXIST ENOENT :POSIX);
        if ($! != EEXIST) {
            $class->error_message("Can't create symlink from $tempdir to lock resource $resource_lock because: $!");
            Carp::croak($class->error_message());
        }
        my $symlink_error = $!;
        chomp $symlink_error;
        return undef unless $max_try--;

        my $target = readlink($resource_lock);

        #If symlink no longer exists
        if ($! == ENOENT || !$target) {
            sleep $block_sleep;
            next;
        }

        #symlink could have disappeared between the top of the while loop and now, so we check to see if it's changed
        my $target_exists = (-e $target);
        unless($target eq readlink($resource_lock)){
            next;
        }

        if (!$target_exists) {
            # TONY: This means the lock symlink points to something that's been deleted
            # That's _really_ bad news and should probably get an email like below.
            $class->error_message("Lock ($resource_lock) exists but target ($target) does not exist.");
            Carp::croak($class->error_message);
        }

        if ($class->is_my_lock_target($target)) {
            $class->error_message("Tried to lock resource more than once: $resource_lock");
            Carp::croak($class->error_message);
        }

        my $target_basename = File::Basename::basename($target);
        $target_basename =~ s/lock-.*?--//; #might not always work if lock name starts with "-" or contains "--"
        my ($host, $user, $pid, $lsf_id) = split /_/, $target_basename;
        my $info_content=sprintf("HOST %s\nPID %s\nLSF_JOB_ID %s\nUSER %s",$host,$pid,$lsf_id,$user);

        my $time = time;
        my $elapsed_time = $time - $last_wait_announce_time;
        if ($elapsed_time >= $wait_announce_interval) {
            $last_wait_announce_time = $time;
            my $total_elapsed_time = $time - $initial_time;
            $class->status_message("waiting (total_elapsed_time = $total_elapsed_time seconds) on lock for resource '$resource_lock': $symlink_error. lock_info is:\n$info_content");
        }

        if ($lsf_id ne "NONE") {
            my ($job_info,$events) = Genome::Model::Event->lsf_state($lsf_id);
                 unless ($job_info) {
                     Genome::Utility::Instrumentation::increment('sys.lock.lock.found_orphan');
                     $class->warning_message("Invalid lock for resource $resource_lock\n"
                                            ." lock info was:\n". $info_content ."\n"
                                            ."Removing old resource lock $resource_lock\n");
                     unless ($Genome::Sys::IS_TESTING) {
                        my $message_content = <<END_CONTENT;
Hey Apipe,

This is a lock attempt on %s running as PID $$ LSF job %s and user %s.

I'm about to remove a lock file held by a LSF job that I think is dead.

The resource is:

%s

Here's info about the job that I think is gone.

%s

I'll remove the lock in an hour.  If you want to save the lock, kill me
before I unlock the process!

Your pal,
Genome::Utility::Filesystem

END_CONTENT

                        my $msg = MIME::Lite->new(From    => sprintf('"Genome::Utility::Filesystem" <%s@%s>', $ENV{'USER'}, $ENV{GENOME_EMAIL_DOMAIN}),
                                              To      => $ENV{GENOME_EMAIL_PIPELINE_NOISY},
                                              Subject => 'Attempt to release a lock held by a dead process',
                                              Data    => sprintf($message_content, $my_host, $ENV{'LSB_JOBID'}, $ENV{'USER'}, $resource_lock, $info_content),
                                            );
                        $msg->send();
                        $class->status_message('Sleeping for one hour...');
                        sleep 60 * 60;
                 }
                     $class->unlock(resource_lock => $resource_lock, force => 1);
                     #maybe warn here before stealing the lock...
               }
           }
        sleep $block_sleep;
        $lock_attempts += 1;
       }
    $SYMLINKS_TO_REMOVE{$resource_lock} = $$;

    my $total_lock_stop_time = Time::HiRes::time();
    my $lock_time_miliseconds = 1000 * ($total_lock_stop_time - $total_lock_start_time);

    my $caller_name = _resolve_caller_name(caller());

    Genome::Utility::Instrumentation::timing("lock_resource.$caller_name", $lock_time_miliseconds);
    Genome::Utility::Instrumentation::timing("lock_resource_attempts.$caller_name",
        $lock_attempts);

    Genome::Utility::Instrumentation::timing('lock_resource.total', $lock_time_miliseconds);
    Genome::Utility::Instrumentation::timing('lock_resource_attempts.total',
        $lock_attempts);

    # I don't think the conditional is actually needed but being safe
    if ($resource_lock) {
        Genome::Utility::Instrumentation::increment('sys.lock.lock.success');
    }
    return $resource_lock;
}

sub unlock {
    my($class, %args) = @_;

    $args{resource_lock} = $class->_resolve_resource_lock_for_unlock_resource(%args);

    my $resource_lock = delete $args{resource_lock};
    unless ($resource_lock) {
        carp('resource_lock is not set');
    }
    my $force = delete $args{force};

    my $target = readlink($resource_lock);
    if (!$target) {
        if ($! == ENOENT) {
            Genome::Utility::Instrumentation::increment('sys.lock.unlock.stolen_from_me');
            $class->error_message("Tried to unlock something that's not locked -- $resource_lock.");
            Carp::croak($class->error_message);
        } else {
            $class->error_message("Couldn't readlink $resource_lock: $!");
        }
    }
    unless (-d $target) {
        $class->error_message("Lock symlink '$resource_lock' points to something that's not a directory - $target. ");
        Carp::croak($class->error_message);
    }

    unless ($force) {
        unless ($class->is_my_lock_target($target)) {
             my $basename = File::Basename::basename($target);
             my $expected_details = $class->_resolve_lock_owner_details;
             Genome::Utility::Instrumentation::increment('sys.lock.unlock.stolen_from_me');
             $class->error_message("This lock does not look like it belongs to me.  $basename does not match $expected_details.");
             delete $SYMLINKS_TO_REMOVE{$resource_lock}; # otherwise the lock would be forcefully cleaned up when process exits
             Carp::croak($class->error_message);
        }
    }

    my $unlink_rv = unlink($resource_lock);
    if (!$unlink_rv) {
        Genome::Utility::Instrumentation::increment('sys.lock.unlock.unlink_failed');
        $class->error_message("Failed to remove lock symlink '$resource_lock':  $!");
        Carp::croak($class->error_message);
    }

    my $rmdir_rv = File::Path::rmtree($target);
    if (!$rmdir_rv) {
        Genome::Utility::Instrumentation::increment('sys.lock.unlock.rmtree_failed');
        $class->error_message("Failed to remove lock symlink target '$target', but we successfully unlocked.");
        Carp::croak($class->error_message);
    }

    delete $SYMLINKS_TO_REMOVE{$resource_lock};

    Genome::Utility::Instrumentation::increment('sys.lock.unlock.success');
    return 1;
}

sub clear_state {
    %SYMLINKS_TO_REMOVE = ();
}

sub translate_lock_args { shift; return @_ }
sub translate_unlock_args { shift; return @_ }

sub _resolve_caller_name {
    my ($package, $filename, $line) = @_;
    $package =~ s/::/./g;
    return $package;
}

#build the string for locks generated by this process
sub _resolve_lock_owner_details {
    my $class = shift;
    my ($my_host, $my_pid, $my_lsf_id, $my_user) = (hostname, $$, ($ENV{'LSB_JOBID'} || 'NONE'), Genome::Sys->username);
    my $job_id = (defined $ENV{'LSB_JOBID'} ? $ENV{'LSB_JOBID'} : "NONE");
    my $lock_details = join('_',$my_host,$ENV{'USER'},$$,$job_id);

    return $lock_details;
}

sub is_mandatory { 1 }

sub has_lock {
    my ($class, $resource_lock) = @_;
    return $SYMLINKS_TO_REMOVE{$resource_lock};
}

sub is_my_lock_target {
    my $class = shift;
    my $target = shift;

     my $basename = File::Basename::basename($target);
    $basename =~ s/_.{4}$//; #remove random chars tmpdir adds to end
    my $expected_details = $class->_resolve_lock_owner_details;
    my $length = length($expected_details);

    return (substr($basename, (0-$length)) eq $expected_details);
}

sub release_all {
    my $class = shift;

    my %errors;
    for my $sym_to_remove (keys %SYMLINKS_TO_REMOVE) {
        if ($SYMLINKS_TO_REMOVE{$sym_to_remove} == $$) {
            if (-l $sym_to_remove) {
                warn("Removing remaining resource lock: '$sym_to_remove'") unless $ENV{'HARNESS_ACTIVE'};
                eval {$class->unlock(resource_lock => $sym_to_remove)};
                $errors{$sym_to_remove} = $@ if $@;
            }
        } else {
            $class->warning_message("Not cleaning up lock named (%s) because ".
                "the pid that created it (%s) is not my pid (%s).",
                $sym_to_remove,
                $SYMLINKS_TO_REMOVE{$sym_to_remove},
                $$,
            );
        }
    }
    if (keys %errors) {
        $class->error_message("Cleaning up the following locks failed: %s",
            join(", ", keys %errors),
        );
        Carp::croak(join("\n", values %errors));
    }
}

sub _resolve_resource_lock_and_parent_dir_for_lock_resource {
    my %args = @_;

    my $resource_lock = delete $args{resource_lock};
    my ($lock_directory,$resource_id,$parent_dir);
    if ($resource_lock) {
        $parent_dir = File::Basename::dirname($resource_lock);
        Genome::Sys->create_directory($parent_dir);
        unless (-d $parent_dir) {
            Carp::croak("failed to make parent directory $parent_dir for lock $resource_lock!: $!");
        }
    }
    else {
        $lock_directory =  delete $args{lock_directory} || Carp::croak('Must supply lock_directory to lock resource');
        Genome::Sys->create_directory($lock_directory);
        $resource_id = $args{'resource_id'} || Carp::croak('Must supply resource_id to lock resource');
        $resource_lock = $lock_directory . '/' . $resource_id . ".lock";
        $parent_dir = $lock_directory
    }

    return ($resource_lock, $parent_dir);
}

sub _resolve_resource_lock_for_unlock_resource {
    my($class, %args) = @_;

    my $resource_lock = $args{resource_lock};
    unless ($resource_lock) {
        my ($lock_directory,$resource_id);
        $lock_directory =  delete $args{lock_directory} || Carp::croak('Must supply lock_directory to unlock resource');
        $resource_id = $args{'resource_id'} || Carp::croak('Must supply resource_id to lock resource');
        $resource_lock = $lock_directory . '/' . $resource_id . ".lock";
    }
    return $resource_lock;
}

1;
