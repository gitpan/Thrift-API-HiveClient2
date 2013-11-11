package Thrift::API::HiveClient2;
{
  $Thrift::API::HiveClient2::VERSION = '0.012';
}
{
  $Thrift::API::HiveClient2::DIST = 'Thrift-API-HiveClient2';
}
# ABSTRACT: Perl to HiveServer2 Thrift API wrapper


use strict;
use warnings;

use Moo;
use Carp;

use Thrift;
use Thrift::Socket;
use Thrift::BufferedTransport;

# Protocol loading is done dynamically later.

use Thrift::API::HiveClient2::TCLIService;

# Don't use XS for now, fails initializing properly with BufferedTransport. See
# Thrift::XS documentation.
has use_xs => (
    is      => 'rwp',
    default => sub {0},
    lazy    => 1,
);

has host => (
    is      => 'ro',
    default => sub {'localhost'},
);
has port => (
    is      => 'ro',
    default => sub {10_000},
);

# 1 hour default recv socket timeout. Increase for longer-running queries
# called "timeout" for simplicity's sake, as this is how a user will experience
# it: a time after which the Thrift stack will throw an exception if not
# getting an answer from the server

has timeout => (
    is      => 'rw',
    default => sub { 3_600 },
);

# These exist to make testing with various other Thrift Implementation classes
# easier, eventually.

has _socket    => ( is => 'rwp' );
has _transport => ( is => 'rwp' );
has _protocol  => ( is => 'rwp' );
has _client    => ( is => 'rwp' );

# setters implied by the 'rwp' mode on the attrs above.

sub _set_socket    { $_[0]->{_socket}    = $_[1] }
sub _set_transport { $_[0]->{_transport} = $_[1] }
sub _set_protocol  { $_[0]->{_protocol}  = $_[1] }
sub _set_client    { $_[0]->{_client}    = $_[1] }

# after constructon is complete, initialize any attributes that
# weren't set in the constructor.
sub BUILD {
    my $self = shift;

    $self->_set_socket( Thrift::Socket->new( $self->host, $self->port ) )
        unless $self->_socket;

    $self->_set_transport( Thrift::BufferedTransport->new( $self->_socket ) )
        unless $self->_transport;

    $self->_set_protocol( $self->_init_protocol( $self->_transport ) )
        unless $self->_protocol;

    $self->_set_client( Thrift::API::HiveClient2::TCLIServiceClient->new( $self->_protocol ) )
        unless $self->_client;
}


sub _init_protocol {
    my $self = shift;
    my $err;
    my $protocol = eval {
        $self->use_xs
            && require Thrift::XS::BinaryProtocol;
        Thrift::XS::BinaryProtocol->new( $self->_transport );
    } or do { $err = $@; 0 };
    $protocol
        ||= do { require Thrift::BinaryProtocol; Thrift::BinaryProtocol->new( $self->_transport ) };
    $self->_set_use_xs(0) if ref($protocol) !~ /XS/;

    # TODO Add warning when XS was asked but failed to load
    return $protocol;
}


sub connect {
    my ($self) = @_;
    $self->_socket->setRecvTimeout($self->timeout * 1000);
    $self->_transport->open;
}

has _session => (
    is      => 'rwp',
    isa     => sub {
        die "Session isn't a Thrift::API::HiveClient2::TOpenSessionResp"
            if !$_[0]->isa('Thrift::API::HiveClient2::TOpenSessionResp') },
    lazy    => 1,
    builder => '_build_session',
);

has username => (
    is      => 'rwp',
    lazy    => 1,
    default => sub {'foo'},
);

has password => (
    is      => 'rwp',
    lazy    => 1,
    default => sub {''},
);

sub _build_session {
    my $self = shift;
    $self->_transport->open if !$self->_transport->isOpen;
    return $self->_client->OpenSession(
        Thrift::API::HiveClient2::TOpenSessionReq->new(
            {   username => $self->username,
                password => $self->password,
            }
        )
    );
}

has _session_handle => (
    is      => 'rwp',
    isa     => sub {
        die "Session handle isn't a Thrift::API::HiveClient2::TSessionHandle"
            if !$_[0]->isa('Thrift::API::HiveClient2::TSessionHandle') },
    lazy    => 1,
    builder => '_build_session_handle',
);

sub _build_session_handle {
    my $self = shift;
    return $self->_session->{sessionHandle};
}

has _operation => (
    is => "rwp",
    isa     => sub {
        die "Operation isn't a Thrift::API::HiveClient2::TExecuteStatementResp"
            if defined $_[0] && !$_[0]->isa('Thrift::API::HiveClient2::TExecuteStatementResp') },
    lazy    => 1,
);

has _operation_handle => (
    is => 'rwp',
    isa => sub {
        die
            "Operation handle isn't a Thrift::API::HiveClient2::TOperationHandle"
            if defined $_[0] && !$_[0]->isa('Thrift::API::HiveClient2::TOperationHandle');
    },
    lazy    => 1,
);

sub _cleanup_previous_operation {
    my $self = shift;

    # We seeem to have some memory leaks in the Hive server, let's try freeing the
    # operation handle explicitely
    if ( $self->_operation_handle ) {
        $self->_client->CloseOperation(
             Thrift::API::HiveClient2::TCloseOperationReq->new(
                 { operationHandle => $self->_operation_handle, }
             )
        );
        $self->_set__operation(undef);
        $self->_set__operation_handle(undef);
    }
}


sub execute {
    my $self = shift;
    my ($query) = @_;    # make this a bit more flexible

    $self->_cleanup_previous_operation;

    my $rh = $self->_client->ExecuteStatement(
        Thrift::API::HiveClient2::TExecuteStatementReq->new(
            { sessionHandle => $self->_session_handle, statement => $query, confOverlay => {} }
        )
    );
    if ($rh->{status}{errorCode}) {
        die "execute() failed: $rh->{status}{errorMessage} (code: $rh->{status}{errorCode})";
    }
    $self->_set__operation($rh);
    $self->_set__operation_handle($rh->{operationHandle});
    return $rh;
}

{
    # cache the column names we need to extract from the bloated data structure
    # (keyed on query)
    my $column_keys;

    sub fetch {
        my $self = shift;
        my ( $rv, $rows_at_a_time ) = @_;

        # if $rv looks like a number, use it instead of $rows_at_a_time
        $rows_at_a_time = $rv if !$rows_at_a_time && $rv =~ /^[1-9][0-9]*$/;

        my $result = [];
        my $has_more_rows;

        # NOTE we don't use $rv now, maybe we should leave that possibility open
        # for parallel queries, but that woudl need a lot more testing. Patches
        # welcome.
        my $rh = $self->_client->FetchResults(
            Thrift::API::HiveClient2::TFetchResultsReq->new(
                {   operationHandle => $self->_operation_handle,
                    maxRows         => $rows_at_a_time || 10_000
                }
            )
        );
        if ( ref $rh eq 'Thrift::API::HiveClient2::TFetchResultsResp' ) {

            # NOTE that currently (july 2013) the hasMoreRows method is broken,
            # see the explanation in the POD
            $has_more_rows = $rh->hasMoreRows();

            for my $row ( @{ $rh->{results}{rows} || [] } ) {

                # Find which fields to extract from each row, only on the first iteration
                if ( !@{ $column_keys->{ $rv } || [] } ) {
                    for my $column ( @{ $row->{colVals} || [] } ) {

                        my $first_col = {%$column};

                        # Only 1 element of each TColumnValue is populated
                        # (although 7 keys are present, 1 for each possible data
                        # type) with a T*Value, and the rest is undef. Find out
                        # which is defined, and put the key (i.e. the data type) in
                        # cache, to reuse it to fetch the next rows faster.
                        # NOTE this data structure smells of Java and friends from
                        # miles away. Dynamically typed languages don't really need
                        # the bloat.
                        push @{ $column_keys->{$rv} }, grep { ref $first_col->{$_} } keys %$first_col;
                    }
                }

                # TODO find something faster?

                my $idx = 0;
                push @$result,
                    [ map { $row->{colVals}[ $idx++ ]{$_}->value() } @{ $column_keys->{$rv} } ];
            }
        }
        return wantarray ? ( $result, $has_more_rows ) : ( @$result ? $result : undef );
    }
}

sub DEMOLISH {
    my $self = shift;

    $self->_cleanup_previous_operation;

    if ( $self->_session_handle ) {
        $self->_client->CloseSession(
            Thrift::API::HiveClient2::TCloseSessionReq->new(
                { sessionHandle => $self->_session_handle, }
            )
        );
    }
    $self->_transport->close;
}

# when the user calls a method on an object of this class, see if that method
# exists on the TCLIService object. If so, create a sub that calls that method
# on the client object. If not, die horribly.
sub AUTOLOAD {
    my ($self) = @_;
    ( my $meth = our $AUTOLOAD ) =~ s/.*:://;
    return if $meth eq 'DESTROY';
    print STDERR "$meth\n";
    no strict 'refs';
    if ( $self->_client->can($meth) ) {
        *$AUTOLOAD = sub { shift->_client->$meth(@_) };
        goto &$AUTOLOAD;
    }
    croak "No such method exists: $AUTOLOAD";
}


1;

__END__

=pod

=head1 NAME

Thrift::API::HiveClient2 - Perl to HiveServer2 Thrift API wrapper

=head1 VERSION

version 0.012

=head1 METHODS

=head2 new

Initialize the client object with the Hive server parameters

    my $client = Thrift::API::HiveClient2->new(
        host    => <host name or IP, defaults to localhost>,
        port    => <port, defaults to 10000>,
        timeout => <seconds timeout, defaults to 1 hour>,
    );

=head2 connect

Open the connection on the server declared in the object's constructor.

     $client->connect() or die "Failed to connect";

=head2 execute

Run an HiveQl statement on an open connection.

    my $rh = $client->execute( <HiveQL statement> );

=head2 fetch

Returns an array(ref) of arrayrefs, like DBI's fetchall_arrayref, and a boolean
indicator telling wether or not a subsequent call to fetch() will return more
rows.

    my ($rv, $has_more_rows) = $client->fetch( $rh, <maximum records to retrieve> );

IMPORTANT: The version of HiveServer2 that we use for testing is the one
bundled with CDH 4.2.1. The hasMoreRows method is currently broken, and always
returns false. So the right way of obtaining the resultset is to keep using
fetch() until it returns an empty array. For this reason the behaviour of fetch
has been altered in scalar context (which becomes the current advised way of
retrieving the data):

    # $rv will be an arrayref is anything was fetched, and undef otherwise.
    #
    while (my $rv = $client->fetch( $rh, <maximum records to retrieve> )) {
        # ... do something with @$rv
    }

This is the approach adopted in L<https://github.com/cloudera/hue/blob/master/apps/beeswax/src/beeswax/server/hive_server2_lib.py>

Starting with version 0.12, we cache the operation handle and don't need it as a
first parameter for the fetch() call. We want to be backward-compatible though,
so depending on the type of the first parameter, we'll ignore it (since we
cached it in the object and we can get it from there) or we'll use it as the
number of rows to be retrieved if it looks like a positive integer:

     my $rv = $client->fetch( 10_000 );

=head1 WARNING

Thrift in Perl currently doesn't support SASL, so authentication needs
to be disabled for now on HiveServer2 by setting this property in your
/etc/hive/conf/hive-site.xml. Although the property is documented, this
*value* -which disables the SASL server transport- is not, AFAICT.

  <property>
    <name>hive.server2.authentication</name>
    <value>NOSASL</value>
  </property>

=head1 CAVEATS

The instance of hiveserver2 we have didn't return results encoded in UTF8, for
the reason mentioned here: L<https://groups.google.com/a/cloudera.org/d/msg/cdh-user/AXeEuaFP0Ro/Txmn1OHleAsJ>

So we had to change the init script for hive-server2 to make it behave, adding
'-Dfile.encoding=UTF-8' to HADOOP_OPTS

=head1 AUTHOR

David Morel <david.morel@amakuru.net>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2013 by David Morel & Booking.com. Portions are (c) R.Scaffidi, Thrift files are (c) Apache Software Foundation..

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004

=cut
