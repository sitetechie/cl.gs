package clgs::Redis;

use namespace::autoclean;
use Moose;
use MooseX::StrictConstructor;
use Const::Fast;
use DateTime;
use DateTime::Format::ISO8601;
use DateTime::Format::MySQL;
use String::Koremutake;
use JSON ();
use Redis;

our $VERSION = '0.001';

my $KORE = String::Koremutake->new();

has 'connection' => (
    is       => 'ro',
    required => 0,
    isa      => 'Redis',
    default => sub { Redis->new() }
);

has 'base' => (
    is       => 'ro',
    default  => '__clgs'
);

const my $UNIQUE_COUNTER         => 'CLGS:%s:COUNT';
const my $ENCODED_URL_MASK       => 'CLGS:%s:CODE:%s';
const my $ENCODED_URL_DICT       => 'CLGS:%s:META:%s';
const my $ENCODED_URL_STATS_DICT => 'CLGS:%s:STATS:%s'; # code visitcount per hour

sub _key_counter { sprintf( $UNIQUE_COUNTER,         shift->base) }     ## no critic (RequireArgUnpacking)
sub _key_code    { sprintf( $ENCODED_URL_MASK,       shift->base, @_) } ## no critic (RequireArgUnpacking)
sub _key_data    { sprintf( $ENCODED_URL_DICT,       shift->base, @_) } ## no critic (RequireArgUnpacking)
sub _key_stats   { sprintf( $ENCODED_URL_STATS_DICT, shift->base, @_) } ## no critic (RequireArgUnpacking)

sub _next_code {
    my $self = shift;
    
    # return the next code that is available for release.
    return $KORE->integer_to_koremutake($self->_next_count);
}

sub _next_count {
    my $self = shift;
    
    # init if needed, start at 10.000 (reserving the shortest codes for later use)
    $self->connection->setnx($self->_key_counter, 10000); 
    
    return $self->connection->get($self->_key_counter);
}

sub release_code {
    my $self = shift;
    
    my $code = $self->_next_code;
    $self->connection->incr($self->_key_counter);
    
    return $code;
}

sub get_url {
    my ($self, $code) = @_;
    die "Code required" unless $code;
    return $self->connection->get($self->_key_code($code));
}

sub add_url {
    my ($self, $url, $owner, $code) = @_;

    die("URL required") unless $url;
    die("User cookie required") unless $owner;

    $code ||= $self->release_code();

    my $redis = $self->connection();
    $redis->set($self->_key_code($code), $url);

    my $k = $self->_key_data($code);
    $redis->hset($k, 'created', DateTime->now());
    $redis->hset($k, 'created_by', $owner);
    $redis->hset($k, 'url', $url);

    return $code;
}

sub delete_code {
    my ($self, $code) = @_;
    
    my $redis = $self->connection();

    if( $redis->del($self->_key_code($code)) ) {
        $redis->del($self->_key_data($code)) or die "datakey $code doesn't exist";
        $redis->del($self->_key_stats($code)); # or no visitors yet
        return 1;
        }
    
    return 0;
}

sub add_visit {
    my ($self, $short, $entry) = @_;

    die('No short or entry') unless($short && $entry);

    my $redis = $self->connection();    
    
    my $date = $entry->{datetime} ?
        ($entry->{datetime} =~ /T/ ? 
            DateTime::Format::ISO8601->parse_datetime( $entry->{datetime}  ) :
            DateTime::Format::MySQL->parse_datetime( $entry->{datetime}  ))
      : DateTime->now();

    #- increment redis stats

    my $dayhour = sprintf('%s.%s.%s.%s', $date->year, $date->month, $date->day, $date->hour);

    $redis->hincrby($self->_key_data($short), 'clicks', 1);
    $redis->hincrby($self->_key_stats($short), $dayhour, 1);
    
    #- convert entry to json
        
    my $log_str;
    eval {
        $entry->{short_code} = $short;
        $entry->{datetime} ||= $date->datetime();
        $log_str = JSON->new->utf8->encode($entry);
    };
    if($@) {
        $log_str = JSON->new->utf8->encode({ 
            id => 0, short_code => $short, error => $@ 
        });
    }

    #- publish json to queue

    $redis->publish('cl.gs:visits', $log_str);

    #- increment sparkline point for today
    # TODO
    }

sub get_stats {
    my ($self, $short) = @_;

    my $redis = $self->connection() or die("Redis disconnected");

    my %meta  = $redis->hgetall($self->_key_data($short));
    die("Invalid short code '$short'") unless %meta;

    my $stats = { $redis->hgetall($self->_key_stats($short)) };
    return { code => $short, 'meta' => \%meta, breakdown => $stats };
    }


__PACKAGE__->meta->make_immutable;

1;
__END__

=pod

=head1 NAME

cl.gs::Redis - Redis backend for the cl.gs URL Shortener

=head1 VERSION

0.001

=head1 SYNOPSIS

    my $store = clgs::Redis->new(
        connection => Redis->new(),
        base       => 'example.com'
    );

    # encode and store a long url
    $short_code = $store->add_url('http://google.com', $owner_id);
    
    # decode a short code
    $long_url = $store->get_url($short_code);
    
    # store record of visit
    $store->add_visit($short_code, { foo => 'bar' });

    # get statistics for a short code
    $stats = $store->get_stats($short_code);

=head1 DESCRIPTION

Redis backend to the cl.gs URL Shortener

=head1 METHODS

=head2 new

Constructor. Takes the following parameters:

=over 4        

=item * connection

A valid L<Redis> instance (connected to a Redis server)

=item * base

A string used as a namespace in all redis keys. Use this to separate different
domains or installations using the same Redis database.

=back

=head2 release_code

Release a new short code primed on the current internal counter value and 
increment the counter.

  $code = $store->release_code();

=head2 get_url

Fetch the long URL for a short code.

  $long_url = $store->delete_code($code);

=head2 add_url
  
Add a long url to the data store and return the corresponding short code.
  
  $code = $store->add_url($url, $owner);

=head2 delete_code

Delete a code and its statistics from the data store
  
  $store->delete_code($code);

=head2 add_visit

Store record of a click on a shortened URL. In addition to incrementing click
counters, the provided log entry hash is published as a JSON string to the
C<cl.gs:visits> Redis queue. This enables you to write background workers to 
consume and process these entries.

  $store->add_visit($code, { foo => 'bar' });

=head2 get_stats

Get statistics for a short code.
    
  $stats = $store->get_stats($code);

=head1 AUTHOR

Peter de Vos <techie@sitetechie.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2012 by Site Corporation.

This module is free software; you can redistribute it and/or modify it under the
same terms as Perl itself. See L<perlartistic>.

=cut
