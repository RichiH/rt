# BEGIN BPS TAGGED BLOCK {{{
#
# COPYRIGHT:
#
# This software is Copyright (c) 1996-2013 Best Practical Solutions, LLC
#                                          <sales@bestpractical.com>
#
# (Except where explicitly superseded by other copyright notices)
#
#
# LICENSE:
#
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
#
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
# 02110-1301 or visit their web page on the internet at
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.html.
#
#
# CONTRIBUTION SUBMISSION POLICY:
#
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
#
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
#
# END BPS TAGGED BLOCK }}}

use warnings;
use strict;

package RT::PlackRunner;

use base 'Plack::Runner';

sub parse_options {
    my $self = shift;
    my @args = @_;
    # handle "rt-server 8888" for back-compat, but complain about it
    if (@args && $args[0] =~ m/^\d+$/) {
        warn "Deprecated: please run $0 --port $ARGV[0] instead\n";
        unshift @args, '--port';
    }

    $self->SUPER::parse_options(@args);

    $self->{app}    ||= $self->app;
    $self->{server} ||= $self->loader->guess;

    my %args = @{$self->{options}};
    if ($self->{server} eq "FCGI") {
        # We deal with the possible failure modes of this in ->run
    } elsif ($args{port}) {
        $self->{explicit_port} = 1;
        my $old_app = $self->{app};
        $self->{app} = sub {
            my $env = shift;
            $env->{'rt.explicit_port'} = $args{port};
            $old_app->($env, @_);
        };
    } else {
        $self->set_options(port => (RT->Config->Get('WebPort') || '8080'));
    }
}

# Override to not default to port 5000
sub mangle_host_port_socket {
    my($self, $host, $port, $socket, @listen) = @_;

    for my $listen (reverse @listen) {
        if ($listen =~ /:\d+$/) {
            ($host, $port) = split /:/, $listen, 2;
            $host = undef if $host eq '';
        } else {
            $socket ||= $listen;
        }
    }

    unless (@listen) {
        if ($socket) {
            @listen = ($socket);
        } elsif ($port) {
            @listen = ($host ? "$host:$port" : ":$port");
        }
    }

    return host => $host, port => $port, listen => \@listen, socket => $socket;
}

sub prepare_devel {
    my($self, $app) = @_;
    # Don't install the Lint, StackTrace, and AccessLog middleware

    push @{$self->{options}}, server_ready => sub {
        my($args) = @_;
        my $name  = $args->{server_software} || ref($args);
        my $host  = $args->{host}  || RT->Config->Get('WebDomain');
        my $proto = $args->{proto} || 'http';
        print STDERR "$name: Accepting connections at $proto://$host:$args->{port}/\n";
    };

    $app;
}


sub app {
    require RT::Interface::Web::Handler;
    my $app = RT::Interface::Web::Handler->PSGIApp;

    if ($ENV{RT_TESTING}) {
        my $screen_logger = $RT::Logger->remove('screen');
        require Log::Dispatch::Perl;
        $RT::Logger->add(
            Log::Dispatch::Perl->new(
                name      => 'rttest',
                min_level => $screen_logger->min_level,
                action    => {
                    error    => 'warn',
                    critical => 'warn'
                }
            )
        );
        require Plack::Middleware::Test::StashWarnings;
        $app = Plack::Middleware::Test::StashWarnings->wrap($app);
    }

    return $app;
}

sub run {
    my $self = shift;

    my %args = @{$self->{options}};

    # Plack::Handler::FCGI has its own catch for this, but doesn't
    # notice that listen is an empty list, and we can also provide a
    # better error message.
    if ($self->{server} eq "FCGI" and not -S STDIN and not @{$args{listen}}) {
        print STDERR "STDIN is not a socket, and no --listen, --socket, or --port provided\n";
        exit 1;
    }

    eval { $self->SUPER::run(@_) };
    my $err = $@;
    exit 0 unless $err;

    if ( $err =~ /listen/ ) {
        print STDERR <<EOF;
WARNING: RT couldn't start up a web server on port $args{port}.
This is often the case if the port is already in use or you're running @{[$0]}
as someone other than your system's "root" user.  You may also specify a
temporary port with: $0 --port <port>
EOF

        if ($self->{explicit_port}) {
            print STDERR
                "Please check your system configuration or choose another port\n\n";
        }
        exit 1;
    } else {
        die
            "Something went wrong while trying to run RT's standalone web server:\n\t"
                . $err;
    }
}

1;
