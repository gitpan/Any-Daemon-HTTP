# Copyrights 2013 by [Mark Overmeer].
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.01.
use warnings;
use strict;

package Any::Daemon::HTTP::VirtualHost;
use vars '$VERSION';
$VERSION = '0.20';

use Log::Report    'any-daemon-http';

use Any::Daemon::HTTP::Directory;
use Any::Daemon::HTTP::UserDirs;

use HTTP::Status qw/:constants/;
use List::Util   qw/first/;
use English      qw/$EUID/;
use File::Spec   ();
use POSIX        qw(strftime);
use Scalar::Util qw(blessed);


sub new(@)
{   my $class = shift;
    my $args  = @_==1 ? shift : {@_};
    (bless {}, $class)->init($args);
}

sub init($)
{   my ($self, $args) = @_;

    my $name = $self->{ADHV_name} = $args->{name};
    defined $name
        or error __x"virtual host {pkg} has no name", pkg => ref $self;

    my $aliases = $args->{aliases}            || [];
    $self->{ADHV_aliases} = ref $aliases eq 'ARRAY' ? $aliases : [$aliases];
    $self->{ADHV_rewrite} = $args->{rewrite}  || sub {$_[0]};
    $self->{ADHV_dirlist} = $args->{directory_list};
    $self->{ADHV_handlers} = $args->{handler} || $args->{handlers} || {};

    $self->{ADHV_dirs}     = {};
    if(my $docroot = $args->{documents})
    {   File::Spec->file_name_is_absolute($docroot)
            or error __x"vhost {name} documents directory must be absolute"
                 , name => $name;
        -d $docroot
            or error __x"vhost {name} documents `{dir}' must point to dir"
                 , name => $name, dir => $docroot;
        $docroot =~ s/\\$//; # strip trailing / if present
        $self->addDirectory(path => '/', location => $docroot);
    }
    my $dirs = $args->{directories} || [];
    $self->addDirectory($_) for ref $dirs eq 'ARRAY' ? @$dirs : $dirs;

    if(my $ud = $args->{user_dirs})
    {   if(ref $ud eq 'HASH')
        {   $ud = Any::Daemon::HTTP::UserDirs->new($ud) }
        elsif(! $ud->isa('Any::Daemon::HTTP::UserDirs'))
        {   error __x"vhost {name} user_dirs is not an ::UserDirs object"
              , name => $self->name;
        }
        $self->{ADHV_udirs} = $ud;
    }
    $self;
}

#---------------------

sub name()    {shift->{ADHV_name}}
sub aliases() {@{shift->{ADHV_aliases}}}

#---------------------

sub addHandler(@)
{   my $self = shift;
    my @pairs
       = @_ > 1              ? @_
       : ref $_[0] eq 'HASH' ? %{$_[0]}
       :                       ( '/' => $_[0]);
    
    my $h = $self->{ADHV_handlers} ||= {};
    while(@pairs)
    {   my $k    = shift @pairs;
        index($k, 0, 1) eq '/'
            or error __x"handler path must be absolute, for {rel} in {vhost}"
                 , rel => $k, vhost => $self->host;

        $h->{$k} = shift @pairs;
    }
    $h;
}


sub findHandler(@)
{   my $self = shift;
    my @path = @_>1 ? @_ : ref $_[0] ? $_[0]->path_segments : split('/', $_[0]);

    my $h = $self->{ADHV_handlers} ||= {};
    while(@path)
    {   my $handler = $h->{join '/', @path};
        return $handler if $handler;
        pop @path;
    }
    
    sub {HTTP::Response->new(HTTP_NOT_FOUND)}
}


#-----------------


sub handleRequest($$$;$)
{   my ($self, $server, $session, $req, $uri) = @_;

    $uri      ||= $req->uri;
    my $new_uri = $self->rewrite($uri);
    if($new_uri ne $uri)
    {   info $req->id." rewritten to $uri";
        return HTTP::Response->new(HTTP_TEMPORARY_REDIRECT
           , '', [Location => $uri]);
    }

    my $path = $uri->path;
    my @path = $uri->path_segments;
    my $tree = $self->directoryOf(@path);
    my $resp = $tree ? $tree->fromDisk($session, $req, $uri) : undef;
    $resp || $self->findHandler(@path)->($session, $req, $uri, $self, $tree);
}

#----------------------

sub rewrite($) { $_[0]->{ADHV_rewrite}->($_[1]) }


sub allow($$$)
{   my ($self, $session, $req, $uri) = @_;

    if($EUID==0 && substr($uri->path, 0, 2) eq '/~')
    {   notice __x"daemon running as root, only access to {path}"
          , path => '/~user';
        return 0;
    }

    1;
}

#------------------

sub filename($)
{   my ($self, $uri) = @_;
    my $dir = $self->directoryOf($uri);
    $dir ? $dir->filename($uri->path) : undef;
}


sub addDirectory(@)
{   my $self = shift;
    my $dir  = @_==1 && blessed $_[0] ? shift
       : Any::Daemon::HTTP::Directory->new(@_);

    my $path = $dir->path || '';
    !exists $self->{ADHV_dirs}{$path}
        or error __x"vhost {name} directory `{path}' defined twice"
             , name => $self->name, path => $path;
    $self->{ADHV_dirs}{$path} = $dir;
}


sub directoryOf(@)
{   my $self  = shift;
    my @path  = @_>1 || index($_[0], '/')==-1 ? @_ : split('/', $_[0]);

    return $self->{ADHV_udirs}
        if substr($path[0], 0, 1) eq '~';

    my $dirs = $self->{ADHV_dirs};
    while(@path)
    {   my $dir = $dirs->{join '/', @path};
        return $dir if $dir;
        pop @path;
    }
    $dirs->{'/'} ? $dirs->{'/'} : ();
}

#-----------------------------


1;
