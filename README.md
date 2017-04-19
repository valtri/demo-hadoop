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

* Debian 7/wheezy
* Debian 8/jessie
* Ubuntu 14/trusty
* Ubuntu 16/xenial

CESNET puppet modules are used are used for installation and setup.

# Deployment

Replace *$MASTER\_HOSTNAME*, *$MASTER\_IP*, and *$DEVICE* variables by proper values. For example:

    MASTER_HOSTNAME='hadoop-master'
	MASTER_IP='192.168.0.1'
    DEVICE='eth0'

Device is the private interface to run Hadoop cluster.

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
