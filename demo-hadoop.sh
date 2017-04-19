#! /bin/bash -xe

if [ -z "$3" ]; then
	cat <<EOF
Usage: $0 MASTER_HOSTNAME MASTER_IP DEVICE [ROLE [DEPLOYED]]"

  ROLE: master|slave
  DEPLOYED: true|false
EOF
	exit 1
fi

if [ ! -d /etc/puppet/modules/hadoop ]; then
	apt-get update
	apt-get dist-upgrade -y
	apt-get install -y --no-install-recommends puppet

	puppet module install cesnet-site_hadoop
	puppet module install cesnet-hue
fi

MASTER="$1"
MASTER_IP="$2"
DEVICE="$3"
ROLE="${4:-slave}"
DEPLOYED="${5:-true}"

# local IP dynamicaly (we need to know device)
FQDN="`ip -4 addr show dev \"$DEVICE\" | grep inet  | awk '{print $2}' | cut -d/ -f1`"
if [ $? -ne 0 ]; then
	echo "Device $2 not found"
	exit 1
fi

# puppet hadoop module role detections according to FQDN (hacky)
if [ "$ROLE" = "slave" ]; then
	SLAVES="['$FQDN']"
else
	SLAVES='[]'
fi

cat > site.pp <<EOF
\$master = '$MASTER'
\$zookeepers = [
  \$master,
]
\$hdfs_deployed = $DEPLOYED
\$acl = true

include ::stdlib

class { '::java_ng':
  ensure  => 'held',
  repo    => 'ppa:oracle',
  version => 8,
  stage   => 'setup',
}

class { '::hadoop':
  hdfs_hostname       => \$master,
  yarn_hostname       => \$master,
  frontends           => [\$master],
  slaves              => $SLAVES,
  zookeeper_hostnames => \$zookeepers,
  hue_hostnames       => [\$master],
  httpfs_hostnames    => [\$master],
  oozie_hostnames     => [\$master],
  acl                 => \$acl,
  hdfs_deployed       => \$hdfs_deployed,
  features            => {
    aggregation   => true,
    multihome     => true,
    yellowmanager => true,
  },
  properties => {
    'dfs.replication'                                      => 2,
    'hadoop.security.auth_to_local'                        => '::undef',
    # need that without DNS infrastructure
    'dfs.namenode.datanode.registration.ip-hostname-check' => false,
  }
}

class { '::impala':
  catalog_hostname    => \$master,
  statestore_hostname => \$master,
  features            => {
    launcher => true,
    manager  => true,
  },
  parameters => {
    catalog => {
      authorized_proxy_user_config => "'hue=*'",
    },
    server => {
      authorized_proxy_user_config => "'hue=*'",
    },
    statestore => {
      authorized_proxy_user_config => "'hue=*'",
    },
  },
}

class { '::hbase':
  acl                 => \$acl,
  hdfs_hostname       => \$master,
  master_hostname     => \$master,
  slaves              => $SLAVES,
  zookeeper_hostnames => \$zookeepers,
  features            => {
    hbmanager => true,
  },
}

class { '::hive':
  metastore_hostname  => \$master,
  server2_hostname    => \$master,
  zookeeper_hostnames => \$zookeepers,
  db                  => 'mysql',
  db_password         => 'hive_rw_password',
  features            => {
    manager => true,
  },
}

class { '::oozie':
  #defaultFS   => "hdfs://\$master:8020",
  hdfs_hostname => \$master,
  hue_hostnames => [\$master],
  acl         => true,
  db          => 'mysql',
  db_password => 'oozie_rw_password',
  gui_enable  => false,
}

class { '::spark':
  hdfs_hostname          => \$master,
  historyserver_hostname => \$master,
}

class { '::site_hadoop':
  # too ugly (binding not configurable, requires NAT everywhere)
  hbase_enable        => false,
  hue_enable          => true,
  impala_enable       => true,
  java_enable         => false,
  # TODO: authorization (as root)
  nfs_frontend_enable => false,
  oozie_enable        => true,
  users               => [
    'hawking',
  ],
  version             => '5.11',
}

EOF

case $ROLE in
  master)
    # we have a hostname for master
    export FACTER_fqdn="$MASTER"

    cat >> site.pp <<EOF
# required for hive, oozie
class { '::mysql::bindings':
  java_enable => true,
}

class { '::mysql::server':
  root_password => 'mysql_rw_password',
}

if \$hdfs_deployed {
  class { '::hue':
    hdfs_hostname          => \$master,
    historyserver_hostname => \$master,
    hive_server2_hostname  => \$master,
    httpfs_hostname        => \$master,
    impala_hostname        => \$master,
    oozie_hostname         => \$master,
    yarn_hostname          => \$master,
    db                     => 'mysql',
    db_password            => 'hue_rw_password',
    https                  => false,
    https_hue              => true,
	https_cachain          => '/etc/grid-security/ca-chain.pem',
    secret                 => 'American president can\'t read',
    properties => {
      'desktop.app_blacklist'   => 'hbase,search,sentry,spark,sqoop,zookeeper',
    },
  }
}

class { '::zookeeper':
  hostnames => \$zookeepers,
}

include ::site_hadoop::role::master
include ::site_hadoop::role::frontend
include ::site_hadoop::role::hue
# just to found any impala server
include ::impala::server
include ::hadoop::httpfs
EOF
    # from external network permit only the status html pages
    cat > /etc/network/if-pre-up.d/iptables <<EOF2
#! /bin/sh
/sbin/iptables-restore <<EOF
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:fail2ban-ssh - [0:0]

-A INPUT -i lo -j ACCEPT
-A INPUT -i eth1 -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -p tcp -m multiport --dports 22 -j fail2ban-ssh
# HDFS, YARN, Spark HS, JHS, Impala (impalad, state, catalog), HBase
-A INPUT -p tcp -m multiport --dports 50070,8088,18088,19888,8888,25000,25010,25020,60010 -j fail2ban-ssh
-A INPUT -j REJECT

-A fail2ban-ssh -j ACCEPT
COMMIT
EOF
EOF2
    sed -e 's,/sbin/iptables-restore,/sbin/ip6tables-restore,' /etc/network/if-pre-up.d/iptables > /etc/network/if-pre-up.d/ip6tables
    chmod +x /etc/network/if-pre-up.d/ip*tables
    /etc/network/if-pre-up.d/iptables
    /etc/network/if-pre-up.d/ip6tables
    ;;
  slave)
    # force proper IP addres for slave (no hostname for slave)
    export FACTER_fqdn="$FQDN"

    cat >> site.pp <<EOF
include ::site_hadoop::role::slave
EOF
    ;;
  *)
    ;;
esac

# hadoop requires hostname for namenode (DNS or hosts file)
if ! grep -q "\\<$MASTER_IP\\>.*\\<$MASTER\\>" /etc/hosts; then
  echo "$MASTER_IP ${MASTER}. ${MASTER}" >> /etc/hosts
  if [ -f /etc/cloud/cloud.cfg ]; then
    sed -e 's,^\(\s*manage_etc_hosts\):.*,\1: False,' -i /etc/cloud/cloud.cfg
  fi
fi

# launch!
puppet apply --test ./site.pp

# no security needed for impala
adduser impala users
