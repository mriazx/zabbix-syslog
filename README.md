# About
Scripts to get Syslog (protocol) messages into Zabbix from network devices, servers and others.  


![new](https://cloud.githubusercontent.com/assets/14870891/19680057/da8dcf52-9aac-11e6-915a-cf136577dae3.png)  
1. Configure network devices to route all Syslog messages to a your zabbix-server or zabbix-proxy host with rsyslog on board    
2. with rsyslog configuration altered it would run script (3) and determines from what zabbix-host this message comes from(using Zabbix API)    
4. zabbix-sender protocol is then used to put messages into Zabbix (using found host and item where key=syslog)  


Features include:  
- IP to host resolutions are cached to minimize the number of Zabbix API queries  
- zabbix_sender here is in a form of a perl function, so no cli zabbix_sender tool is required      

## Map context menu  
As a bonus, script `zabbix_syslog_create_urls.pl` can be used(and scheduled in cron for regular map link updates) to append a direct link into maps host menu for reading Syslog item values for each host that has syslog:  
![2013-12-30_152557](https://cloud.githubusercontent.com/assets/14870891/19680048/d248b76c-9aac-11e6-8a95-accd34794563.png)  
Script will do no rewriting of existing host links, only appending to a list. Also link only added to hosts that has item with key 'syslog'.  

# Setup  
## Dependencies  

The script is written in Perl and you will need common modules in order to run it:  
```
LWP
JSON::XS
Config::General
```
There are numerous ways to install them:  

| In Debian  | In Centos | using CPAN | using cpanm|  
|------------|-----------|------------|------------|  
|  `apt-get install libwww-perl libjson-xs-perl libconfig-general-perl` | `yum install perl-JSON-XS perl-libwww-perl perl-LWP-Protocol-https perl-Config-General` | `PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'install Bundle::LWP'` and  `PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'install JSON::XS'` and `PERL_MM_USE_DEFAULT=1 perl -MCPAN -e 'install Config::General'` | `cpanm install LWP` and `cpanm install JSON::XS` and `cpanm install Config::General`|  

## Copy scripts  
```
mkdir -p /etc/zabbix/scripts
cp zabbix_syslog_create_urls.pl /etc/zabbix/scripts/zabbix_syslog_create_urls.pl
chmod +x /etc/zabbix/scripts/zabbix_syslog_create_urls.pl

cp zabbix_syslog_lkp_host.pl /etc/zabbix/scripts/zabbix_syslog_lkp_host.pl
chmod +x /etc/zabbix/scripts/zabbix_syslog_lkp_host.pl

mkdir /etc/zabbix/scripts/lib
cp lib/ZabbixAPI.pm /etc/zabbix/scripts/lib


cp zabbix_syslog.cfg /etc/zabbix/zabbix_syslog.cfg
sudo chown zabbix:zabbix /etc/zabbix/zabbix_syslog.cfg
sudo chmod 700 /etc/zabbix/zabbix_syslog.cfg
```
edit `/etc/zabbix/zabbix_syslog.cfg`  

## Copy crontab
Next file updates syslog map links once a day. Copy it into your zabbix-server  
```
cp cron.d/zabbix_syslog_create_urls /etc/cron.d
```

## rsyslog
add file /etc/rsyslog.d/00_zabbix_rsyslog.conf with contents:  
```
# provides UDP syslog reception
module(load="imudp")
input(type="imudp" port="514")

#enables omrpog module
module(load="omprog")

#dfine template
$template RFC3164fmt,"<%PRI%>%TIMESTAMP% %HOSTNAME% %syslogtag%%msg%"
$template network-fmt,"%TIMESTAMP:::date-rfc3339% [%fromhost-ip%] %pri-text% %syslogtag%%msg%\n"
#$template network-fmt, "%fromhost%||%syslogfacility%||%syslogpriority%||%syslogseverity%||%syslogtag%||%$year%-%$month%-%$day% %timegenerated:8:25%||%msg%||%programname%\n"

#exclude unwanted messages(examples):
:msg, contains, "Child connection from" stop
:msg, contains, "exit after auth (ubnt): Disconnect received" stop
:msg, contains, "password auth succeeded for 'ubnt' from" stop
:msg, contains, "exit before auth: Exited normally" stop
if $fromhost-ip != '127.0.0.1' then {
        action(type="omprog"
		       binary="/etc/zabbix/scripts/zabbix_syslog_lkp_host.pl"
			   template="network-fmt")
        stop
}
```
(also check your firewall for UDP/514 btw)  

...and restart rsyslog  
```
service rsyslog restart 
```

## Import template
Import syslog template and attach it to hosts from which you expect syslog messages to come  

## Create user in Zabbix frontend for syslog  
NOTE: you can use your admin user for testing  
It is recommended to create separate user in order to retreive hostnames and check syslog items existence via Zabbix API. 
Simple user with READ permissions for each Host group should be enough.
If you use map context menu script `zabbix_syslog_create_urls.pl` then also check for write permessions to maps.  

# Troubleshooting
Make sure that script `/etc/zabbix/scripts/zabbix_syslog_lkp_host.pl` is exetuable under rsyslog system user.  
Run it by hand to see that all perl modules are available under that user (probably `root`).  

## Suggested Test 1  
Do the following test:
 - In Zabbix create the test host with host interface of any type. Assign IP=127.0.0.1 to this host interface.  
 - Attach Template Syslog to this host.  
 - Under user `root` (or user that runs rsyslog):  
`echo "2017-12-19T09:26:26.314936+03:00 [127.0.0.1] syslog.info SysLogTest[4616]Test syslog message" | /etc/zabbix/scripts/zabbix_syslog_lkp_host.pl`
then check that this message can be found in item with key = `syslog`.  

## Suggested Test 2  
 - Stop rsyslog daemon  
 - run rsyslogd in the interactive mode: `rsyslogd -n`  
 - open another terminal and send a test syslog message connecting to IP address other than 127.0.0.1:  
 `logger -n 192.168.56.15`.  
 - then type some test message like so: `hello world`  
 - observe what actually script returns when processing this test syslog message.  
 For example:  
 ```
 [root@zabbix-lab vagrant]# rsyslogd -n
rsyslogd: error during config processing: STOP is followed by unreachable statements!  [v8.24.0 try http://www.rsyslog.com/e/2207 ]
Can't locate ZabbixAPI.pm in @INC (@INC contains: /etc/zabbix/scripts/lib /usr/local/lib64/perl5 /usr/local/share/perl5 /usr/lib64/perl5/vendor_perl /usr/share/perl5/vendor_perl /usr/lib64/perl5 /usr/share/perl5 .) at /etc/zabbix/scripts/zabbix_syslog_lkp_host.pl line 11.
BEGIN failed--compilation aborted at /etc/zabbix/scripts/zabbix_syslog_lkp_host.pl line 11.
rsyslogd: Child 15334 has terminated, reaped by main-loop. [v8.24.0 try http://www.rsyslog.com/e/0 
```
If this doesn't help, then try again this time running rsyslogd in the debug mode:
`rsyslogd -dn`  

# More info:  
https://habrahabr.ru/company/zabbix/blog/252915/  (RU)
