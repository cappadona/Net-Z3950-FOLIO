package Net::Z3950::FOLIO;

use 5.008000;
use strict;
use warnings;

use IO::File;
use Cpanel::JSON::XS qw(decode_json encode_json);
use Net::Z3950::SimpleServer;
use ZOOM; # For ZOOM::Exception
use LWP::UserAgent;
use MARC::Record;
use URI::Escape;
use XML::Simple;

use Net::Z3950::FOLIO::ResultSet;

our $VERSION = '0.01';

1;


=head1 NAME

Net::Z3950::FOLIO - Z39.50 server for FOLIO bibliographic data

=head1 SYNOPSIS

 use Net::Z3950::FOLIO;
 $service = new Net::Z3950::FOLIO('config.json');
 $service->launch_server("someServer", @ARGV);

=head1 DESCRIPTION

The C<Net::Z3950::FOLIO> module provides all the application logic of
a Z39.50 server that allows searching in and retrieval from the
inventory module of FOLIO.  It is used by the C<z2folio> program, and
there is probably no good reason to make any other program to use it.

The library has only two public entry points: the C<new()> constructor
and the C<launch_server()> method.  The synopsis above shows how they
are used: a Net::Z3950::FOLIO object is created using C<new()>, then
the C<launch_server()> method is invoked on it to start the server.
(In fact, this synopsis is essentially the whole of the code of the
C<simple2zoom> program.  All the work happens inside the library.)

=head1 METHODS

=head2 new($configFile)

 $s2z = new Net::Z3950::FOLIO('config.json');

Creates and returns a new Net::Z3950::FOLIO object, configured according to
the JSON file C<$configFile> that is the only argument.  The format of
this file is described in C<Net::Z3950::FOLIO::Config>.

=cut

sub new {
    my $class = shift();
    my($cfgfile) = @_;

    my $this = bless {
	cfgfile => $cfgfile || 'config.json',
	cfg => undef,
	ua => new LWP::UserAgent(),
	token => undef,
    }, $class;

    $this->{ua}->agent("z2folio $VERSION");
    $this->_reload_config_file();

    $this->{server} = Net::Z3950::SimpleServer->new(
	GHANDLE => $this,
	INIT =>    \&_init_handler,
	SEARCH =>  \&_search_handler,
	FETCH =>   \&_fetch_handler,
	DELETE =>  \&_delete_handler,
#	SCAN =>    \&_scan_handler,
#	SORT   =>  \&_sort_handler,
    );

    return $this;
}


sub _reload_config_file {
    my $this = shift();

    my $cfgfile = $this->{cfgfile};
    my $fh = new IO::File("<$cfgfile")
	or die "$0: can't open config file '$cfgfile': $!";
    my $json; { local $/; $json = <$fh> };
    $fh->close();

    $this->{cfg} = decode_json($json);
}


sub _init_handler { _eval_wrapper(\&_real_init_handler, @_) }
sub _search_handler { _eval_wrapper(\&_real_search_handler, @_) }
sub _fetch_handler { _eval_wrapper(\&_real_fetch_handler, @_) }
sub _delete_handler { _eval_wrapper(\&_real_delete_handler, @_) }


sub _eval_wrapper {
    my $coderef = shift();
    my $args = shift();

    eval {
	&$coderef($args, @_);
    }; if (ref $@ && $@->isa('ZOOM::Exception')) {
	if ($@->diagset() eq 'Bib-1') {
	    $args->{ERR_CODE} = $@->code();
	    $args->{ERR_STR} = $@->addinfo();
	} else {
	    $args->{ERR_CODE} = 100;
	    $args->{ERR_STR} = $@->message() || $@->addinfo();
	}
    } elsif ($@) {
	# Non-ZOOM exceptions may be generated by the Perl
	# interpreter, for example if we try to call a method that
	# does not exist in the relevant class.  These should be
	# considered fatal and not reported to the client.
	die $@;
    }
}


sub _real_init_handler {
    my($args) = @_;
    my $this = $args->{GHANDLE};

    $this->_reload_config_file();

    my $user = $args->{USER};
    my $pass = $args->{PASS};
    $args->{HANDLE} = {
	username => $user || '',
	password => $pass || '',
	resultsets => {},  # result sets, indexed by setname
    };

    $args->{IMP_ID} = '81';
    $args->{IMP_VER} = $Net::Z3950::FOLIO::VERSION;
    $args->{IMP_NAME} = 'z2folio gateway';

    my $cfg = $this->{cfg};
    my $login = $cfg->{login} || {};
    my $username = $user || $login->{username};
    my $password = $pass || $login->{password};
    _throw(1014, "credentials not supplied")
	if !defined $username || !defined $password;

    my $url = $cfg->{okapi}->{url} . '/bl-users/login';
    my $req = $this->_make_http_request(POST => $url);
    $req->content(qq[{ "username": "$username", "password": "$password" }]);
    # warn "req=", $req->content();
    my $res = $this->{ua}->request($req);
    # warn "res=", $res->content();
    _throw(1014, $res->content())
	if !$res->is_success();
    $this->{token} = $res->header('X-Okapi-token');
}


sub _real_search_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};
    my $this = $args->{GHANDLE};

    # For now, we ignore the dbname. In the future we will use this as
    # the tenant ID, which will mean postponing the authentication
    # call from the Init handler to now, when we first discover the
    # dbname.

    my $cql;
    if ($args->{CQL}) {
	$cql = $args->{CQL};
    } else {
	my $type1 = $args->{RPN}->{query};
	$cql = $type1->_toCQL($args, $args->{RPN}->{attributeSet});
	warn "search: translated '" . $args->{QUERY} . "' to '$cql'\n";
    }

    my $setname = $args->{SETNAME};
    my $rs = new Net::Z3950::FOLIO::ResultSet($setname, $cql);
    $session->{resultsets}->{$setname} = $rs;

    my $chunkSize = $this->{cfg}->{chunkSize} || 10;
    $this->_do_search($rs, 0, $chunkSize);
    $args->{HITS} = $rs->total_count();
}


sub _real_fetch_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};
    my $this = $args->{GHANDLE};

    my $rs = $session->{resultsets}->{$args->{SETNAME}};
    _throw(30, $args->{SETNAME}) if !$rs; # Result set does not exist

    my $index1 = $args->{OFFSET};
    _throw(13, $index1) if $index1 < 1 || $index1 > $rs->total_count();

    my $rec = $rs->record($index1);
    if (!defined $rec) {
	# We need to fetch a chunk of records that contains the
	# requested one. We'll do this by splitting the whole set into
	# chunks of the specified size, and fetching the one that
	# contains the requested record.
	my $index0 = $index1 - 1;
	my $chunkSize = $this->{cfg}->{chunkSize} || 10;
	my $chunk = int($index0 / $chunkSize);
	$this->_do_search($rs, $chunk * $chunkSize, $chunkSize);
	$rec = $rs->record($index1);
	_throw(1, "missing record") if !defined $rec;
    }

    my $xml;
    {
	# I have no idea why this generates an "uninitialized value" warning
	local $SIG{__WARN__} = sub {};
	$xml = XMLout($rec, NoAttr => 1);
    }
    $xml =~ s/<@/<__/;
    $xml =~ s/<\/@/<\/__/;

    $args->{REP_FORM} = 'xml';
    $args->{RECORD} = $xml;
    return;

}


sub _real_delete_handler {
    my($args) = @_;
    my $session = $args->{HANDLE};
    my $this = $args->{GHANDLE};

    my $setname = $args->{SETNAME};
    my $rs = $session->{resultsets}->{$setname};

    # XXX Delete errors are ignored by SimpleServer, but we do the right thing anyway
    _throw(30, $args->{SETNAME}) if !$rs;

    $session->{resultsets}->{$setname} = undef;
    return;
}


sub _do_search {
    my $this = shift();
    my($rs, $offset, $limit) = @_;
    warn "_do_search($offset, $limit)";

    my $escapedQuery = uri_escape($rs->{cql});
    my $url = $this->{cfg}->{okapi}->{url} . "/inventory/instances?offset=$offset&limit=$limit&query=$escapedQuery";
    my $req = $this->_make_http_request(GET => $url);
    my $res = $this->{ua}->request($req);
    # warn "searching at $url";
    # warn "result: ", $res->content();
    _throw(3, $res->content()) if !$res->is_success();

    my $obj = decode_json($res->content());
    $rs->total_count($obj->{totalRecords} + 0);
    $rs->insert_records($offset, $obj->{instances});

    return $rs;
}


=head2 launch_server($label, @ARGV)

 $s2z->launch_server("someServer", @ARGV);

Launches the Net::Z3950::FOLIO server: this method never returns.  The
C<$label> string is used in logging, and the C<@ARGV> vector of
command-line arguments is interpreted by the YAZ backend server as
described at
https://software.indexdata.com/yaz/doc/server.invocation.html

=cut

sub launch_server {
    my $this = shift();
    my($label, @argv) = @_;

    return $this->{server}->launch_server($label, @argv);
}


sub _make_http_request() {
    my $this = shift();
    my(%args) = @_;

    my $req = new HTTP::Request(%args);
    $req->header('X-Okapi-tenant' => $this->{cfg}->{okapi}->{tenant});
    $req->header('Content-type' => 'application/json');
    $req->header('Accept' => 'application/json');
    $req->header('X-Okapi-token' => $this->{token}) if $this->{token};
    return $req;
}


sub _throw {
    my($code, $addinfo, $diagset) = @_;
    $diagset ||= "Bib-1";

    # HTTP body for errors is sometimes a plain string, sometimes a JSON structure
    if ($addinfo =~ /^{/) {
	my $obj = decode_json($addinfo);
	$addinfo = $obj->{errorMessage};
    }

    die new ZOOM::Exception($code, undef, $addinfo, $diagset);
}


# The following code maps Z39.50 Type-1 queries to CQL by providing a
# _toCQL() method on each query tree node type.

package Net::Z3950::RPN::Term;

sub _toCQL {
    my $self = shift;
    my($args, $defaultSet) = @_;
    my $gh = $args->{GHANDLE};
    my $field;
    my $relation;
    my($left_anchor, $right_anchor) = (0, 0);
    my($left_truncation, $right_truncation) = (0, 0);
    my $term = $self->{term};

    my $attrs = $self->{attributes};
    untie $attrs;

    # First we determine USE attribute
    foreach my $attr (@$attrs) {
	my $set = $attr->{attributeSet} || $defaultSet;
	# Unknown attribute set (anything except BIB-1)
	_throw(121, $set) if $set ne '1.2.840.10003.3.1';
	if ($attr->{attributeType} == 1) {
	    my $val = $attr->{attributeValue};
	    $field = _ap2index($gh->{cfg}->{indexMap}, $val);
	}
    }

    # Then we can handle any other attributes
    foreach my $attr (@$attrs) {
        my $type = $attr->{attributeType};
        my $value = $attr->{attributeValue};

        if ($type == 2) {
	    # Relation.  The following switch hard-codes information
	    # about the crrespondance between the BIB-1 attribute set
	    # and CQL context set.
	    if ($value == 1) {
		$relation = "<";
	    } elsif ($value == 2) {
		$relation = "<=";
	    } elsif ($value == 3) {
		$relation = "=";
	    } elsif ($value == 4) {
		$relation = ">=";
	    } elsif ($value == 5) {
		$relation = ">";
	    } elsif ($value == 6) {
		$relation = "<>";
	    } elsif ($value == 100) {
		$relation = "=/phonetic";
	    } elsif ($value == 101) {
		$relation = "=/stem";
	    } elsif ($value == 102) {
		$relation = "=/relevant";
	    } else {
		_throw(117, $value);
	    }
        }

        elsif ($type == 3) { # Position
            if ($value == 1 || $value == 2) {
                $left_anchor = 1;
            } elsif ($value != 3) {
                _throw(119, $value);
            }
        }

        elsif ($type == 4) { # Structure -- we ignore it
        }

        elsif ($type == 5) { # Truncation
            if ($value == 1) {
                $right_truncation = 1;
            } elsif ($value == 2) {
                $left_truncation = 1;
            } elsif ($value == 3) {
                $right_truncation = 1;
                $left_truncation = 1;
            } elsif ($value == 101) {
		# Process # in search term
		$term =~ s/#/?/g;
            } elsif ($value == 104) {
		# Z39.58-style (CCL) truncation: #=single char, ?=multiple
		$term =~ s/#/?/g;
		$term =~ s/\?\d?/*/g;
            } elsif ($value != 100) {
                _throw(120, $value);
            }
        }

        elsif ($type == 6) { # Completeness
            if ($value == 2 || $value == 3) {
		$left_anchor = $right_anchor = 1;
	    } elsif ($value != 1) {
                _throw(122, $value);
            }
        }

        elsif ($type != 1) { # Unknown attribute type
            _throw(113, $type);
        }
    }

    $term = "*$term" if $left_truncation;
    $term = "$term*" if $right_truncation;
    $term = "^$term" if $left_anchor;
    $term = "$term^" if $right_anchor;

    $term = "\"$term\"" if $term =~ /[\s""\/=]/;

    if (defined $field && defined $relation) {
	$term = "$field $relation $term";
    } elsif (defined $field) {
	$term = "$field=$term";
    } elsif (defined $relation) {
	$term = "cql.serverChoice $relation $term";
    }

    return $term;
}


sub _ap2index {
    my($indexMap, $value) = @_;

    if (!defined $indexMap) {
	# This allows us to use string-valued attributes when no indexes are defined.
	return $value;
    }

    my $field = $indexMap->{$value};
    _throw(114, $value) if !defined $field;
    return $field;
}


package Net::Z3950::RPN::RSID;
sub _toCQL {
    my $self = shift;
    my($args, $defaultSet) = @_;
    my $session = $args->{HANDLE};

    my $zid = $self->{id};
    my $rs = $session->{resultsets}->{$zid};
    _throw(128, $zid) if !defined $rs; # "Illegal result set name"

    my $sid = $rs->{rsid};
    return qq[cql.resultSetId="$sid"]
}

package Net::Z3950::RPN::And;
sub _toCQL {
    my $self = shift;
    my $left = $self->[0]->_toCQL(@_);
    my $right = $self->[1]->_toCQL(@_);
    return "($left and $right)";
}

package Net::Z3950::RPN::Or;
sub _toCQL {
    my $self = shift;
    my $left = $self->[0]->_toCQL(@_);
    my $right = $self->[1]->_toCQL(@_);
    return "($left or $right)";
}

package Net::Z3950::RPN::AndNot;
sub _toCQL {
    my $self = shift;
    my $left = $self->[0]->_toCQL(@_);
    my $right = $self->[1]->_toCQL(@_);
    return "($left not $right)";
}


=head1 SEE ALSO

=over 4

=item The C<z2folio> script conveniently launches the server.

=item C<Net::Z3950::FOLIO::Config> describes the configuration-file format.

=item The C<Net::Z3950::SimpleServer> handles the Z39.50 service.

=back

=head1 AUTHOR

Mike Taylor, E<lt>mike@indexdata.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2018 The Open Library Foundation

This software is distributed under the terms of the Apache License,
Version 2.0. See the file "LICENSE" for more information.

=cut

