package Elevate::Components::PostgreSQL;

=encoding utf-8

=head1 NAME

Elevate::Components::PostgreSQL

=cut

use cPstrict;

use parent qw{Elevate::Components::Base};

use Elevate::Constants ();

use Cpanel::Pkgr       ();
use Whostmgr::Postgres ();

use Log::Log4perl qw(:easy);

use File::Copy::Recursive ();
use File::Slurp           ();

sub pre_leapp ($self) {
    if ( Cpanel::Pkgr::is_installed('postgresql-server') ) {
        $self->_backup_postgresql_datadir();
    }

    return;
}

# TODO: What happens if this runs out of disk space? Other error checking too.
# XXX Is this really better than `cp -a $src $dst`? I hope nothing in there is owned by someone other than the postgres user...
sub _backup_postgresql_datadir ($self) {
    my $pgsql_datadir_path        = Elevate::Constants::POSTGRESQL_SYSTEM_DATADIR;
    my $pgsql_datadir_backup_path = $pgsql_datadir_path . '_' . time() . '_' . $$;

    # TODO: add final notification elaborating on this
    INFO("Backing up the system PostgreSQL data directory at $pgsql_datadir_path to $pgsql_datadir_backup_path.");

    # Set EUID/EGID to postgres for the rest of this function (this is not security critical; it's just to retain correct ownership within copy):
    my ( $uid, $gid ) = ( scalar( getpwnam('postgres') ), scalar( getgrnam('postgres') ) );
    local ( $>, $) ) = ( $uid, "$gid $gid" );

    File::Copy::Recursive::dircopy( $pgsql_datadir_path, $pgsql_datadir_backup_path );

    return;
}

sub post_leapp ($self) {
    if ( Cpanel::Pkgr::is_installed('postgresql-server') ) {
        $self->_perform_config_workaround();
        $self->_perform_postgresql_upgrade();
        $self->_run_whostmgr_postgres_update_config();
    }

    return;
}

sub _perform_config_workaround ($self) {
    my $pgconf_path = Elevate::Constants::POSTGRESQL_SYSTEM_DATADIR . '/postgresql.conf';
    my $pgconf      = File::Slurper::read_text($pgconf_path);                               # TODO: what if this file does not exist?

    INFO("Modifying $pgconf_path to work around a defect in the system's PostgreSQL upgrade package.");

    my @lines = split "\n", $pgconf;
    foreach my $line (@lines) {
        next if $line =~ m/^\s*$/a;
        $line = "#$line" if $line =~ m/^\s*unix_socket_directories/;
    }

    push @lines, "unix_socket_directory = '/var/run/postgresql'";

    my $pgconf_altered = join "\n", @lines;
    File::Slurper::write_text( $pgconf_path, $pgconf_altered );

    return;
}

# TODO: error handling?
sub _perform_postgresql_upgrade ($self) {
    INFO("Installing PostgreSQL update package:");
    $self->dnf->install('postgresql-update');

    INFO("Upgrading PostgreSQL data directory:");
    $self->ssystem(qw{/usr/bin/postgresql-setup --upgrade});

    # TODO: add final notification stating that custom configuration and authentication may need to be restored manually

    return;
}

# TODO: return values
sub _run_whostmgr_postgres_update_config ($self) {
    INFO("Configuring PostgreSQL to work with cPanel's installation of phpPgAdmin.");
    return Whostmgr::Postgres::update_config();
}

1;
