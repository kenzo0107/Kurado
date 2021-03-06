package Kurado::TinyTCP;

use strict;
use warnings;
use POSIX qw(EINTR EAGAIN EWOULDBLOCK :sys_wait_h);
use IO::Socket qw(IPPROTO_TCP TCP_NODELAY);
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw//;

our $READ_BYTES = 16 * 1024;

sub new {
    my $class = shift;
    my %args = ref $_ ? %{$_[0]} : @_;
    %args = (
        server => '127.0.0.1:6379',
        timeout => 10,
        %args,
    );
    my $server = shift;
    my $self = bless \%args, $class;
    $self->connect;
    $self;
}

sub connect {
    my $self = shift;
    return $self->{sock} if $self->{sock};
    my $socket;
    eval {
        local $SIG{ALRM} = sub { die "Timed out\n"; };
        alarm(4);
        $socket = IO::Socket::INET->new(
            PeerAddr => $self->{server},
        ) or die "Socket connect failed: $!\n";
    };
    alarm(0);
    die $@ if $@;
    $socket->blocking(0);
    $socket->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1)
        or die "setsockopt(TCP_NODELAY) failed:$!\n";
    $self->{sock} = $socket;
    $socket;
}

sub read : method {
    my ($self, $timeout) = @_;
    $timeout ||= $self->{timeout};
    my $timeout_at = Time::HiRes::time + $timeout;
    my $buf = '';
    my $n = $self->do_io(undef, \$buf, $READ_BYTES, 0, $timeout_at);
    die $! != 0 ? "$!\n" : "timeout or socket closed\n" if !defined $n;
    die "Socket closed by remote server: $!" if $n == 0;
    return $buf;
}

sub read_until_close {
    my ($self, $timeout) = @_;
    $timeout ||= $self->{timeout};
    my $timeout_at = Time::HiRes::time + $timeout;
    my $buf = '';
    while (1) {
        my $off = length($buf);
        my $n = $self->do_io(undef, \$buf, $READ_BYTES, $off, $timeout_at);
        die $! != 0 ? "$!\n" : "timeout\n" if !defined $n;
        last if $n == 0; #close
    }
    return $buf;
}

sub write : method {
    my ($self, $buf, $timeout) = @_;
    $timeout ||= $self->{timeout};
    my $timeout_at = Time::HiRes::time + $timeout;
    my $off = 0;
    while (my $len = length($buf) - $off) {
        my $n = $self->do_io(1, $buf, $len, $off, $timeout_at);
        die $! != 0 ? "$!\n" : "timeout\n" if !$n;
        die "Socket closed by remote server: $!" if $n == 0;
        $off += $n;
    }
    return length $buf;    
}



# returns value returned by $cb, or undef on timeout or network error
sub do_io {
    my ($self, $is_write, $buf, $len, $off, $timeout_at) = @_;
    my $sock = $self->{sock};
    my $ret;
    local $SIG{PIPE} = 'IGNORE';    

    if ( !$is_write ){ #read
        goto DO_SELECT;
    }
 DO_READWRITE:
    # try to do the IO
    if ($is_write) {
        defined($ret = syswrite $sock, $buf, $len, $off)
            and return $ret;
    } else {
        defined($ret = sysread $sock, $$buf, $len, $off)
            and return $ret;
    }
    if ( $! != EINTR && $! != EAGAIN && $! != EWOULDBLOCK ) {
        return;
    }
    # wait for data
 DO_SELECT:
    while (1) {
        my $timeout = $timeout_at - Time::HiRes::time;
        return if $timeout <= 0;
        my ($rfd, $wfd);
        my $efd = '';
        vec($efd, fileno($sock), 1) = 1;
        if ($is_write) {
            ($rfd, $wfd) = ('', $efd);
        } else {
            ($rfd, $wfd) = ($efd, '');
        }
        my $nfound = select($rfd, $wfd, $efd, $timeout);
        last if $nfound;
    }
    goto DO_READWRITE;
}

1;
