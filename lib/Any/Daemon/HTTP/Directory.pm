# Copyrights 2013 by [Mark Overmeer].
#  For other contributors see ChangeLog.
# See the manual pages for details on the licensing terms.
# Pod stripped from pm file by OODoc 2.01.
use warnings;
use strict;

package Any::Daemon::HTTP::Directory;
use vars '$VERSION';
$VERSION = '0.20';

use Log::Report  'any-daemon-http';

use Net::CIDR      qw/cidrlookup/;
use File::Spec     ();
use Fcntl          qw/:mode/;
use POSIX          qw/strftime/;
use HTTP::Status   qw/:constants/;
use HTTP::Response ();
use Encode         qw/encode/;
use MIME::Types    ();
use List::Util     qw/first/;

my $mimetypes = MIME::Types->new(only_complete => 1);

sub _allow_cleanup($);
sub _allow_match($$$$);
sub _filename_trans($$);


sub new(@)
{   my $class = shift;
    my $args  = @_==1 ? shift : +{@_};
    (bless {}, $class)->init($args);
}

sub init($)
{   my ($self, $args) = @_;

    my $path = $self->{ADHD_path}  = $args->{path} || '/';
    my $loc  = $args->{location}
        or error __x"directory definition requires location";

    my $trans;
    if(ref $loc eq 'CODE')
    {   $trans = $loc;
        undef $loc;
    }
    else
    {   File::Spec->file_name_is_absolute($loc)
           or error __x"directory location {loc} for path {path} not absolute"
                , loc => $loc, path => $path;
        substr($loc, -1) eq '/' or $loc .= '/';
        $trans = _filename_trans $path, $loc;

        -d $loc
            or error __x"directory location {loc} for {path} does not exist"
                 , loc => $loc, path => $path;
    }

    $self->{ADHD_loc}   = $loc;
    $self->{ADHD_fn}    = $trans;
    $self->{ADHD_allow} = _allow_cleanup $args->{allow};
    $self->{ADHD_deny}  = _allow_cleanup $args->{deny};
    $self->{ADHD_dirlist} = $args->{directory_list} || 0;

    my $if = $args->{index_file};
    my @if = ref $if eq 'ARRAY' ? @$if
           : defined $if        ? $if
           : qw/index.html index.html/;
    $self->{ADHD_indexfns} = \@if;
    $self;
}

#-----------------

sub path()     {shift->{ADHD_path}}
sub location() {shift->{ADHD_location}}

#-----------------

sub allow($$$$)
{   my ($self, $session, $req, $uri) = @_;
    if(my $allow = $self->{ADHD_allow})
    {   $self->_allow_match($session, $uri, $allow) or return 0;
    }
    if(my $deny = $self->{ADHD_deny})
    {    $self->_allow_match($session, $uri, $deny) and return 0;
    }
    1;
}

sub _allow_match($$$$)
{   my ($self, $session, $uri, $rules) = @_;
    my ($ip, $host) = $session->get(qw/peer_ip peer_host/);
    first { $_->($ip, $host, $session, $uri) } @$rules;
}

sub _allow_cleanup($)
{   my $p = shift or return;
    my @p;
    foreach my $r (ref $p eq 'ARRAY' ? @$p : $p)
    {   push @p
          , ref $r eq 'CODE'      ? $r
          : index($r, ':') >= 0   ? sub {cidrlookup $_[0], $r}    # IPv6
          : $r !~ m/[a-zA-Z]/     ? sub {cidrlookup $_[0], $r}    # IPv4
          : substr($r,0,1) eq '.' ? sub {$_[1] =~ qr/(^|\.)\Q$r\E$/i} # Domain
          :                         sub {lc($_[1]) eq lc($r)}     # hostname
    }
    @p ? \@p : undef;
}


sub filename($) { $_[0]->{ADHD_fn}->($_[1]) }

sub _filename_trans($$)
{   my ($path, $loc) = @_;
    return $loc if ref $loc eq 'CODE';
    sub
      { my $x = shift;
        $x =~ s!^\Q$path!$loc! or panic "path $x not inside $path";
        $x;
      };
}


sub fromDisk($$$)
{   my ($self, $session, $req, $uri) = @_;

    # first check access rights
    $self->allow($session, $req, $uri)
        or return HTTP::Response->new(HTTP_FORBIDDEN);

    my $item = $self->filename($uri);

    # soft-fail when the item does not exists
    -e $item or return;

    return $self->_file_response($req, $item)
        if -f _;

    return HTTP::Response->new(HTTP_FORBIDDEN)
        if ! -d _;     # neither file nor directory

    return HTTP::Response->new(HTTP_TEMPORARY_REDIRECT, undef
      , [Location => $uri.'/'])
        if substr($item, -1) ne '/';

    foreach my $if (@{$self->{ADHD_indexfns}})
    {   -f $item.$if or next;
         return $self->_file_response($req, $item.$if);
    }

    $self->{ADHD_dirlist}
        or return HTTP::Response->new(HTTP_FORBIDDEN, "no directory lists");

    $self->_list_response($req, $uri, $item);
}

sub _file_response($$)
{   my ($self, $req, $fn) = @_;

    -f $fn
        or return HTTP::Response->new(HTTP_NOT_FOUND);

    my $mtime     = (stat $fn)[9];
    my $has_mtime = $req->if_modified_since;
    return HTTP::Response->new(HTTP_NOT_MODIFIED)
        if defined $has_mtime && $has_mtime >= $mtime;

    open my($fh), '<:raw', $fn
        or return HTTP::Response->new(HTTP_FORBIDDEN);

    my $ct;
    if(my $mime = $mimetypes->mimeTypeOf($fn))
    {   $ct  = $mime->type;
        $ct .= "; charset='utf8'" if $mime->isAscii;
    }
    else
    {   $ct  = 'binary/octet-stream';
    }

    local $/;
    my $resp = HTTP::Response
       ->new(HTTP_OK, undef, ['Content-Type' => $ct], <$fh>);
    $resp->last_modified($mtime);
    $resp;
}

sub _list_response($$$)
{   my ($self, $req, $uri, $dir) = @_;

    no warnings 'uninitialized';

    my $list = $self->list($dir);

    my $now  = localtime;
    my @rows;
    push @rows, <<__UP if $dir ne '/';
<tr><td colspan="5">&nbsp;</td><td><a href="../">(up)</a></td></tr>
__UP

    foreach my $item (sort keys %$list)
    {   my $d = $list->{$item};
        push @rows, <<__ROW;
<tr><td>$d->{flags}</td>
    <td>$d->{user}</td>
    <td>$d->{group}</td>
    <td align="right">$d->{size_nice}</td>
    <td>$d->{mtime_nice}</td>
    <td><a href="$d->{name}">$d->{name}</a></td></tr>
__ROW
    }

    local $" = "\n";
    my $content = encode 'utf8', <<__PAGE;
<html><head><title>$dir</title></head>
<style>TD { padding: 0 10px; }</style>
<body>
<h1>Directory $dir</h1>
<table>
@rows
</table>
<p><i>Generated $now</i></p>
</body></html>
__PAGE

    HTTP::Response->new(HTTP_OK, undef
      , ['Content-Type' => 'text/html; charset="utf8"']
      , $content
      );
}


my %filetype =
  ( &S_IFSOCK => 's', &S_IFLNK => 'l', &S_IFREG => '-', &S_IFBLK => 'b'
  , &S_IFDIR  => 'd', &S_IFCHR => 'c', &S_IFIFO => 'p');

my @flags    = ('---', '--x', '-w-', '-wx', 'r--', 'r-x', 'rw-', 'rwx');
    
my @stat_fields =
   qw/dev ino mode nlink uid gid rdev size atime mtime ctime blksize blocks/;

sub list($@)
{   my ($self, $dirname, %opts) = @_;

    opendir my $from_dir, $dirname
        or return;

    my $names      = $opts{names} || qr/^[^.]/;
    my $prefilter
       = ref $names eq 'Regexp' ? sub { $_[0] =~ $names }
       : ref $names eq 'CODE'   ? $names
       : panic "::Directory::list(names) must be regexp or code, not $names";

    my $postfilter = $opts{filter} || sub {1};
    ref $postfilter eq 'CODE'
        or panic "::Directory::list(filter) must be code, not $postfilter";

    my $hide_symlinks = $opts{hide_symlinks};

    my (%dirlist, %users, %groups);
    foreach my $name (grep $prefilter->($_), readdir $from_dir)
    {   my $path = $dirname.$name;
        my %d    = (name => $name, path => $path);
        @d{@stat_fields}
            = $hide_symlinks ? stat($path) : lstat($path);

           if(!$hide_symlinks && -l _)
                    { @d{qw/kind is_symlink  /} = ('SYMLINK',  1)}
        elsif(-d _) { @d{qw/kind is_directory/} = ('DIRECTORY',1)}
        elsif(-f _) { @d{qw/kind is_file     /} = ('FILE',     1)}
        else        { @d{qw/kind is_other    /} = ('OTHER',    1)}

        $postfilter->(\%d)
            or next;

        if($d{is_symlink})
        {   my $sl = $d{symlink_dest} = readlink $path;
            $d{symlink_dest_exists} = -e $sl;
        }
        elsif($d{is_file})
        {   my ($s, $l) = ($d{size}, '  ');
            ($s,$l) = ($s/1024, 'kB') if $s > 1024;
            ($s,$l) = ($s/1024, 'MB') if $s > 1024;
            ($s,$l) = ($s/1024, 'GB') if $s > 1024;
            $d{size_nice} = sprintf +($s>=100?"%.0f%s":"%.1f%s"), $s,$l;
        }
        elsif($d{is_directory})
        {   $d{name} .= '/';
        }

        if($d{is_file} || $d{is_directory})
        {   $d{user}  = $users{$d{uid}} ||= getpwuid $d{uid};
            $d{group} = $users{$d{gid}} ||= getgrgid $d{gid};
            my $mode = $d{mode};
            my $b = $filetype{$mode & S_IFMT} || '?';
            $b   .= $flags[ ($mode & S_IRWXU) >> 6 ];
            substr($b, -1, -1) = 's' if $mode & S_ISUID;
            $b   .= $flags[ ($mode & S_IRWXG) >> 3 ];
            substr($b, -1, -1) = 's' if $mode & S_ISGID;
            $b   .= $flags[  $mode & S_IRWXO ];
            substr($b, -1, -1) = 't' if $mode & S_ISVTX;
            $d{flags}      = $b;
            $d{mtime_nice} = strftime "%F %T", localtime $d{mtime};
        }
        $dirlist{$name} = \%d;
    }
    \%dirlist;
}

#-----------------------

1;
