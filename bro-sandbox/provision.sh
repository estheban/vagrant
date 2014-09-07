#!/bin/bash
# Author: Jon Schipp <jonschipp@gmail.com>
# Written for Ubuntu Saucy and Trusty, should be adaptable to other distros.

# Global Variables
VAGRANT=/home/vagrant
if [ -d $VAGRANT ]; then
	HOME=/home/vagrant
else
	HOME=/root
fi
COWSAY=/usr/games/cowsay
IRCSAY=/usr/local/bin/ircsay
IRC_CHAN="#replace_me"
HOST=$(hostname -s)
LOGFILE=/root/bro-sandbox_install.log
DST=/usr/local/bin
EMAIL=jonschipp@gmail.com
CONTAINER_DESTINATION= # Put containers on another volume (optional)
IMAGE="jonschipp/latest-bro-sandbox" # Assign a different name to the image (optional). Must make same in sandbox scripts

# Get Ubuntu distribution information
source /etc/lsb-release

# Logging
exec > >(tee -a "$LOGFILE") 2>&1
echo -e "\n --> Logging stdout & stderr to $LOGFILE"

# Must run as root
if [ $UID -ne 0 ]; then
	echo "Script must be run as root user, exiting..."a
	exit 1
fi

cd $HOME

function die {
    if [ -f ${COWSAY:-none} ]; then
        $COWSAY -d "$*"
    else
        echo "$*"
    fi
    if [ -f $IRCSAY ]; then
        ( set +e; $IRCSAY "$IRC_CHAN" "$*" 2>/dev/null || true )
    fi
    echo "$*" | mail -s "[vagrant] Bro Sandbox install information on $HOST" $EMAIL
    exit 1
}

function hi {
    if [ -f ${COWSAY:-none} ]; then
        $COWSAY "$*"
    else
        echo "$*"
    fi
    if [ -f $IRCSAY ]; then
        ( set +e; $IRCSAY "$IRC_CHAN" "$*" 2>/dev/null || true )
    fi
    echo "$*" | mail -s "[vagrant] Bro Sandbox install information on $HOST" $EMAIL
}

function logo {
cat <<"EOF"
===========================================

		Bro
	    -----------
	  /             \
	 |  (   (0)   )  |
	 |            // |
	  \     <====// /
	    -----------

	Web: http://bro.org

===========================================

EOF
}

no_vagrant_setup() {
local COUNT=0
local SUCCESS=0
local FILES="
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/Dockerfile
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/etc.default.docker
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/sandbox.cron
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/remove_old_containers
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/remove_old_users
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/disk_limit
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/sandbox_login
https://raw.githubusercontent.com/jonschipp/vagrant/master/bro-sandbox/scripts/sandbox_shell
"

echo -e "Downloading required configuration files!\n"

for url in $FILES
do
	COUNT=$((COUNT+1))
	wget $url 2>/dev/null
	if [ $? -ne 0 ]; then
		echo "$COUNT - Download for $url failed!"
	else
		echo "$COUNT - Success! for $url"
		SUCCESS=$((SUCCESS+1))
	fi
done
echo
}

function install_docker() {
local ORDER=$1
echo -e "$ORDER Installing Docker!\n"

# Check that HTTPS transport is available to APT
if [ ! -e /usr/lib/apt/methods/https ]; then
	apt-get update
	apt-get install -y apt-transport-https
	echo
fi

# Add the repository to your APT sources
# Then import the repository key
if [ ! -e /etc/apt/sources.list.d/docker.list ]
then
	echo deb https://get.docker.io/ubuntu docker main > /etc/apt/sources.list.d/docker.list
	apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 36A1D7869245C8950F966E92D8576A8BA88D21E9
	echo
fi

# Install docker
if ! command -v docker >/dev/null 2>&1
then
	apt-get update
	apt-get install -y lxc-docker
	echo
fi
}

function user_configuration() {
local ORDER=$1
local SSH_CONFIG=/etc/ssh/sshd_config 
local RESTART_SSH=0
echo -e "$ORDER Configuring the demo user account!\n"

if [ ! -e /etc/sudoers.d/sandbox ]; then
cat > /etc/sudoers.d/sandbox <<EOF
Cmnd_Alias SANDBOX = /usr/bin/docker
demo ALL=(root) NOPASSWD: SANDBOX
EOF
chmod 0440 /etc/sudoers.d/sandbox && chown root:root /etc/sudoers.d/sandbox
fi

if ! grep -q sandbox /etc/shells
then
	sh -c 'echo /usr/local/bin/sandbox_shell >> /etc/shells'
fi

if ! getent passwd demo 1>/dev/null
then
	adduser --disabled-login --gecos "" --shell $DST/sandbox_shell demo
	sed -i '/demo/s/:!:/:$6$CivABH1p$GU\/U7opFS0T31c.6xBRH98rc6c6yg9jiC5adKjWo1XJHT3r.25ySF5E5ajwgwZlSk6OouLfIAjwIbtluf40ft\/:/' /etc/shadow
fi

if ! grep -q "ClientAliveInterval 15" $SSH_CONFIG
then
	echo -e "\nClientAliveInterval 15\nClientAliveCountMax 10\n" >> $SSH_CONFIG
	RESTART_SSH=1
fi

if grep -q "PasswordAuthentication no" $SSH_CONFIG
then
	if ! grep -q "Match User demo" $SSH_CONFIG
	then
		echo -e "\nMatch User demo\n\tPasswordAuthentication yes\n" >> $SSH_CONFIG
		RESTART_SSH=1
	fi
fi

if ! grep -q '^#Subsystem sftp' $SSH_CONFIG
then
	sed -i '/^Subsystem sftp/s/^/#/' $SSH_CONFIG
	RESTART_SSH=1
fi

if [ $RESTART_SSH -eq 1 ]
then
	restart ssh
	echo
fi
}

function system_configuration() {
local ORDER=$1
local LIMITS=/etc/security/limits.d
echo -e "$ORDER Configuring the system for use!\n"

if [ -e $HOME/sandbox_shell ]; then
	install -o root -g root -m 755 $HOME/sandbox_shell $DST/sandbox_shell
fi

if [ -e $HOME/sandbox_login ]; then
	install -o root -g root -m 755 $HOME/sandbox_login $DST/sandbox_login
fi

if [ -e $HOME/sandbox.cron ]; then
	install -o root -g root -m 644 $HOME/sandbox.cron /etc/cron.d/sandbox
fi

if [ ! -e $LIMITS/fsize.conf ]; then
	echo "*                hard    fsize           1000000" > $LIMITS/fsize.conf
fi

if [ ! -e $LIMITS/nproc.conf ]; then
	echo "*                hard    nproc           10000" > $LIMITS/nproc.conf
fi
}

function container_scripts(){
local ORDER=$1
echo -e "$ORDER Installing container maintainence scripts!\n"

for FILE in disk_limit remove_old_containers remove_old_users
do
	if [ -e $HOME/$FILE ]; then
		install -o root -g root -m 750 $HOME/$FILE $DST/sandbox_${FILE}
	fi
done
}

function docker_configuration() {
local ORDER=$1
local DEFAULT=/etc/default/docker
local UPSTART=/etc/init/docker.conf

echo -e "$ORDER Installing the Bro Sandbox Docker image!\n"


if ! grep -q "limit fsize" $UPSTART
then
	sed -i '/limit nproc/a limit fsize 500000000 500000000' $UPSTART
fi

if ! grep -q "limit nproc 524288 524288" $UPSTART
then
	sed -i '/limit nproc/s/[0-9]\{1,8\}/524288/g' $UPSTART
fi

if [[ "$DISTRIB_CODENAME" == "saucy" || "$DISTRIB_CODENAME" == "trusty" ]]
then
	# Devicemapper allows us to limit container sizes for security
	# https://github.com/docker/docker/tree/master/daemon/graphdriver/devmapper
	if ! grep -q devicemapper $DEFAULT
	then
		echo -e " --> Using devicemapper as storage backend\n"
		install -o root -g root -m 644 $HOME/etc.default.docker $DEFAULT

		if [ -d /var/lib/docker ]; then
			rm -rf /var/lib/docker/
		fi

		if [ ! -z $CONTAINER_DESTINATION ]; then

			if ! mount | grep -q $CONTAINER_DESTINATION ; then
				mount $CONTAINER_DESTINATION /var/lib/docker
			fi

			if ! grep -q $CONTAINER_DESTINATION /etc/fstab 2>/dev/null; then
				echo -e "${CONTAINER_DESTINATION}\t/var/lib/docker\text4\tdefaults,noatime,nodiratime\t0\t1" >> /etc/fstab
			fi
                fi

		mkdir -p /var/lib/docker/devicemapper/devicemapper
		restart docker
		sleep 5
	fi
fi

if ! docker images | grep -q $IMAGE
then
	if [ -e $HOME/Dockerfile ]; then
		docker build -t $IMAGE - < $HOME/Dockerfile
	else
		docker pull jonschipp/latest-bro-sandbox
	fi
	#docker commit $(docker ps -a -q | head -n 1) jonschipp/latest-bro-sandbox
fi
}

training_configuration() {
local COUNT=0
local SUCCESS=0
local FILES="
http://www.bro.org/downloads/archive/bro-2.2.tar.gz
http://www.bro.org/downloads/archive/bro-2.1.tar.gz
http://www.bro.org/downloads/archive/bro-2.0.tar.gz
http://www.bro.org/downloads/archive/bro-1.5.tar.gz
http://www.bro.org/downloads/archive/bro-1.4.tar.gz
http://www.bro.org/downloads/archive/bro-1.3.tar.gz
http://www.bro.org/downloads/archive/bro-1.2.tar.gz
http://www.bro.org/downloads/archive/bro-1.1.tar.gz
http://www.bro.org/downloads/archive/bro-1.0.tar.gz
http://www.bro.org/downloads/archive/bro-0.9-stable.tar.gz
"
echo -e "Applying training configuration!\n"

if [ ! -d /exercises ]
then
	mkdir /exercises
fi

if [ ! -d /versions ]
then
	mkdir /versions
	cd /versions

	for url in $FILES
	do
		COUNT=$((COUNT+1))
		wget $url 2>/dev/null
		if [ $? -ne 0 ]; then
			echo "$COUNT - Download for $url failed!"
		else
			echo "$COUNT - Success! for $url"
			SUCCESS=$((SUCCESS+1))
		fi
done

cat > /versions/README <<EOF
* Still in development: compilation fails *

This is mostly for fun, to see how Bro has changed over time.

/versions is mounted read-only.
You must copy a release tarball to your home directory and compile it there to play with it. e.g.

$ cp /versions/bro-2.0.tar.gz ~/
$ cd bro-2.0
$ ./configure
$ make
$ ./build/src/bro

EOF
fi
}

sample_exercises() {
local DIR=/exercises
echo -e "Installing sample exercises!\n"
if [ ! -d $DIR ]
	mkdir /exercises
fi

cd $DIR

if [ ! -d $DIR/BroCon14 ]
then
	wget http://www.bro.org/static/BroCon14/BroCon14.tar.gz 2>/dev/null
	if [ $? -ne 0 ]; then
		echo "$COUNT - Download for $url failed!"
	else
		echo "$COUNT - Success! for $url"
	fi
	tar zxf BroCon14.tar.gz
	rm -f BroCon14.tar.gz
fi
}

logo

# Run if not using Vagrant (We have to get the files another way)
if [ ! -d $VAGRANT ]; then
	no_vagrant_setup
fi

install_docker "1.)"
user_configuration "2.)"
system_configuration "3.)"
container_scripts "4.)"
docker_configuration "5.)"
#training_configuration "6.)"
sample_exercises "7.)"

echo
if [ -d $VAGRANT ]; then
        echo "Try it out: ssh -p 2222 demo@127.0.0.1 -o UserKnownHostsFile=/dev/null"
else
        echo "Try it out: ssh demo@<ip> -o UserKnownHostsFile=/dev/null"
fi
