package GLPI::Agent::Task::NetDiscovery;

use strict;
use warnings;

use parent 'GLPI::Agent::Task';

use constant DEVICE_PER_MESSAGE => 4;

use English qw(-no_match_vars);
use Net::IP;
use Time::localtime;
use Time::HiRes qw(usleep);
use UNIVERSAL::require;
use Parallel::ForkManager;

use GLPI::Agent::Version;
use GLPI::Agent::Tools;
use GLPI::Agent::Tools::Network;
use GLPI::Agent::Tools::Hardware;
use GLPI::Agent::Tools::Expiration;
use GLPI::Agent::Tools::SNMP;
use GLPI::Agent::XML::Query;
use GLPI::Agent::HTTP::Client::OCS;

use GLPI::Agent::Task::NetDiscovery::Version;
use GLPI::Agent::Task::NetDiscovery::Job;

our $VERSION = GLPI::Agent::Task::NetDiscovery::Version::VERSION;

sub isEnabled {
    my ($self, $contact) = @_;

    if (!$self->{target}->isType('server')) {
        $self->{logger}->debug("NetDiscovery task not compatible with local target");
        return;
    }

    if (ref($contact) ne 'GLPI::Agent::XML::Response') {
        # TODO Support NetDiscovery task via GLPI Agent Protocol
        $self->{logger}->debug("NetDiscovery task not supported by server");
        return;
    }

    my @options = $contact->getOptionsInfoByName('NETDISCOVERY');
    if (!@options) {
        $self->{logger}->debug("NetDiscovery task execution not requested");
        return;
    }

    my @jobs;
    # Parse and validate options
    foreach my $option (@options) {

        next unless ref($option) eq 'HASH';

        unless (ref($option->{RANGEIP}) eq 'ARRAY') {
            $self->{logger}->error("invalid job: no IP range defined");
            next;
        }

        my @ranges;
        foreach my $range (@{$option->{RANGEIP}}) {
            next unless ref($range) eq 'HASH';
            if (!$range->{IPSTART}) {
                $self->{logger}->error(
                    "invalid range: no first address defined"
                );
                next;
            }
            if (!$range->{IPEND}) {
                $self->{logger}->error(
                    "invalid range: no last address defined"
                );
                next;
            }
            push @ranges, $range;
        }

        if (!@ranges) {
            $self->{logger}->error("invalid job: no valid IP range defined");
            next;
        }

        unless (ref($option->{PARAM}) eq 'ARRAY') {
            $self->{logger}->error("invalid job: no valid param defined");
            next;
        }

        my $params = $option->{PARAM}->[0];

        unless (ref($params) eq 'HASH') {
            $self->{logger}->error("invalid job: no PARAM defined");
            next;
        }

        if (!defined($params->{PID})) {
            $self->{logger}->error("invalid job: no PID defined");
            next;
        }

        push @jobs, GLPI::Agent::Task::NetDiscovery::Job->new(
            logger      => $self->{logger},
            params      => $params,
            credentials => $option->{AUTHENTICATION},
            ranges      => \@ranges,
        );
    }

    if (!@jobs) {
        $self->{logger}->error("no valid job found, aborting");
        return;
    }

    $self->{jobs} = \@jobs;

    return 1;
}

sub run {
    my ($self) = @_;

    my $abort = 0;
    $SIG{TERM} = sub { $abort = 1; };

    # check discovery methods available
    if (canRun('arp')) {
        $self->{arp} = 'arp -a';
    } elsif (canRun('ip')) {
        $self->{arp} = 'ip neighbor show';
    } else {
        $self->{logger}->info(
            "Can't run 'ip neighbor show' or 'arp' command, arp table detection can't be used"
        );
    }

    Net::Ping->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load Net::Ping, echo ping can't be used"
        );
    }

    Net::NBName->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load Net::NBName, netbios can't be used"
        );
    }

    GLPI::Agent::SNMP::Live->require();
    if ($EVAL_ERROR) {
        $self->{logger}->info(
            "Can't load GLPI::Agent::SNMP::Live, snmp detection " .
            "can't be used"
        );
    }

    # Extract greatest max_threads from jobs
    my ($max_threads) = sort { $b <=> $a } map { int($_->max_threads()) }
        @{$self->{jobs}};

    # Prepare fork manager
    my $manager = Parallel::ForkManager->new($max_threads);
    $manager->set_waitpid_blocking_sleep(0);

    my %queues = ();

    # Callback to update %queues
    $manager->run_on_finish(
        sub {
            my ($pid, $ret, $jobid, $signal, $coredump, $data) = @_;
            if (!$ret && $data) {
                $queues{$jobid}->{size} += $data->{size};
                push @{$queues{$jobid}->{ranges}}, $data->{range};
            }
        }
    );

    # Start jobs by preparing range queues and counting ips
    foreach my $job (@{$self->{jobs}}) {
        my $jobid = $job->pid;

        # Initialize queue
        $queues{$jobid} = {
            max_in_queue        => $job->max_threads(),
            in_queue            => 0,
            timeout             => $job->timeout(),
            snmp_credentials    => $job->getValidCredentials(),
            ranges              => [],
            size                => 0,
            done                => 0,
        };

        $self->{logger}->debug("initializing job $jobid");

        # process each address block
        foreach my $range ($job->ranges()) {
            my $start = $range->{start};
            my $end   = $range->{end};

            $manager->start($jobid) and next;

            my $block = Net::IP->new( "$start-$end" );
            if (!$block || !$block->ip() || $block->{binip} !~ /1/) {
                $self->{logger}->error(
                    "IPv4 range not supported by Net::IP: $start-$end"
                );
                $manager->finish(1);
            }

            unless ($block->size()) {
                $self->{logger}->error("Skipping empty range: $start-$end");
                $manager->finish(2);
            }

            $self->{logger}->debug("initializing block $start-$end");

            $range->{block} = $block;

            my $data = {
                size    => $block->size()->numify(),
                range   => $range
            };

            $manager->finish(0, $data);
        }
    }

    $manager->wait_all_children();

    # Check computed queues
    my $max_count = 0;
    my $minimum_timeout = 1;
    foreach my $jobid (keys(%queues)) {
        my $queue = $queues{$jobid};
        unless ($queue->{size}) {
            $self->{logger}->debug("no valid block found for job $jobid");
            $self->_sendStartMessage($jobid);
            $self->_sendBlockMessage($jobid, 0);
            $self->_sendStopMessage($jobid);
            $self->_sendStopMessage($jobid);
            delete $queues{$jobid};
            next;
        }

        # Update total count
        $max_count += $queue->{size};

        # Update minimum expiration
        $minimum_timeout += $queue->{size} * $queue->{timeout};
    }
    my $minimum_expiration = time + $minimum_timeout;

    # Define a realistic block scan expiration : at least one minute by address

    # Can be set from GLPI::Agent::HTTP::Server::ToolBox::Inventory
    my $target_expiration = $self->{target_expiration} || 60;
    $target_expiration = 60 if ($target_expiration < 60);
    setExpirationTime( timeout => $max_count * $target_expiration );
    my $expiration = getExpirationTime();
    $expiration = $minimum_expiration if $expiration < $minimum_expiration;
    $self->_logExpirationHours($expiration);

    # no need more worker than ips to scan
    my $worker_count = $max_threads > $max_count ? $max_count : $max_threads;
    my $queued_count = 0;

    $self->{logger}->debug("creating $worker_count workers");
    $manager->set_max_procs($worker_count);

    # Callback for processed scan
    $manager->run_on_finish(
        sub {
            my ($pid, $ret, $jobid) = @_;
            my $queue = $queues{$jobid};
            $queue->{in_queue} --;
            $queued_count--;
            $queue->{done} ++;
            if ($queue->{done} == $queue->{size}) {
                # send final message to the server before cleaning threads
                $self->_sendStopMessage($jobid);

                delete $queues{$jobid};

                # send final message to the server
                $self->_sendStopMessage($jobid);
            }
        }
    );

    my $job_count = 0;
    my $jid_len = length(sprintf("%i",$max_count));
    my $jid_pattern = "#%0".$jid_len."i";

    # We need to guaranty we don't have more than max_in_queue device in shared
    # queue for each job
    while (my @jobs = sort { $a <=> $b } keys(%queues)) {

        # Enqueue as ip as possible
        foreach my $jobid (@jobs) {
            my $queue = $queues{$jobid};
            next unless @{$queue->{ranges}};
            next if $queue->{in_queue} >= $queue->{max_in_queue};
            my $range = $queue->{ranges}->[0];
            my $block = $range->{block};
            my $blockip = $block->ip();
            # Still update block and handle range list
            shift @{$queue->{ranges}} unless $range->{block} = $block + 1;
            next unless $blockip;

            $queue->{in_queue} ++;
            $queued_count++;

            if ($expiration && time > $expiration) {
                $self->{logger}->warning("Aborting netdiscovery task as it reached expiration time");
                $abort ++;
                last;
            }

            if ($abort) {
                $self->{logger}->warning("Aborting netdiscovery task on TERM signal");
                last;
            }

            # Don't forget to send initial start message to the server
            unless ($queue->{started}) {
                $self->{logger}->debug("starting job $jobid with $queue->{size} ips to scan using $queue->{max_in_queue} workers");
                $queue->{started} = 1;
                $self->_sendStartMessage($jobid);
                # Also send block size to the server
                $self->_sendBlockMessage($jobid, $queue->{size});
            }

            $job_count++;

            # Start worker and still try for another ip for this job
            $manager->start($jobid) and redo;

            my $jobaddress = {
                ip                  => $blockip,
                snmp_ports          => $range->{ports},
                snmp_domains        => $range->{domains},
                entity              => $range->{entity},
                pid                 => $jobid,
                timeout             => $queue->{timeout},
                snmp_credentials    => $queue->{snmp_credentials},
                jid                 => sprintf($jid_pattern, $job_count),
            };
            $jobaddress->{walk} = $range->{walk} if $range->{walk};

            my $result = $self->_scanAddress($jobaddress);

            if ($result && $result->{IP}) {
                $result->{ENTITY} = $range->{entity} if defined($range->{entity});
                $self->_sendResultMessage($result, $jobid);
            }

            $manager->finish(0);
        }

        last if $abort;

        # wait a little bit
        usleep(50000);
        $manager->reap_finished_children();
    }

    $manager->wait_all_children();

    if ($queued_count) {
        $self->{logger}->error("$queued_count devices scan result missed");
    }

    # Send exit message if we quit during a job still being run
    foreach my $pid (sort { $a <=> $b } keys(%queues)) {
        $self->{logger}->error("job $pid aborted");
        $self->_sendExitMessage($pid);
    }

    # Reset expiration
    setExpirationTime();
}

sub _logExpirationHours {
    my ($self, $expiration) = @_;

    return if $self->{_remaining_next_log} && time < $self->{_remaining_next_log};

    # Turn expiration integer as a float string to compute remaining as a float
    my $remaining = ("$expiration.0" - time)/3600;

    $self->{_remaining_next_log} = time + 600;

    if ($remaining>2) {
        $remaining = sprintf("%.1f hours", $remaining);
    } elsif($remaining<1) {
        my $minutes = int($remaining*60);
        if ($minutes>=10) {
            $remaining = "$minutes minutes";
        } elsif ($minutes>1) {
            $remaining = "few minutes";
        } else {
            $remaining = "soon";
        }
    } else {
        $remaining = sprintf("%.1f hour", $remaining);
    }

    $self->{logger}->debug("Current run expiration timeout: $remaining");
}

sub abort {
    my ($self) = @_;

    $self->_sendStopMessage() if $self->{pid};
    $self->SUPER::abort();
}

sub _sendMessage {
    my ($self, $content) = @_;

    my $message = GLPI::Agent::XML::Query->new(
        deviceid => $self->{deviceid} || 'foo',
        query    => 'NETDISCOVERY',
        content  => $content
    );

    # task-specific client, if needed
    unless ($self->{client}) {
        $self->{client} = GLPI::Agent::HTTP::Client::OCS->new(
            logger  => $self->{logger},
            config  => $self->{config},
        );
    }

    $self->{client}->send(
        url     => $self->{target}->getUrl(),
        message => $message
    );
}

sub _scanAddress {
    my ($self, $params) = @_;

    my $logger = $self->{logger};
    $logger->{prefix} = "$params->{jid}, ";
    $logger->debug("scanning $params->{ip}");

    # Used by unittest to test arp cases
    $self->{arp} = $params->{arp} if $params->{arp};

    my %device = (
        $INC{'Net/SNMP.pm'}      ? $self->_scanAddressBySNMP($params)    : (),
        $INC{'Net/NBName.pm'}    ? $self->_scanAddressByNetbios($params) : (),
        $INC{'Net/Ping.pm'}      ? $self->_scanAddressByPing($params)    : (),
        $self->{arp}             ? $self->_scanAddressByArp($params)     : (),
    );

    # don't report anything without a minimal amount of information
    return unless
        $device{MAC}          ||
        $device{SNMPHOSTNAME} ||
        $device{DNSHOSTNAME}  ||
        $device{NETBIOSNAME};

    $device{IP} = $params->{ip};

    if ($device{MAC}) {
        $device{MAC} =~ tr/A-F/a-f/;
    }

    return \%device;
}

sub _scanAddressByArp {
    my ($self, $params) = @_;

    return unless $params->{ip};
    return if $params->{walk};

    # We want to match the ip including non digit character around
    my $ip_match = '\b' . $params->{ip} . '\D';
    # We want to match dot on dots
    $ip_match =~ s/\./\\./g;

    # Just to handle unittests
    my %params = ( logger => $self->{logger} );
    $params{file} = $params->{file} if $params->{file};

    my $output = getFirstMatch(
        command => $self->{arp} . " " . $params->{ip},
        pattern => qr/^(.*$ip_match.*)$/,
        %params
    );

    my %device = ();

    if ($output && $output =~ /^(\S+) \(\S+\) at (\S+) /) {
        $device{DNSHOSTNAME} = $1 if $1 ne '?';
        $device{MAC}         = getCanonicalMacAddress($2);
    } elsif ($output && $output =~ /^\s+\S+\s+([:a-zA-Z0-9-]+)\s/) {
        # Under win32, mac address separators are minus signs
        my $mac_address = $1;
        $mac_address =~ s/-/:/g;
        $device{MAC} = getCanonicalMacAddress($mac_address);
    } elsif ($output && $output =~ /^\S+\s+dev\s+\S+\s+lladdr\s+([:a-zA-Z0-9-]+)\s/) {
        $device{MAC} = getCanonicalMacAddress($1);
    }

    $self->{logger}->debug(
        sprintf "- scanning %s in arp table: %s",
        $params->{ip},
        $device{MAC} ? 'success' : 'no result'
    );

    return %device;
}

sub _scanAddressByPing {
    my ($self, $params) = @_;

    return if $params->{walk};

    my $type = 'echo';
    my $np;
    eval {
        $np = Net::Ping->new('icmp', 1);
    };

    unless ($np) {
        $self->{logger}->debug(
            sprintf "- scanning %s with $type ping: %s",
            $params->{ip},
            'no result, ping not supported'
        );
        return ();
    }

    my %device = ();

    # Avoid an error as Net::Ping::VERSION may contain underscore
    my ($NetPingVersion) = split('_',$Net::Ping::VERSION);

    if ($np->ping($params->{ip})) {
        $device{DNSHOSTNAME} = $params->{ip};
    } elsif ($NetPingVersion >= 2.67) {
        $type = 'timestamp';
        $np->message_type($type);
        if ($np->ping($params->{ip})) {
            $device{DNSHOSTNAME} = $params->{ip};
        }
    }

    $self->{logger}->debug(
        sprintf "- scanning %s with $type ping: %s",
        $params->{ip},
        $device{DNSHOSTNAME} ? 'success' : 'no result'
    );

    return %device;
}

sub _scanAddressByNetbios {
    my ($self, $params) = @_;

    return if $params->{walk};

    my $nb = Net::NBName->new();

    my $ns = $nb->node_status($params->{ip});

    $self->{logger}->debug(
        sprintf "- scanning %s with netbios: %s",
        $params->{ip},
        $ns ? 'success' : 'no result'
    );
    return unless $ns;

    my %device;
    foreach my $rr ($ns->names()) {
        my $suffix = $rr->suffix();
        my $G      = $rr->G();
        my $name   = $rr->name();
        if ($suffix == 0 && $G eq 'GROUP') {
            $device{WORKGROUP} = getSanitizedString($name);
        }
        if ($suffix == 3 && $G eq 'UNIQUE') {
            $device{USERSESSION} = getSanitizedString($name);
        }
        if ($suffix == 0 && $G eq 'UNIQUE') {
            $device{NETBIOSNAME} = getSanitizedString($name)
                unless $name =~ /^IS~/;
        }
    }

    my $mac = $ns->mac_address();
    if ($mac) {
        $mac =~ tr/-/:/;
        $mac = getCanonicalMacAddress($mac);
        $device{MAC} = $mac
            if $mac;
    }

    return %device;
}

sub _scanAddressBySNMP {
    my ($self, $params) = @_;

    my $tries = [];
    if ($params->{snmp_ports} && @{$params->{snmp_ports}}) {
        foreach my $port (@{$params->{snmp_ports}}) {
            my @cases = map { { port => $port, credential => $_ } } @{$params->{snmp_credentials}};
            push @{$tries}, @cases;
        }
    } else {
        @{$tries} = map { { credential => $_ } } @{$params->{snmp_credentials}};
    }
    if ($params->{snmp_domains} && @{$params->{snmp_domains}}) {
        my @domtries = ();
        foreach my $domain (@{$params->{snmp_domains}}) {
            foreach my $try (@{$tries}) {
                $try->{domain} = $domain;
            }
            push @domtries, @{$tries};
        }
        $tries = \@domtries;
    }

    foreach my $try (@{$tries}) {
        my $credential = $try->{credential};
        my $device = $self->_scanAddressBySNMPReal(
            ip         => $params->{ip},
            port       => $try->{port},
            domain     => $try->{domain},
            timeout    => $params->{timeout},
            file       => $params->{walk},
            credential => $credential
        );

        # no result means either no host, no response, or invalid credentials
        $self->{logger}->debug(
            sprintf "- scanning %s%s with SNMP%s, credentials %s: %s",
            $params->{ip},
            $try->{port}   ? ':'.$try->{port}   : '',
            $try->{domain} ? ' '.$try->{domain} : '',
            $credential->{ID},
            ref $device eq 'HASH' ? 'success' :
                $device ? "no result, $device" : 'no result'
        );

        if (ref $device eq 'HASH') {
            $device->{AUTHSNMP}     = $credential->{ID};
            $device->{AUTHPORT}     = $try->{port};
            $device->{AUTHPROTOCOL} = $try->{domain};
            return %{$device};
        }
    }

    return;
}

sub _scanAddressBySNMPReal {
    my ($self, %params) = @_;

    my $snmp;
    if ($params{file}) {
        GLPI::Agent::SNMP::Mock->require();
        eval {
            $snmp = GLPI::Agent::SNMP::Mock->new(
                ip   => $params{ip},
                file => $params{file}
            );
        };
        die "SNMP emulation error: $EVAL_ERROR" if $EVAL_ERROR;
    } else {
        eval {
            # AUTHPASSPHRASE & PRIVPASSPHRASE are deprecated but still used by FusionInventory for GLPI plugin
            $snmp = GLPI::Agent::SNMP::Live->new(
                version      => $params{credential}->{VERSION},
                hostname     => $params{ip},
                port         => $params{port},
                domain       => $params{domain},
                timeout      => $params{timeout} || 1,
                community    => $params{credential}->{COMMUNITY},
                username     => $params{credential}->{USERNAME},
                authpassword => $params{credential}->{AUTHPASSPHRASE} // $params{credential}->{AUTHPASSWORD},
                authprotocol => $params{credential}->{AUTHPROTOCOL},
                privpassword => $params{credential}->{PRIVPASSPHRASE} // $params{credential}->{PRIVPASSWORD},
                privprotocol => $params{credential}->{PRIVPROTOCOL},
            );
        };
    }

    # an exception here just means no device or wrong credentials
    return $EVAL_ERROR if $EVAL_ERROR;

    my $info = getDeviceInfo(
        snmp    => $snmp,
        config  => $self->{config},
        datadir => $self->{datadir},
        logger  => $self->{logger},
    );
    return unless $info;

    return $info;
}

sub _sendStartMessage {
    my ($self, $pid) = @_;

    $self->_sendMessage({
        AGENT => {
            START        => 1,
            AGENTVERSION => $GLPI::Agent::Version::VERSION,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

sub _sendStopMessage {
    my ($self, $pid) = @_;

    $self->_sendMessage({
        AGENT => {
            END => 1,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

sub _sendExitMessage {
    my ($self, $pid) = @_;

    $self->_sendMessage({
        AGENT => {
            EXIT => 1,
        },
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

sub _sendBlockMessage {
    my ($self, $pid, $count) = @_;

    $self->_sendMessage({
        AGENT => {
            NBIP => $count
        },
        PROCESSNUMBER => $pid
    });
}

sub _sendResultMessage {
    my ($self, $result, $pid) = @_;

    $self->_sendMessage({
        DEVICE        => [$result],
        MODULEVERSION => $VERSION,
        PROCESSNUMBER => $pid
    });
}

1;

__END__

=head1 NAME

GLPI::Agent::Task::NetDiscovery - Net discovery support for GLPI Agent

=head1 DESCRIPTION

This tasks scans the network to find connected devices, allowing:

=over

=item *

devices discovery within an IP range, through arp, ping, NetBios or SNMP

=item *

devices identification, through SNMP

=back

This task requires a GLPI server with a FusionInventory compatible plugin.
