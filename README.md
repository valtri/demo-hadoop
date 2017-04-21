# Demo Hadoop script

The script will install unsecured Hadoop cluster, which is expected to be run inside private network. Hue web interface has enabled https, so certificates for the public endpoint are required.

Enabled Hadoop parts and add-ons:

* Hadoop HDFS
* Hadoop YARN
* Hive
* Hue (plus required add-ons Oozie, httpfs)
* Impala
* Pig
* Spark

Supported platforms (2017):

* Debian 7/wheezy (except master, [Bug #828836](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=828836), requires pre-installed puppet >= 3)
* Debian 8/jessie
* Ubuntu 14/trusty
* Ubuntu 16/xenial

Network requirements (for all nodes):

* all hostnames in DNS or host files
* when enabling HBase, only one interface may be available, or use NAT PREROUTING rules

CESNET puppet modules are used are used for installation and setup.

# Deployment

Replace *$MASTER\_HOSTNAME*, *$MASTER\_IP*, and *$DEVICE* variables by proper values. For example:

    MASTER_HOSTNAME='hadoop-master'
    MASTER_IP='192.168.0.1'
    DEVICE='eth0'

Device is the private interface to run Hadoop cluster.

Optionaly network topology script can be installed as */usr/local/sbin/topology*.

Note, the master has installation in two-steps.

## Master - preparation

Store certificates in */etc/grid-security*:

* *hostcert.pem*
* *hostkey.pem*
* *ca-chain.pem*

Preparation:

    ./demo-hadoop.sh $MASTER_HOSTNAME $MASTER_IP $DEVICE master false

## Workers

    ./demo-hadoop.sh $MASTER_HOSTNAME $MASTER_IP $DEVICE

## Master

    ./demo-hadoop.sh $MASTER_HOSTNAME $MASTER_IP $DEVICE master true

# Result

* http://$MASTER\_HOSTNAME:50070 - HDFS service status page
* https://$MASTER\_HOSTNAME:8888 - Hue web interface
