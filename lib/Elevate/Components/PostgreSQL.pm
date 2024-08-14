package Elevate::Components::PostgreSQL;

=encoding utf-8

=head1 NAME

Elevate::Components::PostgreSQL

=cut

use cPstrict;

use Simple::Accessor qw{service};

use parent qw{Elevate::Components::Base};

use Elevate::Constants        ();
use Elevate::Notify           ();
use Elevate::StageFile        ();
use Elevate::SystemctlService ();

use Cpanel::Pkgr              ();
use Cpanel::SafeRun::Object   ();
use Cpanel::Services::Enabled ();
use Whostmgr::Postgres        ();

use Log::Log4perl qw(:easy);

use File::Copy::Recursive ();
use File::Slurp           ();

sub _build_service ($self) {
    return Elevate::SystemctlService->new( name => 'postgresql' );
}

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

    INFO("Fetching encoding and locale information from PostgreSQL.");

    my $is_active_prior = $self->service->is_active;

    $self->service->start();

    if ( $self->service->is_active ) {
        my $psql_sro = Cpanel::SafeRun::Object->new(
            program => '/usr/bin/psql',
            args    => [
                qw{-F | -At -U postgres -c},
                q{SELECT pg_encoding_to_char(encoding), datcollate, datctype FROM pg_catalog.pg_database WHERE datname = 'template1'},
            ],
        );

        if ( $psql_sro->CHILD_ERROR ) {
            ERROR("The system instance of PostgreSQL did not return information about the encoding and locale of core databases.");
            ERROR("ELevate will assume the system defaults and attempt an upgrade anyway.");
            return;
        }

        my $output = $psql_sro->stdout;
        chomp $output;

        my ( $encoding, $collation, $ctype ) = split /\|/, $output;
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
        ERROR("The system instance of PostgreSQL was unable to start to give information about the encoding and locale of core databases.");
        ERROR("ELevate will assume the system defaults and attempt an upgrade anyway.");
        $self->_give_up_on_postgresql();
    }

    return;
}

sub _disable_postgresql_service ($self) {

    # If the service is enabled in Service Manager, then upcp fails during post-leapp phase of the RpmDB component:
    if ( Cpanel::Services::Enabled::is_enabled('postgresql') ) {
        Elevate::StageFile::update_stage_file( { 're-enable_postgresql_in_sm' => 1 } );
        Cpanel::Services::Enabled::touch_disable_file('postgresql');
    }

    return;
}

# TODO: What happens if this runs out of disk space? Should we check first?
# XXX Is this really better than `cp -a $src $dst`? I hope nothing in there is owned by someone other than the postgres user...
sub _backup_postgresql_datadir ($self) {

    $self->service->stop() if $self->service->is_active;    # for safety

    my $pgsql_datadir_path        = Elevate::Constants::POSTGRESQL_SYSTEM_DATADIR;
    my $pgsql_datadir_backup_path = $pgsql_datadir_path . '_elevate_' . time() . '_' . $$;

    INFO("Backing up the system PostgreSQL data directory at $pgsql_datadir_path to $pgsql_datadir_backup_path.");

    # Set EUID/EGID to postgres (this is not security critical; it's just to retain correct ownership within copy):
    my ( $uid, $gid ) = ( scalar( getpwnam('postgres') ), scalar( getgrnam('postgres') ) );
    my $outcome = 0;
    {
        local ( $>, $) ) = ( $uid, "$gid $gid" );
        $outcome = File::Copy::Recursive::dircopy( $pgsql_datadir_path, $pgsql_datadir_backup_path );
    }

    if ( !$outcome ) {
        ERROR("The system encountered an error while trying to make a backup.");
        $self->_give_up_on_postgresql();
    }
    else {
        Elevate::Notify::add_final_notification( <<~"EOS" );
        ELevate backed up your system PostgreSQL data directory to $pgsql_datadir_backup_path
        prior to any modification or attempt to upgrade, in case the upgrade needs to be performed
        manually, or if old settings need to be referenced.
        EOS
    }

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
    return unless -e $pgconf_path;    # if postgresql.conf isn't there, there's nothing to work around

    INFO("Modifying $pgconf_path to work around a defect in the system's PostgreSQL upgrade package.");

    my $pgconf = eval { File::Slurper::read_text($pgconf_path) };
    if ($@) {
        ERROR("Attempting to read $pgconf_path resulted in an error: $@");
        $self->_give_up_on_postgresql();
        return;
    }

    my $changed = 0;
    my @lines   = split "\n", $pgconf;
    foreach my $line (@lines) {
        next if $line =~ m/^\s*$/a;
        if ( $line =~ m/^\s*unix_socket_directories/ ) {
            $line    = "#$line";
            $changed = 1;
        }
    }

    if ($changed) {
        push @lines, "unix_socket_directory = '/var/run/postgresql'";

        my $pgconf_altered = join "\n", @lines;
        eval { File::Slurper::write_text( $pgconf_path, $pgconf_altered ) };

        if ($@) {
            ERROR("Attempting to overwrite $pgconf_path resulted in an error: $@");
            $self->_give_up_on_postgresql();
        }
    }

    return;
}

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
    my $outcome = $self->ssystem( { keep_env => ( scalar @args > 0 ? 1 : 0 ) }, qw{/usr/bin/postgresql-setup --upgrade} );

    if ( $outcome == 0 ) {
        INFO("The PostgreSQL upgrade process was successful.");
        Elevate::Notify::add_final_notification( <<~EOS );
        ELevate successfully ran the upgrade procedure on the system instance of
        PostgreSQL. If no problems are reported with configuring the upgraded instance
        to work with cPanel, you should proceed with applying any relevant
        customizations to the configuration and authentication settings, since the
        upgrade process reset this information to system defaults.
        EOS
    }
    else {
        ERROR("The upgrade attempt of the system PostgreSQL instance failed. See the log files mentioned in the output of postgresql-setup for more information.");
        $self->_give_up_on_postgresql();
    }

    return;
}

sub _re_enable_service_if_needed ($self) {
    return if $self->_gave_up_on_postgresql;    # keep disabled if there was a failure

    if ( Elevate::StageFile::read_stage_file( 're-enable_postgresql_in_sm', 0 ) ) {
        Cpanel::Services::Enabled::remove_disable_files('postgresql');
    }

    return;
}

sub _run_whostmgr_postgres_update_config ($self) {
    return if $self->_gave_up_on_postgresql;

    INFO("Configuring PostgreSQL to work with cPanel's installation of phpPgAdmin.");
    $self->service->start();    # less noisy when it's online, but still works

    my ( $success, $msg ) = Whostmgr::Postgres::update_config();
    if (!$success) {
        ERROR("The system failed to update the PostgreSQL configuration: $msg");
        Elevate::Notify::add_final_notification( <<~EOS );
        ELevate was unable to configure the upgraded system PostgreSQL instance to work
        with cPanel. See the log for additional information. Once the issue has been
        addressed, perform this step manually using the "Postgres Config Install" area
        in WHM:

        https://go.cpanel.net/whmdocsConfigurePostgreSQL

        Do this before restoring any customizations to PostgreSQL configuration or
        authentication files, since performing this action resets these to cPanel
        defaults.
        EOS
    }

    return;
}

sub _give_up_on_postgresql ($self) {
    ERROR('Skipping attempt to upgrade the system instance of PostgreSQL.');
    Elevate::StageFile::update_stage_file( { postgresql_give_up => 1 } );
    Elevate::Notify::add_final_notification( <<~EOS );
    The process of upgrading the system instance of PostgreSQL failed. The
    PostgreSQL service has been disabled in the Service Manager in WHM:

    https://go.cpanel.net/whmdocsServiceManager

    If you do not have cPanel users who use PostgreSQL or otherwise do not use it,
    you do not have to take any action. Otherwise, see the ELevate logs for further
    information.
    EOS
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
