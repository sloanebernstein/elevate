package Elevate::Components::PostgreSQL;

=encoding utf-8

=head1 NAME

Elevate::Components::PostgreSQL

=cut

use cPstrict;

use Simple::Accessor qw{service};

use parent qw{Elevate::Components::Base};

use Elevate::Constants ();

use Cpanel::Pkgr              ();
use Cpanel::Services::Enabled ();
use Whostmgr::Postgres        ();

use Log::Log4perl qw(:easy);

use File::Copy::Recursive ();
use File::Slurp           ();

sub _build_service ($self) {
    return Elevate::SystemctlService->new( name => 'postgresql' );
}

# installed

sub pre_leapp ($self) {
    if ( Cpanel::Pkgr::is_installed('postgresql-server') ) {
        $self->_store_postgresql_encoding_and_locale();
        $self->_disable_postgresql_service();
        $self->_backup_postgresql_datadir();
    }

    return;
}

# PostgreSQL needs to be up to get this information:
sub _store_postgresql_encoding_and_locale ($self) {

    return if $self->_gave_up_on_postgresql;    # won't hurt

    my $is_active_prior = $self->service->is_active;

    $self->service->start();                    # short-circuits if already active

    if ( $self->service->is_active ) {
        my $psql_sro = Cpanel::SafeRun::Object->new_or_die(
            program => Cpanel::Binaries::path('psql'),
            args    => [
                qw{-F | -At -U postgres -c},
                q{SELECT pg_encoding_to_char(encoding), datcollate, datctype FROM pg_catalog.pg_database WHERE datname = 'template1'},
            ],
        );

        my $output = $psql_sro->stdout;
        chomp $output;

        my ( $encoding, $collation, $ctype ) = split '|', $output;
        Elevate::StageFile::update_stage_file(
            {
                postgresql_locale => {
                    encoding  => $encoding,
                    collation => $collation,
                    ctype     => $ctype,
                }
            }
        );

        $self->service_stop() unless $is_active_prior;
    }
    else {
        $self->_give_up_on_postgresql();
    }

    return;
}

sub _disable_postgresql_service ($self) {

    # If the service is enabled in Service Manager but unable to run, then upcp fails during post-leapp phase of the RpmDB component:
    if ( Cpanel::Services::Enabled::is_enabled('postgresql') ) {
        Elevate::StageFile::update_stage_file( { 're-enable_postgresql_in_sm' => 1 } );
        Cpanel::Services::Enabled::touch_disable_file('postgresql');
    }

    return;
}

# TODO: What happens if this runs out of disk space? Other error checking too.
# XXX Is this really better than `cp -a $src $dst`? I hope nothing in there is owned by someone other than the postgres user...
sub _backup_postgresql_datadir ($self) {

    $self->service->stop() if $self->service->is_active;    # for safety

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
        $self->_re_enable_service_if_needed();
        $self->_run_whostmgr_postgres_update_config();
    }

    return;
}

sub _perform_config_workaround ($self) {
    return if $self->_gave_up_on_postgresql;

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
    return if $self->_gave_up_on_postgresql;

    INFO("Installing PostgreSQL update package:");
    $self->dnf->install('postgresql-upgrade');

    my $opts = Elevate::StageFile::read_stage_file('postgresql_locale');
    my @args;
    push @args, "--encoding=$opts->{encoding}"    if $opts->{encoding};
    push @args, "--lc-collate=$opts->{collation}" if $opts->{collation};
    push @args, "--lc-ctype=$opts->{ctype}"       if $opts->{ctype};

    local $ENV{PGSETUP_INITDB_OPTIONS} = join ' ', @args if scalar @args > 0;

    INFO("Upgrading PostgreSQL data directory:");
    my $capture = $self->ssystem_capture_output( { keep_env => 1 }, qw{/usr/bin/postgresql-setup --upgrade} );

    # TODO: add final notification stating that custom configuration and authentication may need to be restored manually

    return;
}

# TODO: return values
sub _run_whostmgr_postgres_update_config ($self) {
    return if $self->_gave_up_on_postgresql;

    INFO("Configuring PostgreSQL to work with cPanel's installation of phpPgAdmin.");
    $self->service->start();    # PostgreSQL *must* be online for this to work
    return Whostmgr::Postgres::update_config();
}

sub _re_enable_service_if_needed ($self) {
    return if $self->_gave_up_on_postgresql;

    if ( Elevate::StageFile::read_stage_file( 're-enable_postgresql_in_sm', 0 ) ) {
        Cpanel::Services::Enabled::remove_disable_files('postgresql');
    }

    return;
}

sub _give_up_on_postgresql ($self) {
    Elevate::StageFile::update_stage_file( { postgresql_give_up => 1 } );
    return;
}

sub _gave_up_on_postgresql ($self) {
    return Elevate::StageFile::read_stage_file( 'postgresql_give_up', 0 );
}

# alias
sub _given_up_on_postgresql {
    goto &_gave_up_on_postgresql;
}

1;
