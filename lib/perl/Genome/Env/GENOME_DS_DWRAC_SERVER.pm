package Genome::Env::GENOME_DS_DWRAC_SERVER;
use base 'Genome::Env::Required';

=pod

=head1 NAME

GENOME_DS_DWRAC_SERVER

=head1 DESCRIPTION

The GENOME_DS_DWRAC_SERVER environment variable holds database server
connection details for the Dwrac database.  Its value is used to build
the DBI connection string after the DBI driver name.

=cut

1;
