#! /bin/sh

if [ -n "$MASTER" ]; then
	hivemanager stop clean || :
	service hue stop  || :
	service oozie stop || :
	service zookeeper-server stop || :
	mysql -u root -e 'DROP DATABASE oozie' || :
	mysql -u root -e 'DROP DATABASE metastore' || :
	mysql -u root -e 'DROP DATABASE hue' || :
	rm -fv /var/lib/oozie/.puppet* /var/lib/hue/.puppet-*
fi

hbmanager stop clean || :
impmanager stop clean || :
yellowmanager stop clean || :
rm -rf /var/lib/hadoop-hdfs/.puppet* /var/lib/hadoop-hdfs/cache/hdfs /var/lib/hadoop-yarn/cache/yarn /var/lib/zookeeper/version* /var/lib/zookeeper/myid
