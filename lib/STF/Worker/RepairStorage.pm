package STF::Worker::RepairStorage;
use Mouse;
use Scope::Guard ();
use STF::Constants qw(:storage STF_DEBUG);
use STF::Utils ();
use STF::Log;

extends 'STF::Worker::Base';
with 'STF::Trait::WithContainer';

has '+interval' => (
    default => 5 * 60 * 1_000_000
);

sub work_once {
    my $self = shift;

    my $o_e0 = $0;
    my $guard = Scope::Guard->new(sub {
        $0 = $o_e0;
    });
    local $STF::Log::PREFIX = "Repair(S)" if STF_DEBUG;
    eval {
        my $api = $self->get('API::Storage');

        # There may be multiple storages, but we only process one at a time,
        # so just pick one

        if (STF_DEBUG) {
            debugf("Looking for storages with STORAGE_MODE_REPAIR or STORAGE_MODE_CRASH");
        }

        my ($storage) = $api->search( {
            mode => { IN => [ STORAGE_MODE_REPAIR, STORAGE_MODE_CRASH ] }
        } );
        if (! $storage) {
            infof("No storage to repair");
            return;
        }

        my $o_mode = $storage->{mode};
        my ($new_mode, $end_mode);
        if ($o_mode == STORAGE_MODE_REPAIR) {
            $new_mode = STORAGE_MODE_REPAIR_NOW;
            $end_mode = STORAGE_MODE_REPAIR_DONE;
        } else {
            $new_mode = STORAGE_MODE_CRASH_RECOVER_NOW;
            $end_mode = STORAGE_MODE_CRASH_RECOVERED;
        }

        my $storage_id = $storage->{id};
        if (STF_DEBUG) {
            infof("Repairing storage %s (mode was %s)",
                $storage_id,
                $o_mode == STORAGE_MODE_REPAIR ? "REPAIR" : "CRASH"
            );
        }
        my $ok = $api->update( $storage_id,
            { mode => $new_mode, updated_at => \'NOW()' },
            { updated_at => $storage->{updated_at} }
        );
        if (! $ok) {
            warnf("Could not update storage, bailing out");
            return;
        }
        my $guard = Scope::Guard->new(sub {
            STF::Utils::timeout_call( 2, sub {
                local $@;
                eval {
                    $api->update( $storage_id,
                        { mode => $o_mode, updated_at => \'NOW()' },
                        { mode => $new_mode }
                    );
                };
            } );
        });

        # Signals terminate the process, but don't allow us to fire the
        # guard object, so we manually fire it up
        my $loop = 1;
        my $sig   = sub {
            my $sig = shift;
            return sub {
                $loop = 0;
                undef $guard;
                croakf("Received signal, stopping repair");
            };
        };
        local $SIG{INT}  = $sig->("INT");
        local $SIG{QUIT} = $sig->("QUIT");
        local $SIG{TERM} = $sig->("TERM");

        my $bailout = 0;
        my $limit = 10_000;
        my $object_id = 0;
        my $processed = 0;
        my $queue_api = $self->get('API::Queue');
        my $dbh = $self->get('DB::Master');
        # find the largest object_id currently allocated, and make sure to
        # stop there
        my ($max_object_id) = $dbh->selectrow_array(<<EOSQL);
            SELECT max(id) FROM object
EOSQL

        my $sth = $dbh->prepare(<<EOSQL);
            SELECT object_id FROM entity WHERE storage_id = ? AND object_id > ? ORDER BY object_id ASC LIMIT $limit
EOSQL
        my $size = $queue_api->size( 'repair_object' );
        while ( $loop && $sth->execute( $storage_id, $object_id ) > 0 ) {
            $sth->bind_columns( \($object_id) );
            while ( $loop && $sth->fetchrow_arrayref ) {
                $queue_api->enqueue( repair_object => "NP:$object_id" );
                $processed++;
                $0 = "$o_e0 (object_id: $object_id, $processed)";
            }
            $loop = $object_id < $max_object_id;

            # wait here until we have processed the rows that we just
            # inserted into the repair queue
            my $prev = $size;
            $size = $queue_api->size( 'repair_object' );
            while ( $loop && $size > $prev && abs($prev - $size) > $limit * 0.05 ) {
                my $timeout = time() + 60;
                while ($timeout > time()) {
                    select(undef, undef, undef, rand 5);
                }
                $size = $queue_api->size( 'repair_object' );
            }

            # Bail out if the value for mode has changed
            my $now = $api->lookup( $storage_id );
            if ( $now->{mode} != $new_mode ) {
                $bailout = 1;
                last;
            }
        }

        if ($guard) {
            $guard->dismiss;
        }
        infof("Storage %d, processed %d rows", $storage_id, $processed );
        if (! $bailout) {
            $api->update( $storage_id => { mode => $end_mode } );
        }
    };
    if (my $e = $@) {
        if ($e !~ /Received signal/) {
            Carp::confess("Failed to run repair storage: $e");
        } else {
            Carp::confess("Bailing out because of signal; $e" );
        }
    }
}

no Mouse;

1;