#!/usr/bin/env bash

# purpose: Support spark with mesos on docker. Only net mode is supported since
# there is a bug on the mesos side and spark may need patching.

set -e

################################ VARIABLES #####################################

SCRIPT=`basename ${BASH_SOURCE[0]}`
SCRIPTPATH="$( cd "$(dirname "$0")" ; pwd -P )"

#image tag serves as the version
IMAGE_VERSION=latest
MASTER_CONTAINER_NAME="spm_master"
SLAVE_CONTAINER_NAME="spm_slave"
MASTER_IMAGE="spark_mesos_dind:$IMAGE_VERSION"
SLAVE_IMAGE="spark_mesos_dind:$IMAGE_VERSION"
DOCKER_USER="lightbend"
NUMBER_OF_SLAVES=2
SPARK_BINARY_PATH=
SPARK_VERSION=
INSTALL_HDFS=1
START_SHUFFLE_SERVICE=1
IS_QUIET=
SPARK_FILE=
MESOS_MASTER_CONFIG=
MESOS_SLAVE_CONFIG=
HADOOP_FILE=
RESOURCE_THRESHOLD=1.0
SLAVES_CONFIG_FILE=
INSTALL_ZK=
INSTALL_MARATHON=
MIT_IMAGE_MESOS_VERSION=
HISTORY_SERVER=

MEM_HOST_PERCENTAGE=$RESOURCE_THRESHOLD
CPU_HOST_PERCENTAGE=$RESOURCE_THRESHOLD

SPARK_CONF_FOLDER="/etc/spark/conf"

# Make sure we have docker installed on OSX.
if [ "$(uname)" = "Darwin" ]
then
  type docker > /dev/null 2>&1
  if [ $? -ne 0 ]
  then
    echo "OSX: Docker not found. Please install from https://www.docker.com/"
    exit 1
  fi
fi

################################ FUNCTIONS #####################################

function get_latest_spark_version {
  wget -qO- $MIRROR_SITE/mirror/apache/dist/spark/ | \
  grep "spark-[0-9].[0-9].[0-9]" | \
    uniq | sort | tail -n1 | \
    sed 's/^.*spark-\([0-9].[0-9].[0-9]\(-preview\)*\).*$/\1/g'
}

function docker_ip {
  if [[ "$(uname)" == "Darwin" ]]; then
    docker-machine ip default
  else
    /sbin/ifconfig docker0 | awk '/addr:/{ print $2;}' |  sed  's/addr://g'
  fi
}

function print_host_ip {
  printMsg "IP address of the docker host machine is $(get_host_ip)"
}

function get_host_ip {
  if [[ "$(uname)" == "Darwin"  ]]; then
    #Getting the IP address of the host as it seen by docker container
    masterContainerId=$(docker ps -a | grep $MASTER_CONTAINER_NAME | awk '{print $1}')
    docker exec -it $masterContainerId /bin/sh -c "sudo ip route" | awk '/default/ { print $3 }'
  else
    docker_ip
  fi
}

function default_mesos_lib {
  if [[ "$(uname)" == "Darwin"  ]]; then
    echo "/usr/local/lib/libmesos.dylib"
  else
    echo "/usr/local/lib/libmesos.so"
  fi
}

function generate_application_conf_file {
  hdfs_url="hdfs://$(docker_ip):8020"
  host_ip="$(get_host_ip)"
  spark_tgz_file="/var/spark/$SPARK_FILE"
  mesos_native_lib="$(default_mesos_lib)"

  source_location="$SCRIPTPATH/../../test-runner/src/main/resources"
  target_location="$SCRIPTPATH/../../test-runner"

  cp "$source_location/application.conf.template" "$target_location/mit-application.conf"
  sed -i -- "s@replace_with_mesos_lib@$mesos_native_lib@g" "$target_location/mit-application.conf"
  sed -i -- "s@replace_with_hdfs_uri@$hdfs_url@g" "$target_location/mit-application.conf"
  sed -i -- "s@replace_with_docker_host_ip@$host_ip@g" "$target_location/mit-application.conf"
  sed -i -- "s@replace_with_spark_executor_uri@$spark_tgz_file@g" "$target_location/mit-application.conf"

  if [[ -n $INSTALL_ZK ]];then
    echo "spark.zk.uri = \"zk://$(docker_ip):2181\""  >> "$target_location/mit-application.conf"
  fi

  #remove any temp file generated (on OS X)
  rm -f "$target_location/mit-application.conf--"

  printMsg "---------------------------"
  printMsg "Generated application.conf file can be found here: $target_location/mit-application.conf"
  printMsg "---------------------------"
}

function check_if_service_is_running {
  COUNTER=0
  while ! nc -z $dip $2; do
    echo -ne "waiting for $1 at port $2...$COUNTER\r"
    sleep 1
    let COUNTER=COUNTER+1
  done
}

function check_if_container_is_up {
  printMsg "Checking if container $1 is up..."
  #wait to avoid temporary running window...
  sleep 1
  if [[ "$(docker inspect -f {{.State.Running}} $1)" = "false" ]]; then
    echo >&2 "$1 container failed to start...  Aborting."; exit 1;
  else
    printMsg "Container $1 is up..."
  fi
}

function quote_if_non_empty {
  if [[ -n $1 ]];then
    echo "\"$@\""
  else
    echo ""
  fi
}

#
# Compares mesos version on host vs on docker images used.
# If different warn the user.
#
function check_mesos_version {
  local declare MIT_MESOS_HOST_VERSION
  if [[ "$(uname)" == "Darwin" ]]; then
    MIT_MESOS_HOST_VERSION=$(brew info mesos | grep 'mesos:' | awk '{print $3}')
  else
    MIT_MESOS_HOST_VERSION=$(dpkg -s mesos | grep Version | awk '{print $2}')
  fi
  local MIT_MESOS_LIB_DOCKER_VERSION=$(docker exec $1 sh -c "dpkg -s mesos | grep Version" |  awk '{print $2}')\

  if [[ "$MIT_MESOS_HOST_VERSION" != "$MIT_MESOS_LIB_DOCKER_VERSION" ]]; then
    printMsg "WARN: Host and docker image have different libmesos versions, Host:$MIT_MESOS_HOST_VERSION, Image: $MIT_MESOS_LIB_DOCKER_VERSION (image always reflects the latest version). Pls upgrade host."
  fi
}

#
# Returns a string of the command to upgrade or downgrade a package to a specific version
# $1 the name of the package eg. mesos
# $2 the version to upgrade or downgrade to
#
function update_package_str {
  local RET="\$(apt-cache policy $1 | sed -n -e '/Version table:/,$p' | sed 's/\*\*\*//g' | grep "$2" | awk {'print $1'} | head -1)"
  RET="apt-get -qq --yes --force-yes install $1=$RET"
  echo $RET
}

#
# Returns a string of the command to upgrade or downgrade mesos from its repository
#
function get_mesos_update_command {
  com="apt-get update -o Dir::Etc::sourcelist=sources.list.d/mesosphere.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0"

  if [[ -n $MIT_IMAGE_MESOS_VERSION ]];  then
      com="$com; $(update_package_str "mesos" "$MIT_IMAGE_MESOS_VERSION")"
  else
    if [[ -n $MIT_DOCKER_MESOS_VERSION ]]; then
      com="$com; $(update_package_str "mesos" "$MIT_DOCKER_MESOS_VERSION")"
    else
      com="$com; apt-get -qq --yes --force-yes install --only-upgrade mesos"
    fi
  fi
  echo $com
}

#
# Starts the mesos master.
#
function start_master {
  #pull latest image to get any changes (the image is common between master nad slave so we
  #need this once).
  docker pull $DOCKER_USER/$MASTER_IMAGE

  dip=$(docker_ip)

  if [[ -n $INSTALL_ZK ]]; then
    zk="--zk=zk://$dip:2181/mesos"
  fi

  start_master_command="/usr/sbin/mesos-master $zk --ip=$dip $(quote_if_non_empty $MESOS_MASTER_CONFIG)"
  start_master_command="$(get_mesos_update_command) ; $start_master_command"

  if [[ -n $INSTALL_HDFS ]]; then
    HADOOP_VOLUME="-v $HADOOP_BINARY_PATH:/var/tmp/$HADOOP_FILE"
  else
    HADOOP_VOLUME=
  fi

  docker run -p 5050:5050 \
  -e "MESOS_EXECUTOR_REGISTRATION_TIMEOUT=5mins" \
  -e "MESOS_ISOLATOR=cgroups/cpu,cgroups/mem" \
  -e "MESOS_PORT=5050" \
  -e "MESOS_LOG_DIR=/var/log" \
  -e "MESOS_REGISTRY=in_memory" \
  -e "MESOS_WORK_DIR=/tmp/mesos" \
  -e "MESOS_CONTAINERIZERS=docker,mesos" \
  -e "DOCKER_IP=$dip" \
  -e "IT_DFS_DATANODE_ADDRESS_PORT=50010" \
  -e "USER=root" \
  --privileged=true \
  --pid=host \
  --expose=5050 \
  --net=host \
  -d \
  --name $MASTER_CONTAINER_NAME \
  -v "$SCRIPTPATH/hadoop":/var/hadoop \
  -v "$SPARK_BINARY_PATH":/var/spark/$SPARK_FILE  $HADOOP_VOLUME \
  $DOCKER_USER/$MASTER_IMAGE /bin/bash -c "$start_master_command"

  check_if_container_is_up $MASTER_CONTAINER_NAME
  check_if_service_is_running mesos-master 5050
  check_mesos_version $MASTER_CONTAINER_NAME

  if [[ -n $INSTALL_ZK ]]; then
    docker exec $MASTER_CONTAINER_NAME /bin/bash -c "service zookeeper start"
    check_if_service_is_running zk 2181
  fi

  if [[ -n $INSTALL_MARATHON ]]; then
    docker exec $MASTER_CONTAINER_NAME mkdir -p /etc/marathon/conf
    MARATHON_ZK="zk://localhost:2181/marathon"
    MARATHON_MASTER="zk://localhost:2181/mesos"
    MARATHON_COMMAND="nohup /marathon-1.1.1/bin/start --master $MARATHON_MASTER --zk $MARATHON_ZK"
    docker exec -d $MASTER_CONTAINER_NAME /bin/bash -c "$MARATHON_COMMAND"
    check_if_service_is_running marathon 8080
  fi

  if [[ -n $INSTALL_HDFS ]]; then
    docker exec -e HADOOP_VERSION=$HADOOP_VERSION $MASTER_CONTAINER_NAME  /bin/bash /var/hadoop/hadoop_setup.sh
    docker exec $MASTER_CONTAINER_NAME /usr/local/bin/hdfs namenode -format -nonInterActive
    docker exec $MASTER_CONTAINER_NAME /usr/local/sbin/hadoop-daemon.sh --script hdfs start namenode
    docker exec $MASTER_CONTAINER_NAME /usr/local/sbin/hadoop-daemon.sh --script hdfs start datanode
  fi
}

#
# Starts history server on master docker instance
#
function start_history_server {
  HISTORY_FOLDER="spark_history"
  if [[ -n $HISTORY_SERVER ]]; then
    docker exec $MASTER_CONTAINER_NAME /bin/bash -c "hadoop fs -mkdir /$HISTORY_FOLDER"
    docker exec $MASTER_CONTAINER_NAME /bin/bash -c "tar xzf /var/spark/$SPARK_FILE -C /tmp/"
    docker exec $MASTER_CONTAINER_NAME /bin/bash -c "/tmp/${SPARK_FILE%.*}/sbin/start-history-server.sh --dir hdfs://$(docker_ip):8020/$HISTORY_FOLDER"
  fi
}

#
# Checks if hadoop or spark binary distributions are specified.
# If not it downloads the latest binaries.
#
function get_binaries {
  SPARK_VERSION="$(get_latest_spark_version)"

  if [[ -z $SPARK_FILE ]]; then
    SPARK_FILE="spark-$SPARK_VERSION-bin-hadoop${HADOOP_VERSION}.tgz"
  fi

  if [[ -z "${SPARK_BINARY_PATH}" ]]; then
    SPARK_BINARY_PATH=$SCRIPTPATH/binaries/$SPARK_FILE
    if [ ! -f "$SPARK_BINARY_PATH" ]; then
      wget -P $SCRIPTPATH/binaries/ "$MIRROR_SITE/mirror/apache/dist/spark/spark-$SPARK_VERSION/$SPARK_FILE"
    fi
  fi

  if [[ -n $INSTALL_HDFS ]]; then
    if [[ -z "${HADOOP_BINARY_PATH}" ]]; then
      HADOOP_BINARY_PATH=$SCRIPTPATH/binaries/$HADOOP_FILE
      if [ ! -f "$HADOOP_BINARY_PATH" ]; then
        TMP_FILE_PATH="hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}.tar.gz"
        wget -P $SCRIPTPATH/binaries/ "$MIRROR_SITE/mirror/apache/dist/hadoop/common/$TMP_FILE_PATH"
      fi
    fi
  fi
}

function calcf {
  awk "BEGIN { print "$*" }"
}

function get_cpus {
  if [[ "$(uname)" == "Darwin" ]]; then
    sysctl -n hw.ncpu
  else
    nproc
  fi
}

function get_mem {
  #in Mbs
  if [[ "$(uname)" == "Darwin"  ]]; then
    m=`docker info | awk  '/Memory/ {print $3; exit}'`
    echo "$m"
  else
    m=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    echo "$((m/1000))"
  fi
}

function remove_quotes {
  echo "$1" | tr -d '"'
}

#
# Starts the mesos slaves.
# Note: #libapparmor is needed
#       https://github.com/RayRutjes/simple-gitlab-runner/pull/1
#
function start_slaves {
  dip=$(docker_ip)

  if [[ -n $INSTALL_ZK ]]; then
    master="zk://$dip:2181/mesos"
  else
    master="$dip:5050"
  fi

  number_of_ports=3

  for i in `seq 1 $NUMBER_OF_SLAVES`;
  do
    start_slave_command="nohup /usr/local/bin/wrapdocker; /usr/sbin/mesos-agent --master=$master --work_dir=/tmp --ip=$dip $(quote_if_non_empty $MESOS_SLAVE_CONFIG)"
    start_slave_command="$(get_mesos_update_command) ; $start_slave_command"

    echo "starting slave ...$i"
    cpus=$(calcf $(($(get_cpus)/$NUMBER_OF_SLAVES))*$CPU_HOST_PERCENTAGE)
    mem=$(calcf $(($(get_mem)/$NUMBER_OF_SLAVES))*$MEM_HOST_PERCENTAGE)

    echo "Using $cpus cpus and ${mem}M memory for slaves."

    if [[ -n $INSTALL_HDFS ]]; then
      HADOOP_VOLUME="-v $HADOOP_BINARY_PATH:/var/tmp/$HADOOP_FILE"
    else
      HADOOP_VOLUME=
    fi

    if [[ -n $SLAVES_CONFIG_FILE ]]; then
      resources_cfg=$(get_field_value_from_slave_cfg_at_index resources $SLAVES_CONFIG_FILE $(($i-1)))
      attributes_cfg=$(get_field_value_from_slave_cfg_at_index attributes $SLAVES_CONFIG_FILE $(($i-1)))
    fi

    if [[ -n $resources_cfg ]]; then
      resources_cfg=$(remove_quotes "--resources=$resources_cfg")
    else
      resources_cfg=""
    fi

    if [[ -n $attributes_cfg ]]; then
      attributes_cfg=$(remove_quotes "--attributes=$attributes_cfg")
    else
      attributes_cfg=""
    fi

    start_slave_command="$start_slave_command  $(quote_if_non_empty $resources_cfg) $(quote_if_non_empty $attributes_cfg)"

    docker run \
    -e "MESOS_PORT=$((5050 + $i))" \
    -e "MESOS_SWITCH_USER=false" \
    -e "MESOS_RESOURCES=cpus(*):$cpus;mem(*):$mem" \
    -e "MESOS_ISOLATOR=cgroups/cpu,cgroups/mem" \
    -e "MESOS_EXECUTOR_REGISTRATION_TIMEOUT=5mins" \
    -e "MESOS_CONTAINERIZERS=docker,mesos" \
    -e "MESOS_LOG_DIR=/var/log" \
    -e "IT_DFS_DATANODE_ADDRESS_PORT=$((50100 + $(($i -1))*$number_of_ports + 1 ))" \
    -e "IT_DFS_DATANODE_HTTP_ADDRESS_PORT=$((50100 + $(($i -1))*$number_of_ports + 2))" \
    -e "IT_DFS_DATANODE_IPC_ADDRESS_PORT=$((50100 + $(($i -1))*$number_of_ports + 3))" \
    -e "SPARK_CONF_DIR=$SPARK_CONF_FOLDER" \
    -e "DOCKER_IP=$dip" \
    -e "USER=root" \
    -d \
    --privileged=true \
    --pid=host \
    --net=host \
    --name "$SLAVE_CONTAINER_NAME"_"$i" -it \
    -v "$SPARK_BINARY_PATH":/var/spark/$SPARK_FILE $HADOOP_VOLUME \
    -v "$SCRIPTPATH/hadoop":/var/hadoop \
    $DOCKER_USER/$SLAVE_IMAGE /bin/bash -c "$start_slave_command"

    check_if_container_is_up "$SLAVE_CONTAINER_NAME"_"$i"
    check_if_service_is_running mesos-agent $((5050 + $i))

    if [[ -n $INSTALL_HDFS ]]; then
      docker exec -e HADOOP_VERSION=$HADOOP_VERSION "$SLAVE_CONTAINER_NAME"_"$i" /bin/bash /var/hadoop/hadoop_setup.sh SLAVE
      docker exec "$SLAVE_CONTAINER_NAME"_"$i" /usr/local/sbin/hadoop-daemon.sh --script hdfs start datanode
    fi

    if [[ -n $START_SHUFFLE_SERVICE ]]; then
      start_shuffle_service_command="/bin/mkdir -p $SPARK_CONF_FOLDER"
      start_shuffle_service_command="$start_shuffle_service_command; /bin/echo 'spark.shuffle.service.port $((7336 + i))' >> $SPARK_CONF_FOLDER/spark-defaults.conf"
      start_shuffle_service_command="$start_shuffle_service_command; /bin/tar -C /opt/ -xf /var/spark/$SPARK_FILE"
      start_shuffle_service_command="$start_shuffle_service_command; /opt/spark*/sbin/start-mesos-shuffle-service.sh"
      docker exec "$SLAVE_CONTAINER_NAME"_"$i" /bin/bash -c "$start_shuffle_service_command"
    fi
  done
}

#
# Replaces the contents in a file with that of a variable emmittigna new file
# $1 variable
# $2 pattern
# $3 file_in
# $4 file_out
#
function replace_in_htmlfile_multi {
  if [[ "$(uname)" == "Darwin" ]]; then
    l_var="$1"
  awk -v r="${l_var//$'\n'/\\n}" "{sub(/$2/,r)}1" $3 >  $SCRIPTPATH/tmp_file && mv $SCRIPTPATH/tmp_file $4
  else
    awk -v r="$1" "{gsub(/$2/,r)}1" $3 >  $SCRIPTPATH/tmp_file && mv $SCRIPTPATH/tmp_file $4
  fi
}

#
# Creates the index.html in current dir, containing urls to several components'
# uis eg. zookeeper, hdfs, mesos etc.
#
function create_html {
  TOTAL_NODES=$(($NUMBER_OF_SLAVES + 1 ))
  HTML_SNIPPET=

  for i in `seq 1 $NUMBER_OF_SLAVES` ; do
    HTML_SNIPPET=$HTML_SNIPPET"<div>Slave $i: $(docker_ip):$((5050 + $i))</div>"
  done

  node_info=$(cat <<EOF
<div class="my_item">Total Number of Nodes: $TOTAL_NODES (1 Master, $NUMBER_OF_SLAVES Slave(s))</div>
<div>Mesos Master: $(docker_ip):5050 </div>
$HTML_SNIPPET
<div style="margin-top:1em">The IP of the docker interface on host: $(docker_ip)</div>
<div class="my_item">$(print_host_ip)</div>
<div class="alert alert-success" role="alert">Your cluster is up and running!</div>
EOF
)
  replace_in_htmlfile_multi "$node_info" "REPLACE_NODES" "$SCRIPTPATH/template.html" "$SCRIPTPATH/index.html"
  HDFS_SNIPPET_1=
  HDFS_SNIPPET_OUT=
  MARATHON_SNIPPET=
  HISTORY_SERVER_SNIPPET=
  ZK_SNIPPET=
  MESOS_OUTPUT="$(curl -s http://$(docker_ip):5050/master/state.json | python -m json.tool)"

  if [[ -n $INSTALL_HDFS ]]; then
    HDFS_SNIPPET_1="<div class=\"my_item\"><a data-toggle=\"tooltip\" data-placement=\"top\" data-original-title=\"$(docker_ip):50070\" href=\"http://$(docker_ip):50070\">Hadoop UI</a></div>\
    <div>HDFS url: hdfs://$(docker_ip):8020</div>"
    HDFS_SNIPPET_OUT="<div> <a href=\"#\" id=\"hho_link\"> Hadoop Healthcheck output </a></div> \
    <div id=\"hho\" class=\"my_item\"><pre>$(docker exec spm_master hdfs dfsadmin -report)</pre></div>"
  fi

  if [[ -n  $INSTALL_ZK ]]; then
    ZK_SNIPPET="<div>Zookeeper uri: zk://$(docker_ip):2181</div>"
  fi

  if [[ -n $INSTALL_MARATHON ]]; then
    MARATHON_SNIPPET="<div> <a data-toggle=\"tooltip\" data-placement=\"top\" data-original-title=\"$(docker_ip):8888\" href=\"http://$(docker_ip):8080\">Marathon UI</a> </div>"
  fi

  if [[ -n $HISTORY_SERVER ]]; then
    HISTORY_SERVER_SNIPPET="<div> <a data-toggle=\"tooltip\" data-placement=\"top\" data-original-title=\"$(docker_ip):18080\" href=\"http://$(docker_ip):18080\">History Server UI</a> </div>"
  fi

  dash_info=$(cat <<EOF
$MARATHON_SNIPPET
$HISTORY_SERVER_SNIPPET
<div> <a data-toggle="tooltip" data-placement="top" data-original-title="$(docker_ip):5050" href="http://$(docker_ip):5050">Mesos UI</a> </div>
$HDFS_SNIPPET_1
$ZK_SNIPPET
<div>Spark Uri: /var/spark/${SPARK_FILE}</div>
<div>History Server: http://$(docker_ip):18080</div>
<div class="my_item">Spark master: mesos://$(docker_ip):5050</div>

$HDFS_SNIPPET_OUT
<div> <a href="#" id="mho_link"> Mesos Healthcheck output </a></div>
<div id="mho"><pre>$MESOS_OUTPUT</pre></div>
<div style="margin-top:10px;" class="alert alert-success" role="alert">Your cluster is up and running!</div>
EOF
)
  replace_in_htmlfile_multi "$dash_info" "REPLACE_DASHBOARDS" "$SCRIPTPATH/index.html" "$SCRIPTPATH/index.html"
}

#
# Removed a docker container with a specific prefix in its name.
# $1 prefix of the cotnainer name
#
function remove_container_by_name_prefix {
  if [[ "$(uname)" == "Darwin" ]]; then
    input="$(docker ps -a | grep $1 | awk '{print $1}')"

    if [[ -n "$input"  ]]; then
      echo "$input" | xargs docker rm -f
    fi
  else
    docker ps -a | grep $1 | awk '{print $1}' | xargs -r docker rm -f
  fi
}

function show_help {
  cat<< EOF
  This script creates a mini mesos cluster for testing purposes.
  Usage: $SCRIPT [OPTIONS]

  eg: ./run.sh --number-of-slaves 3 --image-version 0.0.1

  Options:

  --cpu-host-percentage the percentage of the host cpu to use for slaves. Default: 0.5.
  --hadoop-binary-file the hadoop binary file to use in docker configuration (optional, if not present tries to download the binary).
  -h|--help prints this message.
  --image-version the image version to use for the containers (optional, defaults to the latest hardcoded value).
  --mem-host-percentage the percentage of the host memory to use for slaves. Default: 0.5.
  --mesos-master-config parameters passed to the mesos master.
  --mesos-slave-config parameters passed to the mesos slave.
  --no-hdfs to ignore hdfs installation step
  --no-shuffle-service to not start the external scheduler service.
  --number-of-slaves number of slave mesos containers to create (optional, defaults to 1).
  -q|--quiet no output is shown to the console regarding execution status.
  --slaves-cfg-file provide a slave configuration file to pass specific attributes per slave.
  --spark-binary-file the hadoop binary file to use in docker configuration (optional, if not present tries to download the binary).
  --update-image-mesos-at-version update the mesos on docker image with a specific version.
    (use version strings from here: http://mesos.apache.org/downloads/ eg. 0.27.0). If version installed is the same nothing will be updated.
    Can be set with env var: MIT_DOCKER_MESOS_VERSION=0.27.0. Command line argument takes precedence.
  --with-history-server starts history server on master container, it will use hdfs://hdfs_host:hdfs_port/spark_history folder for app event logging.
  --with-mararthon starts marathon node (requires zookeeper).
  --with-zk starts zookeeper on master container.
EOF
}

function parse_args {
  #parse args
  while :; do
    case "$1" in
      --cpu-host-percentage)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        CPU_HOST_PERCENTAGE=$2
        shift 2
        continue
      else
        exitWithMsg '"cpu-host-percentage" requires a non-empty option argument.\n'
      fi
      ;;
      --hadoop-binary-file)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        HADOOP_BINARY_PATH=$2
        shift 2
        continue
      else
        exitWithMsg '"hadoop-binary-file" requires a non-empty option argument.\n'
      fi
      ;;
      -h|--help)   # Call a "show_help" function to display a synopsis, then exit.
      show_help
      exit
      ;;
      -q|--quiet)   # Call a "show_help" function to display a synopsis, then exit.
      IS_QUIET=1
      shift 1
      continue
      ;;
      --image-version)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        IMAGE_VERSION=$2
        shift 2
        continue
      else
        exitWithMsg '"--image-version" requires a non-empty option argument.\n'
      fi
      ;;
      --mem-host-percentage)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        MEM_HOST_PERCENTAGE=$2
        shift 2
        continue
      else
        exitWithMsg '"mem-host-percentage" requires a non-empty option argument.\n'
      fi
      ;;
      --mesos-master-config)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        MESOS_MASTER_CONFIG=$2
        shift 2
        continue
      else
        exitWithMsg '"--mesos-master-config" requires a non-empty option argument.\n'
      fi
      ;;
      --mesos-slave-config)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        MESOS_SLAVE_CONFIG=$2
        shift 2
        continue
      else
        exitWithMsg '"--mesos-slave-config" requires a non-empty option argument.\n'
      fi
      ;;
      --no-hdfs)
      INSTALL_HDFS=
      shift 1
      continue
      ;;
      --no-shuffle-service)
      START_SHUFFLE_SERVICE=
      shift 1
      continue
      ;;
      --number-of-slaves)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        NUMBER_OF_SLAVES=$2
        shift 2
        continue
      else
        exitWithMsg '"--number-of-slaves" requires a non-empty option argument.\n'
      fi
      ;;
      --slaves-cfg-file)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        SLAVES_CONFIG_FILE=$2
        shift 2
        continue
      else
        exitWithMsg '"--slaves-cfg-file" requires a non-empty option argument.\n'
      fi
      ;;
      --spark-binary-file)       # Takes an option argument, ensuring it has been specified.
      if [ -n "$2" ]; then
        SPARK_BINARY_PATH=$2
        shift 2
        continue
      else
        exitWithMsg '"spark-binary-file" requires a non-empty option argument.\n'
      fi
      ;;
      --update-image-mesos-at-version)
      if [ -n "$2" ]; then
        MIT_IMAGE_MESOS_VERSION=$2
        shift 2
        continue
      else
        exitWithMsg '"--update-image-mesos-at-version" requires a non-empty option argument.\n'
      fi
      ;;
      --with-history-server)
      HISTORY_SERVER="TRUE"
      shift 1
      continue
      ;;
      --with-marathon)
      INSTALL_MARATHON="TRUE"
      shift 1
      continue
      ;;
      --with-zk)
      INSTALL_ZK="TRUE"
      shift 1
      continue
      ;;
      --)              # End of all options.
      shift
      break
      ;;
      -*)
      printf 'The option is not valid...: %s\n' "$1" >&2
      show_help
      exit 1
      ;;
      *)               # Default case: If no more options then break out of the loop.
      break
    esac
    shift
  done

  if [[ -n $HADOOP_BINARY_PATH && -z $INSTALL_HDFS ]]; then
    exitWithMsg "Don't specify no-hdfs flag, --hadoop-binary-path is only used when hdfs is used which is default"
  fi

  if [ -z $HADOOP_VERSION ] && [ -n "$HADOOP_BINARY_PATH" ]; then
    exitWithMsg "Export HADOOP_VERSION for custom binary."
  fi

  if [[ -z $INSTALL_ZK && -n $INSTALL_MARATHON ]]; then
    exitWithMsg "Marathon needs zookeeper. Use --with-zk flag to enable it."
  fi

  if [[ -n $SLAVES_CONFIG_FILE ]]; then
    if [[ -f $SLAVES_CONFIG_FILE ]]; then
      . cfg.sh
      #update the number of slaves to start here
      NUMBER_OF_SLAVES=$(get_number_of_slaves $SLAVES_CONFIG_FILE)
    else
      exitWithMsg "File $SLAVES_CONFIG_FILE does not exist..."
    fi
  fi

  # Get the filename only, remove full path.Variable substitution is used.
  # Removes the longest prefix that matches the regular expression */.
  # It returns the same value as basename.
  if [[ -n $SPARK_BINARY_PATH ]]; then
   SPARK_FILE=${SPARK_BINARY_PATH##*/}
  fi

  if [[ -n $HADOOP_BINARY_PATH ]]; then
    HADOOP_FILE=${HADOOP_BINARY_PATH##*/}
  fi

  if [ -z $HADOOP_BINARY_PATH ]; then
    if [ -z $HADOOP_VERSION ]; then
      HADOOP_VERSION=2.7.4
    fi
    HADOOP_FILE=hadoop-$HADOOP_VERSION.tar.gz
  fi

  if [ -z $MIRROR_SITE ]; then
    MIRROR_SITE=http://mirror.switch.ch
  fi
}

function exitWithMsg {
  printf 'ERROR: '"$1"'.\n' >&2
  show_help
  exit 1
}

function printMsg {
  if [[ ! -n "$IS_QUIET" ]]; then
    printf '%s\n' "$1"
  fi
}

################################## MAIN ####################################

function main {
  parse_args "$@"
  cat $SCRIPTPATH/message.txt
  printf "\n"
  type docker >/dev/null 2>&1 || { echo >&2 "docker binary is required but it's not installed.  Aborting."; exit 1; }

  printMsg "Setting folders..."
  mkdir -p $SCRIPTPATH/binaries

  printMsg "Stopping and removing master container(s)..."
  remove_container_by_name_prefix $MASTER_CONTAINER_NAME

  printMsg "Stopping and removing slave container(s)..."
  remove_container_by_name_prefix $SLAVE_CONTAINER_NAME

  printMsg "Getting binaries..."
  get_binaries

  printMsg "Starting master(s)..."
  start_master

  printMsg "Starting slave(s)..."
  start_slaves

  if [[ -n $HISTORY_SERVER ]]; then
    printMsg "Starting history server..."
    start_history_server
  fi

  printMsg "Mesos cluster started!"
  printMsg "Mesos cluster dashboard url http://$(docker_ip):5050"

  if [[ -n $INSTALL_HDFS ]]; then
    printMsg "Hdfs cluster started!"
    printMsg "Hdfs cluster dashboard url http://$(docker_ip):50070"
    printMsg "Hdfs url hdfs://$(docker_ip):8020"
  fi

  if [[ -n  $INSTALL_ZK ]]; then
    printMsg "Zookeeper url zk://$(docker_ip):2181"
  fi

  if [[ -n $INSTALL_MARATHON ]]; then
    printMsg "Marathon url http://$(docker_ip):8080"
  fi

  if [[ -n $HISTORY_SERVER ]]; then
    printMsg "History server url http://$(docker_ip):18080"
  fi
  generate_application_conf_file
  create_html
}

main "$@"
exit 0
