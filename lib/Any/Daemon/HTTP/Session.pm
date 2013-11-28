# Copyrights 2013 by [Mark Overmeer].
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.01.
use strict;
use warnings;

package Any::Daemon::HTTP::Session;
use vars '$VERSION';
$VERSION = '0.23';


use Log::Report    'any-daemon-http';

use Socket         qw(inet_aton AF_INET);


sub new(%)  {my $class = shift; (bless {}, $class)->init({@_})}
sub init($)
{   my ($self, $args) = @_;
    my $client = $self->{ADHC_store} = $args->{client} or panic;
    my $store  = $self->{ADHC_store} = $args->{store} || {};

    my $peer   = $store->{peer}    ||= {};
    my $ip     = $peer->{ip}       ||= $client->peerhost;
    $peer->{host} = gethostbyaddr inet_aton($ip), AF_INET;

    $self;
}

#-----------------

sub client() {shift->{ADHC_client}}
sub get(@)   {my $s = shift->{ADHC_store}; wantarray ? @{$s}{@_} : $s->{$_[0]}}
sub set($$)  {$_[0]->{ADHC_store}{$_[1]} = $_[2]}

# should not be used
sub _store() {shift->{ADHC_store}}

1;
