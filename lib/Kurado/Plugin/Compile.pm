package Kurado::Plugin::Compile;

use strict;
use warnings;
use utf8;
use 5.10.0;
use Mouse;
use Log::Minimal;
use Data::Validator;
use File::Spec;
use File::Basename;
use Cwd::Guard;
use POSIX 'SEEK_SET';
use SelectSaver;
use JSON::XS;
use Capture::Tiny;

use Kurado::Storage;

my $_JSON = JSON::XS->new->utf8;

has 'config' => (
    is => 'ro',
    isa => 'Kurado::Config',
    required => 1
);

__PACKAGE__->meta->make_immutable();

our $RETURN_EXIT_VAL = undef;
our $USE_REAL_EXIT;
BEGIN {
    $USE_REAL_EXIT = 1;

    my $orig = *CORE::GLOBAL::exit{CODE};

    my $proto = $orig ? prototype $orig : prototype 'CORE::exit';

    $proto = $proto ? "($proto)" : '';

    $orig ||= sub {
        my $exit_code = shift;

        CORE::exit(defined $exit_code ? $exit_code : 0);
    };

    no warnings 'redefine';

    *CORE::GLOBAL::exit = eval qq{
        sub $proto {
            my \$exit_code = shift;

            \$orig->(\$exit_code) if \$USE_REAL_EXIT;

            die [ "EXIT\n", \$exit_code || 0 ]
        };
    };
    die $@ if $@;
}

# this helper function is placed at the top of the file to
# hide variables in this file from the generated sub.
sub _eval {
    no strict;
    no warnings;

    eval $_[0];
}

my %COMPILE;
sub compile {
    state $rule = Data::Validator->new(
        plugin => 'Str',
        type => 'Str',
    )->with('Method');
    my ($self, $args) = $rule->validate(@_);
    my $path = $self->find_plugin($args);

    return unless $path;

    return $COMPILE{$path} if $COMPILE{$path};

    infof "found plugin %s/%s at %s", $args->{type}, $args->{plugin}, $path;
    my $dir = dirname $path;
    my $package = $self->_build_package($path);
    my $code = $self->_read_source($path);

    my $warnings = $code =~ /^#!.*\s-w\b/ ? 1 : 0;
    $code =~ s/^__END__\r?\n.*//ms;
    $code =~ s/^__DATA__\r?\n(.*)//ms;
    my $data = $1;

        my $eval = join "\n",
        "package $package;",
        "sub {",
        '  local $Kurado::Plugin::Compile::USE_REAL_EXIT = 0;',
        '  local ($0, $Kurado::Plugin::Compile::_dir, *DATA);',
        '  {',
        '    my ($data, $path, $dir) = @_[0..2];',
        '    $0 = $path;',
        '    $Kurado::Plugin::Compile::_dir = Cwd::Guard::cwd_guard $dir;',
       q!    open DATA, '<', \$data;!,   
        '  }',
        # NOTE: this is a workaround to fix a problem in Perl 5.10
       q!  local @SIG{keys %SIG} = do { no warnings 'uninitialized'; @{[]} = values %SIG };!,
        '  local $^W = $warnings;',
        '  my $rv = eval {',
        '    local @ARGV = @{ $_[3] };', # args to @ARGV
        '    local @_    = @{ $_[3] };', # args to @_ as well
        "    #line 1 $path",
        "    $code",
        '  };',
        '  my $exit_code = 0;',
        '  if ($@) {',
        '    die "$@\n" unless (ref($@) eq "ARRAY" and $@->[0] eq "EXIT\n");', #no exit
       q!    $exit_code = unpack('C', pack('C', sprintf('%.0f', $@->[1])));!, # ~128
        '    die "exited nonzero: $exit_code" if $exit_code != 0;',
        '  }',
        '  return $exit_code;',
        '};',"\n";

    my $sub = do {
        no warnings 'uninitialized'; # for 5.8
        # NOTE: this is a workaround to fix a problem in Perl 5.10
        local @SIG{keys %SIG} = @{[]} = values %SIG;
        local $USE_REAL_EXIT = 0;

        my $code = _eval $eval;
        my $exception = $@;

        die "Could not compile $path: $exception\n" if $exception;

        sub {
            my @args = @_;
            $code->($data, $path, $dir, \@args)
        };
    };
    infof "succeeded compiling plugin %s/%s", $args->{type}, $args->{plugin}, $path;
    $COMPILE{$path} = $sub;
    return $sub;
}

sub jdclone {
    my $ref = shift;
    $_JSON->decode($_JSON->encode($ref));
}

sub run {
    state $rule = Data::Validator->new(
        host => 'Kurado::Object::Host',
        plugin => 'Kurado::Object::Plugin',
        type => 'Str',
        graph => { isa => 'Str', optional => 1 },
    )->with('Method');
    my ($self, $args) = $rule->validate(@_);
    
    my $sub = $self->compile(
        plugin => $args->{plugin}->plugin,
        type => $args->{type},
    );

    my $storage = Kurado::Storage->new( redis => $self->config->redis );
    my $meta = $storage->get_by_plugin(
        plugin => $args->{plugin},
        address => $args->{host}->address,
    );

    my @params = ();
    push @params, '--address', $args->{host}->address;
    push @params, '--hostname', $args->{host}->hostname;
    push @params, '--comments', $args->{host}->comments if length $args->{host}->comments;
    for my $p_a ( @{$args->{plugin}->arguments} ) {
        push @params, '--plugin-arguments', $p_a;
    }
    push @params, '--graph', $args->{graph} if exists $args->{graph};

    my ($stdout, $stderr, $success) = Capture::Tiny::capture {
        local $Kurado::Plugin::BRIDGE{'kurado.metrics_config'} = jdclone($args->{host}->metrics_config);
        local $Kurado::Plugin::BRIDGE{'kurado.metrics_meta'} = jdclone($meta);
        #local $ENV{'kurado.metrics_config_json'} = $_JSON->encode($args->{metrics_config});
        #local $ENV{'kurado.metrics_meta_json'} = $_JSON->encode($meta);
        eval {
            $sub->(@params);
        };
        if ( $@ ) {
            warn "$@\n";
            return 0;
        }
        return 1;
    };
    return ($stdout, $stderr, $success);
}

sub find_plugin {
    state $rule = Data::Validator->new(
        plugin => 'Str',
        type => 'Str',
    )->with('Method');
    my ($self, $args) = $rule->validate(@_);

    for my $dir ( @{$self->config->metrics_plugin_dir} ) {
        my $path = File::Spec->catfile($dir,$args->{type},$args->{plugin}.'.pl');
        if ( -f $path ) {
            return $path;
        }
    }

    return;
}

sub _read_source {
    my($self, $file) = @_;

    open my $fh, "<", $file or die "$file: $!";
    return do { local $/; <$fh> };
}

sub _build_package {
    my($self, $path) = @_;

    my ($volume, $dirs, $file) = File::Spec->splitpath($path);
    my @dirs = File::Spec->splitdir($dirs);
    my $package = join '_', grep { defined && length } $volume, @dirs, $file;

    # Escape everything into valid perl identifiers
    $package =~ s/([^A-Za-z0-9_])/sprintf("_%2x", unpack("C", $1))/eg;

    # make sure that the sub-package doesn't start with a digit
    $package =~ s/^(\d)/_$1/;

    $package = "Kurado::Plugin::Compile::ROOT" . "::$package";
    return $package;
}

1;

