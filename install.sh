#!/bin/bash

FORCE_KERNEL="1.20210303-1"

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 1>&2
   exit 1
fi

# Check if enough space on /boot volume
boot_line=$(df -BM | grep /boot | head -n 1)
MIN_BOOT_SPC=25 # MegaBytes
if [ "x${boot_line}" = "x" ]; then
  echo "Warning: /boot volume not found .."
else
  boot_space=$(echo $boot_line | awk '{print $4;}')
  free_space=$(echo "${boot_space%?}")
  unit="${boot_space: -1}"
  if [[ "$unit" != "M" ]]; then
    echo "Warning: /boot volume not found .."
  elif [ "$free_space" -lt "$MIN_BOOT_SPC" ]; then
    echo "Error: Not enough space left ($boot_space) on /boot"
    echo "       at least $MIN_BOOT_SPC MB required"
    exit 1
  fi
fi

#
# make sure that we are on something ARM/Raspberry related
# either a bare metal Raspberry or a qemu session with 
# Raspberry stuff available
# - check for /boot/overlays
# - dtparam and dtoverlay is available
errorFound=0
OVERLAYS=/boot/overlays
[ -d /boot/firmware/overlays ] && OVERLAYS=/boot/firmware/overlays

if [ ! -d $OVERLAYS ] ; then
  echo "$OVERLAYS not found or not a directory" 1>&2
  errorFound=1
fi
# should we also check for alsactl and amixer used in seeed-voicecard?
PATH=$PATH:/opt/vc/bin
for cmd in dtparam dtoverlay ; do
  if ! which $cmd &>/dev/null ; then
    echo "$cmd not found" 1>&2
    echo "You may need to run ./ubuntu-prerequisite.sh"
    errorFound=1
  fi
done

if [ ! -x seeed-voicecard -o ! -f seeed-voicecard.service ]; then
  echo "Please run this script in the project directory"
  echo "which has files such as install.sh and seeed-voicecard.service"
  errorFound=1
fi

if [ $errorFound = 1 ] ; then
  echo "Errors found, exiting." 1>&2
  exit 1
fi

ver="0.3"
uname_r=$(uname -r)
arch_r=$(dpkg --print-architecture)

# we create a dir with this version to ensure that 'dkms remove' won't delete
# the sources during kernel updates
marker="0.0.0"

_VER_RUN=
function get_kernel_version() {
  local ZIMAGE IMG_OFFSET

  _VER_RUN=""
#  [ -z "$_VER_RUN" ] && {
#    ZIMAGE=/boot/kernel.img
#    [ -f /boot/firmware/vmlinuz ] && ZIMAGE=/boot/firmware/vmlinuz
#    IMG_OFFSET=$(LC_ALL=C grep -abo $'\x1f\x8b\x08\x00' $ZIMAGE | head -n 1 | cut -d ':' -f 1)
#    _VER_RUN=$(dd if=$ZIMAGE obs=64K ibs=4 skip=$(( IMG_OFFSET / 4)) 2>/dev/null | zcat | grep -a -m1 "Linux version" | strings | awk '{ print $3; }')
#  }
  _VER_RUN=$(uname -r)
  echo "$_VER_RUN"
  return 0
}

function check_kernel_headers() {
  VER_RUN=$(get_kernel_version)
  VER_HDR=$(dpkg -L raspberrypi-kernel-headers | egrep -m1 "/lib/modules/[^-]+/build" | awk -F'/' '{ print $4; }')
  [ "X$VER_RUN" == "X$VER_HDR" ] && {
    return 0
  }
  VER_HDR=$(dpkg -L linux-headers-$VER_RUN | egrep -m1 "/lib/modules/[[:print:]]+/build" | awk -F'/' '{ print $4; }')
  [ "X$VER_RUN" == "X$VER_HDR" ] && {
    return 0
  }

  # echo RUN=$VER_RUN HDR=$VER_HDR
  echo " !!! Your kernel version is $VER_RUN"
  echo "     Couldn't find *** corresponding *** kernel headers with apt-get."
  echo "     This may happen if you ran 'rpi-update'."
  echo " Choose  *** y *** to revert the kernel to version $VER_HDR and continue."
  echo " Choose  *** N *** to exit without this driver support, by default."
  read -p "Would you like to proceed? (y/N)" -n 1 -r -s
  echo
  if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    exit 1;
  fi

  apt-get -y --reinstall install raspberrypi-kernel
}

function download_install_debpkg() {
  local prefix name r pkg status _name
  prefix=$1
  name=$2
  pkg=${name%%_*}

  status=$(dpkg -l $pkg | tail -1)
  _name=$(  echo "$status" | awk '{ printf "%s_%s_%s", $2, $3, $4; }')
  status=$(echo "$status" | awk '{ printf "%s", $1; }')

  if [ "X$status" == "Xii" -a "X${name%.deb}" == "X$_name" ]; then
    echo "debian package $name already installed."
    return 0
  fi

  for (( i = 0; i < 3; i++ )); do
    wget $prefix$name -O /tmp/$name && break
  done
  dpkg -i /tmp/$name; r=$?
  rm -f /tmp/$name
  return $r
}

function usage() {
  cat <<-__EOF__
    usage: sudo ./install [ --compat-kernel | --keep-kernel ] [ -h | --help ]
             default action is update kernel & headers to latest version.
             --compat-kernel uses an older kernel but ensures that the driver can work.
             --keep-kernel   don't change/update the system kernel, maybe install
                             coressponding kernel headers.
             --help          show this help message
__EOF__
  exit 1
}

compat_kernel=
keep_kernel=
# parse commandline options
while [ ! -z "$1" ] ; do
  case $1 in
  -h|--help)
    usage
    ;;
  --compat-kernel)
    compat_kernel=Y
    ;;
  --keep-kernel)
    keep_kernel=Y
    ;;
  esac
  shift
done

if [ "X$keep_kernel" != "X" ]; then
  FORCE_KERNEL=$(dpkg -s raspberrypi-kernel | awk '/^Version:/{printf "%s\n",$2;}')
  echo -e "\n### Keep current system kernel not to change"
elif [ "X$compat_kernel" != "X" ]; then
  echo -e "\n### will compile with a compatible kernel..."
else
  FORCE_KERNEL=""
  echo -e "\n### will compile with the latest kernel..."
fi
[ "X$FORCE_KERNEL" != "X" ] && {
  echo -e "The kernel & headers use package version: $FORCE_KERNEL\r\n\r\n"
}

function install_kernel() {
  local _url _prefix

  # Instead of retrieving the lastest kernel & headers
  [ "X$FORCE_KERNEL" == "X" ] && {
    # Raspbian kernel packages
    apt-get -y --force-yes install raspberrypi-kernel-headers raspberrypi-kernel || {
      # Ubuntu kernel packages
      apt-get -y install linux-raspi linux-headers-raspi linux-image-raspi
    }
  } || {
    # We would like to a fixed version
    KERN_NAME=raspberrypi-kernel_${FORCE_KERNEL}_${arch_r}.deb
    HDR_NAME=raspberrypi-kernel-headers_${FORCE_KERNEL}_${arch_r}.deb
    _url=$(apt-get download --print-uris raspberrypi-kernel | sed -nre "s/'([^']+)'.*$/\1/g;p")
    _prefix=$(echo $_url | sed -nre 's/^(.*)raspberrypi-kernel_.*$/\1/g;p')

    download_install_debpkg "$_prefix" "$KERN_NAME" && {
      download_install_debpkg "$_prefix" "$HDR_NAME"
    } || {
      echo "Error: Install kernel or header failed"
      exit 2
    }
  }
}

function uninstall_module {
  src=$1
  mod=$2

  if [[ -d /var/lib/dkms/$mod/$ver/$marker ]]; then
    rmdir /var/lib/dkms/$mod/$ver/$marker
  fi

  if [[ -e /usr/src/$mod-$ver || -e /var/lib/dkms/$mod/$ver ]]; then
    dkms remove --force -m $mod -v $ver --all
    rm -rf /usr/src/$mod-$ver
  fi

  return 0
}

# update and install required packages
which apt &>/dev/null; r=$?
if [[ $r -eq 0 ]]; then
  echo -e "\n### Install required tool packages"
  apt update -y
  apt-get -y install dkms git i2c-tools libasound2-plugins
fi

echo -e "\n### Uninstall previous dkms module"
uninstall_module "./" "seeed-voicecard"

if [[ $r -eq 0 ]]; then
  echo -e "\n### Install required kernel package"
  install_kernel
  # rpi-update checker
  check_kernel_headers
fi

# Arch Linux
which pacman &>/dev/null
if [[ $? -eq 0 ]]; then
  pacman -Syu --needed git gcc automake make dkms linux-raspberrypi-headers i2c-tools
fi

# locate currently installed kernels (may be different to running kernel if
# it's just been updated)
base_ver=$(get_kernel_version)
base_ver=${base_ver%%[-+]*}
# kernels="${base_ver}+ ${base_ver}-v7+ ${base_ver}-v7l+"
# select exact kernel postfix
kernels=${base_ver}$(echo $uname_r | sed -re 's/^[0-9.]+(.*)/\1/g')

function install_module {
  local _i

  src=$1
  mod=$2

  mkdir -p /usr/src/$mod-$ver
  cp -a $src/* /usr/src/$mod-$ver/

  dkms add -m $mod -v $ver
  for _i in $kernels; do
    dkms build -k $_i -m $mod -v $ver && {
      dkms install --force -k $_i -m $mod -v $ver
    } || {
      echo "Can't compile with this kernel, aborting"
      echo "Please try to compile with the option --compat-kernel"
      exit 1
    }
  done

  mkdir -p /var/lib/dkms/$mod/$ver/$marker
}

echo -e "\n### Install sound card driver"
install_module "./" "seeed-voicecard"

# install dtbos
echo -e "\n### Install device tree overlays"
cp -v seeed-2mic-voicecard.dtbo $OVERLAYS
cp -v seeed-4mic-voicecard.dtbo $OVERLAYS
cp -v seeed-8mic-voicecard.dtbo $OVERLAYS

# install alsa plugins
# we don't need this plugin now
# install -D ac108_plugin/libasound_module_pcm_ac108.so /usr/lib/arm-linux-gnueabihf/alsa-lib/
rm -f /usr/lib/arm-linux-gnueabihf/alsa-lib/libasound_module_pcm_ac108.so

#set kernel modules
echo -e "\n### Codec driver loading at startup (in /etc/modules)"
grep -q "^snd-soc-seeed-voicecard$" /etc/modules || \
  echo "snd-soc-seeed-voicecard" >> /etc/modules
grep -q "^snd-soc-ac108$" /etc/modules || \
  echo "snd-soc-ac108" >> /etc/modules
grep -q "^snd-soc-wm8960$" /etc/modules || \
  echo "snd-soc-wm8960" >> /etc/modules  

#set dtoverlays
CONFIG=/boot/config.txt
[ -f /boot/firmware/usercfg.txt ] && CONFIG=/boot/firmware/usercfg.txt
echo -e "\n### Found boot configuration file $CONFIG"

sed -i -e 's:#dtparam=i2c_arm=on:dtparam=i2c_arm=on:g'  $CONFIG || true
grep -q "^dtoverlay=i2s-mmap$" $CONFIG || \
  echo "dtoverlay=i2s-mmap" >> $CONFIG


grep -q "^dtparam=i2s=on$" $CONFIG || \
  echo "dtparam=i2s=on" >> $CONFIG

#install config files
echo -e "\n### Install alsa and widget configuration"
mkdir /etc/voicecard || true
cp -v *.conf /etc/voicecard
cp -v *.state /etc/voicecard

#create git repo
echo -e "\n### Manage alsa configuration by git"
git_email=$(git config --global --get user.email)
git_name=$(git config --global --get user.name)
if [ "x${git_email}" == "x" ] || [ "x${git_name}" == "x" ] ; then
    echo "setup git config"
    git config --global user.email "respeaker@seeed.cc"
    git config --global user.name "respeaker"
fi
echo "git init"
git --git-dir=/etc/voicecard/.git init
echo "git add --all"
git --git-dir=/etc/voicecard/.git --work-tree=/etc/voicecard/ add --all
echo "git commit -m \"origin configures\""
git --git-dir=/etc/voicecard/.git --work-tree=/etc/voicecard/ commit  -m "origin configures"

echo -e "\n### Start service seeed-voicecard"
echo -e "    see /var/log/seeed-voicecard.log for more service information"
cp seeed-voicecard /usr/bin/
cp seeed-voicecard.service /lib/systemd/system/
systemctl enable  seeed-voicecard.service 
systemctl start   seeed-voicecard

echo "------------------------------------------------------"
echo "Please reboot your device to apply all settings"
echo "Enjoy!"
echo "------------------------------------------------------"
