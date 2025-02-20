#!/usr/bin/perl

use 5.010;
use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/lib";
use Data::Dumper;
use Config::General;
use ZabbixAPI;
use English '-no_match_vars';
use MIME::Base64 qw(encode_base64);
use IO::Socket::INET;
use Storable qw(lock_store lock_retrieve);
our $VERSION = 4.0;

my $CACHE_TIMEOUT = 600;
my $CACHE_DIR     = '/tmp/zabbix_syslog_cache_n';
die "No argumets required anymore since script version 3.0\n" if @ARGV > 0;
my $conf;
$conf  = eval {Config::General->new('/usr/local/etc/zabbix_syslog.cfg')};
if ($@) {
        eval {$conf  = Config::General->new('/etc/zabbix/zabbix_syslog.cfg')};
        if ($@) {die "Please check that config file is available as /usr/local/etc/zabbix_syslog.cfg or /etc/zabbix/zabbix_syslog.cfg\n";}
}
my %Config = $conf->getall;

#Authenticate yourself
my $url = $Config{'url'} || die "URL is missing in zabbix_syslog.cfg\n";
my $username = $Config{'username'} || die "API username is missing in zabbix_syslog.cfg\n";
my $password = $Config{'password'} || die "API user password is missing in zabbix_syslog.cfg\n";
my $server = $Config{'server'} || die "server hostname is missing in zabbix_syslog.cfg\n";
my $zbx;

my $debug = $Config{'debug'};
my ( $authID, $response, $json );
#IP regex patter part
my $ipv4_octet = q/(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)/;

#rsyslog omprog loop
#http://www.rsyslog.com/doc/master/configuration/modules/omprog.html
while (defined(my $message = <>)) {
    chomp($message);

    #get ip from message
    my $ip;

    if ( $message =~ / \[ ((?:$ipv4_octet[.]){3}${ipv4_octet}) \]/msx ) {
        $ip = $1;
    }
    else {
        warn "No IP in square brackets found in '$message', cannot continue\n";
        next;
    }

    my $hostname = ${retrieve_from_store($ip)}->{'hostname'};


    if ( !defined $hostname ) {

        my $result;

        $zbx = ZabbixAPI->new( { api_url => $url, username => $username, password => $password } );
        $zbx->login();


        my @hosts_found;
        my $hostid;
        my @hostinterfaces;
        eval {@hostinterfaces=hostinterface_get($ip)};
        if($@){
            warn "Failed to retrieve any host interface with IP = $ip. Unable to bind message to item, skipping\n";
            next;
        }

        foreach my $host (@hostinterfaces) {

            $hostid = $host->{'hostid'};
            if ( grep { /$hostid/msx } @hosts_found ) {
                next;
            }#check if $hostid already is in array then skip(next)
            else { push @hosts_found, $hostid; }

            # Now get hostname
            if ( get_zbx_trapper_syslogid_by_hostid($hostid) ) {

                # Fetch host details for the given hostid
                my $result = host_get($hostid);

                # Check if the result is defined and contains 'host'
                if ( defined($result) && exists $result->{'host'} && $result->{'host'} ) {

                    # Check if 'proxy_hostid' is defined and compare it to 0
                    if ( defined($result->{'proxy_hostid'}) && $result->{'proxy_hostid'} == 0 ) {
                        # If the host is monitored directly, leave $server as is
                    } else {
                        # If the host is monitored via a proxy, assume that rsyslogd and zabbix_proxy are on the same server
                        $server = 'localhost';
                    }

                    # Set the hostname to the value fetched from the API
                    $hostname = $result->{'host'};
                } else {
                    warn "Failed to retrieve hostname for hostid $hostid\n";
                }

                last;
            }

        }
        $zbx->logout();
        store_message( $ip, $hostname );
    }

    zabbix_send( $server, $hostname, 'syslog', $message );
}


#______SUBS
sub hostinterface_get {

    my $ip = shift;
    my $params = {
            output => [ 'ip', 'hostid' ],
            filter => { ip => $ip, }
    };
    
    my $result = $zbx->do('hostinterface.get',$params);

    if ( $debug > 0 ) { print Dumper $result; }
    # Check if response was successful (not empty array in result)
    if ( !@{ $result } ) {
        $zbx->logout();
        die "hostinterface.get failed\n";
    }
    return @{ $result };

}

sub get_zbx_trapper_syslogid_by_hostid {

    my $hostid = shift;
    my $params = {
            output  => ['itemid'],
            hostids => $hostid,
            search  => {
                'key_' => 'syslog',
                type   => 2,          #type => 2 is zabbix_trapper
                status => 0,
            },
            limit => 1,
        };
    my $result = $zbx->do('item.get',$params);

    if ( $debug > 0 ) { print Dumper $result; }
    # Check if response was successful
    if ( !@{ $result } ) {
        warn "item.get failed\n";
    }
    #return itemid of syslog key (trapper type)
    return ${ $result }[0]->{itemid};
}

sub host_get {
    my $hostid = shift;
    my $params = {
            hostids => [$hostid],
            output  => [ 'host', 'proxy_hostid', 'status' ],
            filter => { status => 0, },    # only use hosts enabled
            limit  => 1,
        };

    
    my $result = $zbx->do('host.get',$params);
    
    if ( $debug > 0 ) { print Dumper $result; }

    # Check if response was successful
    if ( !$result ) {
        $zbx->logout();
        die "host.get failed\n";
    }
    return ${ $result }[0];    #return result
}

sub zabbix_send {
    my $zabbixserver = shift;
    my $hostname     = shift;
    my $item         = shift;
    my $data         = shift;
    my $SOCK_TIMEOUT     = 10;
    my $SOCK_RECV_LENGTH = 1024;

    my $result;

    my $request =
      sprintf
      "<req>\n<host>%s</host>\n<key>%s</key>\n<data>%s</data>\n</req>\n",
      encode_base64($hostname), encode_base64($item), encode_base64($data);
    my $packet = "ZBXD\1" . pack('V', length($request)) . "\0\0\0\0" . $request;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $zabbixserver,
        PeerPort => '10051',
        Proto    => 'tcp',
        Timeout  => $SOCK_TIMEOUT
    );

    die "Could not create socket: $ERRNO\n" unless $sock;
    $sock->send($packet);

    my @handles = IO::Select->new($sock)->can_read($SOCK_TIMEOUT);
    if ( $debug > 0 ) { print "host - $hostname, item - $item, data - $data\n"; }

    if ( scalar(@handles) > 0 ) {
        $sock->recv( $result, $SOCK_RECV_LENGTH );
        if ( $debug > 0 ) {
            print "answer from zabbix server $zabbixserver: $result\n";
        }
    }
    else {
        if ( $debug > 0 ) { print "no answer from zabbix server\n"; }
    }
    $sock->close();
    return;
}

#helpers
sub store_message {
    my $ip            = shift;
    my $hostname      = shift;
    my $storage_file = $CACHE_DIR;
    my ( $stored, $to_store );

    $to_store->{$ip} = {
                        hostname => $hostname,
                        created   => time()
                        };
    

    if ( -f $storage_file ) {
        $stored = lock_retrieve $storage_file;
        lock_store { %{$stored}, %{$to_store} }, $storage_file;
    }
    else {

#first time file creation, apply proper file permissions and store only single event
        lock_store $to_store, $storage_file;
        chmod 0666, $storage_file;
    }

}

sub retrieve_from_store {
    my $ip           = shift;
    my $storage_file = $CACHE_DIR;
    my $stored;
    my $message_to_retrieve;

    if ( -f $storage_file ) {

        $stored = lock_retrieve $storage_file;

        #remove expired from cache
        if (defined($stored->{$ip})){
            if (time() - $stored->{$ip}->{created} > $CACHE_TIMEOUT){
                delete $stored->{$ip};
                lock_store $stored, $storage_file;                
            }
            else {
                $message_to_retrieve = $stored->{$ip};
            }
        }
    }

    return \$message_to_retrieve;

}
