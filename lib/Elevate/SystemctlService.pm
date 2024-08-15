package Elevate::SystemctlService;

=encoding utf-8

=head1 NAME

Elevate::SystemctlService

Interact with a systemctl service.

=cut

use cPstrict;

use Cpanel::SafeRun::Simple     ();
use Cpanel::RestartSrv::Systemd ();

use Log::Log4perl qw(:easy);

use Elevate::Roles::Run ();    # for fatpck

use Simple::Accessor qw{
  name
};

use parent qw{
  Elevate::Roles::Run
};

sub _build_name {
    die q[Missing sevice name ] . __PACKAGE__;
}

sub is_active ($self) {

    # cannot trust: `systemctl is-active` with a one-shot service
    my $service = $self->name;

    my $is_active;
    Cpanel::SafeRun::Simple::saferunnoerror( qw{/usr/bin/systemctl is-active}, $service );
    $is_active = 1 if $? == 0;

    my $info = Cpanel::RestartSrv::Systemd::get_service_info_via_systemd($service);
    $info->{'ActiveState'} //= '';
    $info->{'SubState'}    //= '';

    $is_active = 1 if $info->{'ActiveState'} eq 'activating' && $info->{'SubState'} eq 'start';

    if ( $is_active && $info->{'SubState'} ne 'exited' ) {
        return 1;
    }

    return 0;
}

sub is_enabled ($self) {

    my $service = $self->name;

    my $out = Cpanel::SafeRun::Simple::saferunnoerror( qw{/usr/bin/systemctl is-enabled}, $service ) // '';
    chomp $out;

    return 1 if $out eq 'enabled';

    return 0;
}

sub restart ($self) {
    return $self->ssystem( qw{/usr/bin/systemctl restart}, $self->name );
}

sub remove ($self) {

    my $info = eval { Cpanel::RestartSrv::Systemd::get_service_info_via_systemd( $self->name ) } // {};

    $self->stop;
    $self->disable;

    if ( my $path = $info->{FragmentPath} ) {
        unlink $path;
    }

    return;
}

sub start ($self) {

    return if $self->is_active;

    $self->ssystem( '/usr/bin/systemctl', 'start', $self->name );

    return;
}

sub stop ($self) {

    return unless $self->is_active;

    $self->ssystem( '/usr/bin/systemctl', 'stop', $self->name );

    return;
}

sub disable ( $self, %opts ) {

    return unless $self->is_enabled;

    my $now = $opts{'now'} // 1;    # by default disable it now...

    my @args = qw{ disable };
    push @args, '--now' if $now;

    $self->ssystem( '/usr/bin/systemctl', @args, $self->name );

    return;
}

sub enable ( $self, %opts ) {

    return if $self->is_enabled;

    my $now = $opts{'now'} // 1;    # by default enable it now...

    my @args = qw{ enable };
    push @args, '--now' if $now;

    $self->ssystem( '/usr/bin/systemctl', @args, $self->name );

    return;
}

1;
