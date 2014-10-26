# Copyrights 2013-2014 by [Mark Overmeer].
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.01.
use warnings;
use strict;

package Any::Daemon::HTTP::UserDirs;
use vars '$VERSION';
$VERSION = '0.24';

use parent 'Any::Daemon::HTTP::Directory';

use Log::Report    'any-daemon-http';


sub init($)
{   my ($self, $args) = @_;

    my $subdirs = $args->{user_subdirs} || 'public_html';
    my %allow   = map +($_ => 1), @{$args->{allow_users} || []};
    my %deny    = map +($_ => 1), @{$args->{deny_users}  || []};
    $args->{location} ||= $self->userdirRewrite($subdirs, \%allow, \%deny);

    $self->SUPER::init($args);
    $self;
}

#-----------------

sub userdirRewrite($$$)
{   my ($self, $udsub, $allow, $deny) = @_;
    my %homes;  # cache
    sub { my $path = shift;
          my ($user, $pathinfo) = $path =~ m!^/\~([^/]*)(.*)!;
          return if keys %$allow && !$allow->{$user};
          return if keys %$deny  &&  $deny->{$user};
          return if exists $homes{$user} && !defined $homes{$user};
          my $d = $homes{$user} ||= (getpwnam $user)[7];
          $d ? "$d/$udsub$pathinfo" : undef;
        };
}

1;
