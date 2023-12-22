#! /bin/bash

# verify that script was called as root
if [ -z $SUDO_USER ]; then
    echo "Please run me as root!"
    exit 1
fi

# script usage
usage() {
        echo
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -i IMG_PATH     Mandatory. Path to disk image file."
        echo "  -d DISK_PATH    Mandatory. Device path to target disk."
        echo "  -p PART_NUM     Optional. Partition number, when omitted, the value 1 is used."
        echo "  -n NAME         Mandatory. New host name."
        echo
        exit 0
}

# default value
part_num=1

# parse command line
while getopts ":hi:d:p:n:" opt; do
  case ${opt} in
    h ) usage;;
    i ) img_path=$OPTARG
        if [ ! -f $img_path ]; then
            echo -e "\nArgument of -i must be a path to an existing disk image file!\n"
            exit 1
        fi
        ;;
    d ) disk_path=$OPTARG
        if [ ! -b $disk_path ]; then
            echo -e "\nArgument of -d must be a device path to an existing disk!\n"
            exit 1
        fi
        ;;
    p ) part_num=$OPTARG;;
    n ) new_name=$OPTARG;;
    \?) echo "Invalid option: -$OPTARG" 1>&2; exit 1;;
    : ) echo "Option: -$OPTARG requires an argument" 1>&2; exit 1;;
    * ) echo "Unexpected option -$OPTARG" 1>&2; exit 1;;
  esac
done

# verify that all mandatory parameters with their arguments were specified
if [[ $OPTIND == 1 || -z $img_path || -z $disk_path || -z $new_name ]]; then
    usage
fi

# integrity check of disk image file
if [ -f "$img_path.sha512" ]; then
    echo -e "\nPerforming integrity check of [$img_path]..."
    sha512sum -c "$img_path.sha512"
    if [ $? -ne 0 ]; then
        echo -e "\nIntegrity check failed on [$img_path]!"
        exit 1
    fi
fi

# dump image file content to target disk
echo -e  "\nWriting content of [$img_path] to [$disk_path]..."
dd if="$img_path" of="$disk_path" bs=4M status=progress

# resizing partition without moving it
echo -e "\nResizing partition without moving it..."
echo ", +" | sfdisk -N $part_num $disk_path

echo -e "\nVerifiying partiton [$disk_path$part_num] after resize..."
e2fsck -f "$disk_path$part_num"

# resizing file system
echo -e "\nResizing file system on [$disk_path$part_num]..."
resize2fs "$disk_path$part_num"

# mounting file system
mp='/mnt/tmp1'
echo -e "\nMounting file system on [$disk_path$part_num]..."
mkdir -p $mp
mount -t auto "$disk_path$part_num" $mp

# resizing swapfile to double size of RAM
mem=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem2=$((2 * $mem))
echo -e "\nResizing swap file to $mem2 kB..."
rm -f "$mp/swapfile"
fallocate -l "${mem2}K" "$mp/swapfile"
chmod 600 "$mp/swapfile"
mkswap "$mp/swapfile"

res1=$(grep swap "$mp/etc/fstab")
if [ -z $res1 ]; then
    echo "/swapfile none swap sw 0 0" >> "$mp/etc/fstab"
fi

# renaming the host
oldname=$(cat "$mp/etc/hostname")
echo -e "\nRenaming the host from [$oldname] to [$new_name]..."
echo "$new_name" > "$mp/etc/hostname"
sed -i "s/$oldname/$new_name/" "$mp/etc/hosts"

# asking for new GRUB password
echo -e "\nAsking for password and setting up GRUB..."
pwd1=$(grub-mkpasswd-pbkdf2 | tee /dev/stderr | grep -o "grub.*")
if [ $? -ne 0 ]; then
    echo "Entered passwords did not match!"
    exit 1
fi
echo

# setting up GRUB
local_user='localadmin'
touch "$mp/etc/grub.d/42_moldex"
cat <<EOF >> "$mp/etc/grub.d/42_moldex"
#!/bin/sh
exec tail -n +3 \$0

set superusers="$local_user"
password_pbkdf2 $local_user $pwd1
EOF

mount --bind /dev "$mp/dev"
mount --bind /sys "$mp/sys"
mount proc -t proc "$mp/proc"

chroot $mp chmod 755 /etc/grub.d/42_moldex
chroot $mp update-grub

user_exists=$(chroot $mp getent passwd $local_user)
if [ -z $user_exists ]; then
    echo -e "\nUser [$local_user] does not exist, going to create it..."
    chroot $mp adduser --gecos "" --disabled-password $local_user

    grp=('adm' 'cdrom' 'sudo' 'dip' 'plugdev' 'lpadmin' 'sambashare')
    for item in ${grp[@]}; do
        found=$(grep $item "$mp/etc/group")
        if [ ! -z "$found" ]; then
            echo "Adding $local_user to the $item group..."
            chroot $mp usermod -a -G $item $local_user
        fi
    done
fi
chroot $mp passwd $local_user

umount "$mp/dev"
umount "$mp/sys"
umount "$mp/proc"

# dismounting file system
umount $mp

read -s -N 1 -p "Press any key to shut down or Ctrl+C to stop this script"
echo
poweroff
