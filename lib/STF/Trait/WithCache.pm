package STF::Trait::WithCache;
use Mouse::Role;

with 'STF::Trait::WithContainer';
use STF::Constants qw(STF_CACHE_DEBUG);

our $DEFAULT_CACHE_EXPIRES = 5 * 60;
has cache_expires => (
    is => 'rw',
    default => $DEFAULT_CACHE_EXPIRES
);

sub cache_key {
    my ($self, @keys) = @_;
    join '.', @keys;
}

sub cache_get_multi {
    my ($self, @keys) = @_;
    my $ret = $self->get('Memcached')->get_multi( @keys );
    return $ret;
}

sub cache_get {
    my ($self, @keys) = @_;
    my $key = $self->cache_key(@keys);
    my $ret = $self->get('Memcached')->get( $key );
    if (STF_CACHE_DEBUG) {
        printf STDERR " + Cache %s for %s\n",
            ( defined $ret ? "HIT" : "MISS" ),
            $key
    }
    return $ret;
}

sub cache_set {
    my ($self, $key, $value, $expires) = @_;
    $key = ref $key eq 'ARRAY' ? $self->cache_key(@$key) : $key;
    if (STF_CACHE_DEBUG) {
        printf STDERR " + Cache SET for %s\n", $key
    }
    $self->get('Memcached')->set( $key, $value, $expires || $self->cache_expires || $DEFAULT_CACHE_EXPIRES );
}

sub cache_delete {
    my ($self, @keys) = @_;
    my $key = $self->cache_key(@keys);
    if (STF_CACHE_DEBUG) {
        printf STDERR " + Cache DELETE for %s\n", $key
    }
    $self->get('Memcached')->delete( $key );
}

no Mouse::Role;

1;
