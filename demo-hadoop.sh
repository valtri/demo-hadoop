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
HBASE='false'
NFS='false'

# local IP dynamicaly (we need to know device)
IP="`ip -4 addr show dev \"$DEVICE\" | grep inet  | awk '{print $2}' | cut -d/ -f1`"
if [ $? -ne 0 ]; then
  echo "Device $2 not found"
  exit 1
fi

# puppet hadoop module role detections is according to FQDN (hacky)
if [ "$ROLE" = "slave" ]; then
  SLAVES="['$IP']"
else
  SLAVES='[]'
fi

if [ "$HBASE" = "true" ]; then
  hue_blacklist="search,sentry,spark,sqoop,zookeeper"
else
  hue_blacklist="hbase,search,sentry,spark,sqoop,zookeeper"
fi

# rack awareness (optional)
if [ -f /usr/local/sbin/topology ]; then
  topology="    'net.topology.script.file.name'                        => '/usr/local/sbin/topology',
"
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
  hue_hostnames       => [\$master],
  httpfs_hostnames    => [\$master],
  nfs_hostnames       => [\$master],
  oozie_hostnames     => [\$master],
  zookeeper_hostnames => \$zookeepers,
  acl                 => \$acl,
  hdfs_deployed       => \$hdfs_deployed,
  features            => {
    aggregation   => true,
    multihome     => true,
    yellowmanager => true,
  },
  properties => {
    'dfs.namenode.acls.enabled'                            => true,
    'dfs.replication'                                      => 3,
    'hadoop.security.auth_to_local'                        => '::undef',
    # need that without DNS infrastructure
    'dfs.namenode.datanode.registration.ip-hostname-check' => false,
    # shorter heartbeat
    'dfs.heartbeat.interval'                               => 2,
    # shorter patience (2 minutes to detect offline datanode)
    'dfs.namenode.heartbeat.recheck-interval'              => 60000,
    'nfs.exports.allowed.hosts'                            => "\$::fqdn rw; \$::ipaddress_${DEVICE} rw",
$topology  }
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
  thrift_hostnames    => [ \$master ],
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
  hbase_enable        => $HBASE,
  hue_enable          => true,
  impala_enable       => true,
  java_enable         => false,
  nfs_frontend_enable => $NFS,
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
      'desktop.app_blacklist'   => '$hue_blacklist',
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
    # for hue
    if [ "$HBASE" = "true" ]; then
      echo "include ::hbase::thriftserver" >> site.pp
    fi
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
-A INPUT -i $DEVICE -j ACCEPT
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

    apt-get install -y python-snappy || :
    ;;
  slave)
    # force proper IP addres for slave (no hostname for slave)
    export FACTER_fqdn="$IP"

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
ret=0
puppet apply --test ./site.pp || ret=$?

if [ $ret -gt 1 ]; then
  # no security needed for impala
  adduser impala users

  # impala server can't recover when HDFS is initially installed
  if [ "$DEPLOYED" = "true" ]; then
    impmanager restart || :
  fi
fi

exit $ret
