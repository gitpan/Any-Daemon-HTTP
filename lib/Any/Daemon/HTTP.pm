# Copyrights 2013 by [Mark Overmeer].
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.01.
use warnings;
use strict;

package Any::Daemon::HTTP;
use vars '$VERSION';
$VERSION = '0.21';

use base 'Any::Daemon';

use Log::Report    'any-daemon-http';

use Any::Daemon::HTTP::VirtualHost ();
use Any::Daemon::HTTP::Session     ();

use HTTP::Daemon   ();
use HTTP::Status   qw/:constants :is/;
use IO::Socket     qw/SOCK_STREAM SOMAXCONN/;
use File::Basename qw/basename/;
use File::Spec     ();
use Scalar::Util   qw/blessed/;


sub _to_list($) { ref $_[0] eq 'ARRAY' ? @{$_[0]} : defined $_[0] ? $_[0] : () }
sub init($)
{   my ($self, $args) = @_;
    $self->SUPER::init($args);

    my $host = $args->{host};
    my ($use_ssl, $socket);
    if($socket = $args->{socket})
    {   $use_ssl = $socket->isa('IO::Socket::SSL');
        $host  ||= $socket->sockhost;
    }
    else
    {   $use_ssl = $args->{use_ssl};
        my $sock_class = $use_ssl ? 'IO::Socket::SSL' : 'IO::Socket::INET';
        eval "require $sock_class" or panic $@;

        $host or error __x"host or socket required for {pkg}::new()"
           , pkg => ref $self;

        $socket  = $sock_class->new
          ( LocalHost => $host
          , Listen    => SOMAXCONN
          , Reuse     => 1
          , Type      => SOCK_STREAM
          ) or fault "cannot create socket at $host";
    }

    my $conn_class = 'HTTP::Daemon::ClientConn';
    if($use_ssl)
    {   $conn_class .= '::SSL';
        eval "require $conn_class" or panic $@;
    }
    $self->{ADH_conn_class} = $conn_class;

    $self->{ADH_session_class}
      = $args->{session_class} || 'Any::Daemon::HTTP::Session';

    $self->{ADH_ssl}     = $use_ssl;
    $self->{ADH_socket}  = $socket;
    $self->{ADH_host}    = $host;

    $self->{ADH_vhosts}  = {};
    $self->addVirtualHost($_)
        for _to_list $args->{vhosts};

    !$args->{docroot}
        or error __x"docroot parameter has been removed in v0.11";

    $self->{ADH_server}  = $args->{server_id} || basename($0);
    $self->{ADH_headers} = $args->{standard_headers} || [];
    $self->{ADH_error}   = $args->{on_error}  || sub { $_[1] };

    # "handlers" is probably a common typo
    my $handler = $args->{handler} || $args->{handlers};
    $self->addVirtualHost
      ( name      => $host
      , aliases   => ['default']
      , documents => $args->{documents}
      , handler   => $handler
      ) if $args->{documents} || $handler;

    $self;
}

#----------------

sub useSSL() {shift->{ADH_ssl}}
sub host()   {shift->{ADH_host}}
sub socket() {shift->{ADH_socket}}

#-------------

sub addVirtualHost(@)
{   my $self   = shift;
    my $config = @_==1 ? shift : {@_};
    my $vhost;
    if(UNIVERSAL::isa($config, 'Any::Daemon::HTTP::VirtualHost'))
    {   $vhost = $config;
    }
    elsif(UNIVERSAL::isa($config, 'HASH'))
    {   $vhost = Any::Daemon::HTTP::VirtualHost->new($config);
    }
    else
    {   error __x"virtual configuration not a valid object not HASH";
    }

    info __x"adding virtual host {name}", name => $vhost->name;

    $self->{ADH_vhosts}{$_} = $vhost
        for $vhost->name, $vhost->aliases;

    $vhost;
}


sub removeVirtualHost($)
{   my ($self, $id) = @_;
    my $vhost = blessed $id && $id->isa('Any::Daemon::HTTP::VirtualHost')
       ? $id : $self->virtualHost($id);
    defined $vhost or return;

    delete $self->{ADH_vhosts}{$_}
        for $vhost->name, $vhost->aliases;
    $vhost;
}


sub virtualHost($) { $_[0]->{ADH_vhosts}{$_[1]} }

#-------------------

sub _connection($$)
{   my ($self, $client, $args) = @_;

    # Ugly hack, steal HTTP::Daemon's http/1.1 implementation
    bless $client, $self->{ADH_conn_class};
    ${*$client}{httpd_daemon} = $self;

    my $session = $self->{ADH_session_class}->new(client => $client);
    my $peer    = $session->get('peer');
    info __x"new client from {host} on {ip}"
       , host => $peer->{host}, ip => $peer->{ip};

    $args->{new_connection}->($self, $session);

    while(my $req  = $client->get_request)
    {   my $vhostn = $req->header('Host') || 'default';
        my $vhost  = $vhostn
            ? $self->virtualHost($vhostn) : $self->virtualHost('default');

        my $resp;
        if($vhost)
        {   $self->{ADH_current_vhost} = $vhost;
            $resp = $vhost->handleRequest($self, $session, $req);
        }
        else
        {   $resp = HTTP::Response->new(HTTP_NOT_ACCEPTABLE,
               "virtual host $vhostn is not available");
        }

        unless($resp)
        {   notice __x"no response produced for {uri}", uri => $req->uri;
            $resp = HTTP::Response->new(HTTP_SERVICE_UNAVAILABLE);
        }

        $resp->push_header(@{$self->{ADH_headers}});
        $resp->request($req);

        # No content, then produce something better than an empty page.
        if(is_error($resp->code))
        {   $resp = $self->{ADH_error}->($self, $resp, $session, $req);
            $resp->content or $resp->content($resp->status_line);
        }

        $client->send_response($resp);
    }
}

sub run(%)
{   my ($self, %args) = @_;

    $args{new_connection} ||= sub {};

    my $vhosts = $self->{ADH_vhosts};
    keys %$vhosts
        or $self->addVirtualHost
          ( name      => $self->host
          , aliases   => 'default'
          );

    # option handle_request is deprecated in 0.11
    if(my $handler = delete $args{handle_request})
    {   my (undef, $first) = %$vhosts;
        $first->addHandler('/' => $handler);
    }

    $args{child_task} ||=  sub {
        while(my $client = $self->socket->accept)
        {   $self->_connection($client, \%args);
            $client->close;
        }
        exit 0;
    };

    $self->SUPER::run(%args);
}

# HTTP::Daemon methods used by ::ClientConn.  The names are not compatible
# with MarkOv convention, so hidden for the users of this module
sub url()
{   my $self  = shift;
    my $vhost = $self->{ADH_current_vhost} or return undef;
    ($self->useSSL ? 'https' : 'http').'://'.$vhost->name;
}
sub product_tokens() {shift->{ADH_server}}

1;
