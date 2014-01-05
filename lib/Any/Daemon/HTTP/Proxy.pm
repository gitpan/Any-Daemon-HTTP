# Copyrights 2013-2014 by [Mark Overmeer].
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.01.
use warnings;
use strict;

package Any::Daemon::HTTP::Proxy;
use vars '$VERSION';
$VERSION = '0.24';

use parent 'Any::Daemon::HTTP::Source';

use Log::Report    'any-daemon-http';

use LWP::UserAgent ();
use HTTP::Status   qw(HTTP_TOO_MANY_REQUESTS);


sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);

    $self->{ADHDP_ua}  = $args->{user_agent}
      || LWP::UserAgent->new(keep_alive => 30);

    $self->{ADHDP_via} = $args->{via};
    if(my $fm = $args->{forward_map})
    {   $self->{ADHDP_map}   = $fm eq 'RELAY' ? sub {$_[3]} : $fm;
    }

    if(my $rem = $args->{remote_proxy})
    {   $self->{ADHDP_proxy} = ref $rem eq 'CODE' ? $rem : sub {$rem};
    }

    my @prepare  =
      ( $self->stripHeaders($args->{strip_req_headers})
      , $self->addHeaders  ($args->{add_req_headers})
      , $args->{change_request} || ()
      );
    

    my @postproc =
      ( $self->stripHeaders($args->{strip_resp_headers})
      , $self->addHeaders  ($args->{add_resp_headers})
      , $args->{change_response} || ()
      );

    $self->{ADHDP_prepare}  = \@prepare;
    $self->{ADHDP_postproc} = \@postproc;
    $self;
}

#-----------------

sub userAgent() {shift->{ADHDP_ua}}
sub via()       {shift->{ADHDP_via}}
sub forwardMap(){shift->{ADHDP_map}}


sub remoteProxy(@)
{   my $rem = shift->{ADHDP_proxy};
    $rem ? $rem->(@_) : undef;
}

#-----------------

sub _collect($$$$)
{   my ($self, $vhost, $session, $req, $rel_uri) = @_;

    my $tohost = $req->header('Host') || $vhost->name;

    #XXX MO: need to support https as well
    my $uri    = URI->new_abs($rel_uri, "http://$tohost");

    # Via: RFC2616 section 14.45
    my $my_via = '1.1 ' . ($self->via // $uri->host_port);
    if(my $via = $req->header('Via'))
    {   foreach (split /\,\s+/, $via)
        {   return HTTP::Response->new(HTTP_TOO_MANY_REQUESTS)
                if $_ ne $my_via;
        }
        $req->header(Via => "$via, $my_via");
    }
    else
    {   $req->push_header(Via => $my_via);
    }

    $self->$_($req, $uri) for @{$self->{ADHDP_prepare}};

    my $ua   = $self->userAgent;
    $req->uri($uri);
    if(my $proxy = $self->remoteProxy($session, $req))
    {   $self->proxify($req, $uri);
        $ua->proxy($uri->scheme, $proxy);
    }
    else
    {   $ua->proxy($uri->scheme, undef);
    }

    info __x"request {method} {uri}", method => $req->method, uri => "$uri";
    my $resp = $ua->request($req);

    $self->$_($resp, $uri) for @{$self->{ADHDP_postproc}};
    $resp;
}


sub stripHeaders(@)
{   my $self = shift;
    my @strip;
    foreach my $field (@_ > 1 ? @_ : ref $_[0] eq 'ARRAY' ? @{$_[0]} : shift)
    {   push @strip
          , !ref $field           ? sub {$_[0]->remove_header($field)}
          : ref $field eq 'CODE'  ? $field
          : ref $field eq 'Regex' ? sub {
                my @kill = grep $_ =~ $field, $_[0]->header_field_names;
                $_[0]->remove_header($_) for @kill;
            }
          : panic "do not understand $field";
    }

    @strip or return;
    sub { my $header = $_[1]->headers; $_->($header) for @strip };
}


sub addHeaders($@)
{   my $self  = shift;
    return if @_==1 && ref $_[0] eq 'CODE';

    my @pairs = @_ > 1 ? @_ : defined $_[0] ? @{$_[0]} : ();
    @pairs or return sub {};

    sub { $_[1]->push_header(@pairs) };
}


sub proxify($$)
{   my ($self, $request, $uri) = @_;
    $request->uri($uri);
    $request->header(Host => $uri->authority);
}


sub forwardRewrite($$$)
{   my ($self, $session, $req, $uri) = @_;
    $self->allow($session, $req, $uri) or return;
    my $mapper = $self->forwardMap     or return;
    $mapper->(@_);
}


sub forwardRequest($$$)
{   my ($self, $session, $req, $uri) = @_;
    $self->_collect(undef, $session, $req, $uri);
}

1;

__END__
