#!/bin/bash

. /etc/default/xbian-initramfs

test -e /run/trigger-xbian-update-initramfs && MODVER=$(cat /run/trigger-xbian-update-initramfs)

if [ -z "$MODVER" ]; then
	test -z "$1" && MODVER=$(uname -r)
	test -z "$MODVER" && MODVER="$1"
fi

echo "Updating initramfs as requested by trigger. Kernel modules $MODVER."
mod_done=''
lib_done=''

copy_modules() {

        list="$1"
        for f in $list; do
                f=$(basename $f)
                f="${f%'.ko'}.ko"
                case $mod_done in
                        *"/$f "*)
                                continue
                                ;;
                        *)
                                ;;
                esac
                modname=$(find /lib/modules/$MODVER -iname $f -printf '%P') 
                [ -z "$modname" ] && continue
                echo "copying module /lib/modules/$MODVER/$modname"
                cp -a --parents "/lib/modules/$MODVER/$modname" ./
                mod_done="$mod_done $modname "
                depends=$(grep "$modname:" "/lib/modules/$MODVER/modules.dep" | awk -F': ' '{print $2}')
                [ -z "$depends" ] && continue
                copy_modules "$depends"
        done

}

copy_file() {
        cp -d --parents $3 "$1" "$2"
        test -h "$1" || return
        g=$(basename "$1")
        d=${1%$g}
        fl=$(ls -la "$1" | awk '{print $11}')
        tmp1=${fl##/*}

        lib_done="$lib_done $fl"
        case $lib_done in
                *" $fl "*)
                        return 
                        ;;
                *)
                        ;;
        esac

        if [ -n "$tmp1" ]; then
                test -h ".$2/$fl" && rm -f ".$2/$fl"
                cp -d --parents $3 "$d$fl" "$2"
        else
                test -h ".$fl" && rm -f ".$fl"
                cp -d --parents $3 "$fl" "./"
        fi
        echo "$fl"
}

copy_with_libs() {

        dst="$2"
        test -z "$dst" && dst="./"

        if [ -d "$1" ]; then
                cp -a --parents "$1"/* "$dst"
        fi

        if [ -f "$1" ]; then 
                copy_file "$1" "$dst"
                oldIFS=$IFS
                IFS=$'\n'
                for fff in $(ldd $1 | cat ); do
                        echo "$fff" | grep "not a dynamic exec"
                        rc="$?"
                        test $rc -eq 0 && continue

                        f1=$(echo "$fff" | awk '{print $1}')
                        f2=$(echo "$fff" | awk '{print $3}')
                        f3=$(echo "$fff" | awk '{print $4}')
                        if [ "$f3" = "" ]; then
                                f=$f1
                        else
                                f=$f2
                        fi
                        copy_file "$f" "$dst" "-n"
                        [ -e "$f1" ] && copy_file "$f1" "$dst" "-n"
                done
                IFS=$oldIFS
        fi
}

TMPDIR=$(mktemp -d)
cd $TMPDIR
trap "{ cd ..; rm -fr '${TMPDIR}'; exit 0; }" INT TERM EXIT

mkdir bin dev etc lib proc rootfs run sbin sys tmp usr mnt var
ln -s /run ./var/run
mkdir usr/bin
mkdir etc/udhcpc etc/network etc/wpa_supplicant
mkdir etc/network/if-down.d etc/network/if-up.d etc/network/if-post-down.d etc/network/if-pre-up.d
mkdir lib/modules
mkdir -p usr/bin
mkdir -p usr/lib/arm-linux-gnueabihf
copy_with_libs /bin/busybox 
/bin/busybox --install -s bin/
cp -d bin/modprobe sbin
cp -d bin/insmod sbin
cp -d bin/rmmod sbin
cp -d --remove-destination /etc/udhcpc/default.script etc/udhcpc/
cp -d --remove-destination -R /etc/network etc/
cp -d --remove-destination -R /etc/hostname etc/
cp -d --remove-destination -R /etc/wpa_supplicant etc/
cp -d --remove-destination /etc/udev etc/
mkdir etc/udev/.dev
cp -d --remove-destination -R /etc/fstab etc/
sed -i 's/\/etc\/resolv.conf/\/rootfs\/etc\/resolv.conf/g' etc/udhcpc/default.script
touch etc/mdev.conf
cp -d --remove-destination /etc/modules etc/
cp -d --remove-destination -av --parents /etc/default ./
copy_with_libs /lib/init
copy_with_libs /lib/lsb
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/md ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/arch ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/block ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/ata ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/mmc ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/scsi ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/memstick ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/usb/storage ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/usb/class ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/hid ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/usb/misc ./
#cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/net/usb ./
#cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/net/wireless ./
#cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/net/mac80211 ./
#cp -d --remove-destination -av --parents /lib/firmware ./
cp --remove-destination -av --parents /lib/modules/$MODVER/modules.builtin ./
cp --remove-destination -av --parents /lib/modules/$MODVER/modules.order ./

cat /etc/modules | grep -i evdev || printf "\nevdev" >> ./etc/modules

copy_modules "$(cat /etc/modules | grep -v ^# )" 
copy_modules "btrfs nfs ext4 vfat hfs ntfs fuse reiserfs"
depmod -b ./ $MODVER

cp -d --remove-destination -a --parents /lib/klibc* ./

copy_with_libs /usr/bin/whiptail ./
copy_with_libs /sbin/kexec ./
copy_with_libs /sbin/udevd ./
copy_with_libs /sbin/udevadm ./
copy_with_libs /sbin/fdisk
copy_with_libs /sbin/findfs
copy_with_libs /sbin/blkid 
copy_with_libs /sbin/MAKEDEV 
copy_with_libs /sbin/sfdisk
copy_with_libs /sbin/tune2fs
copy_with_libs /sbin/e2fsck 
copy_with_libs /sbin/resize2fs 
copy_with_libs /sbin/modprobe
copy_with_libs /sbin/btrfs 
copy_with_libs /sbin/btrfs-convert 
#copy_with_libs /sbin/iwconfig 
#copy_with_libs /sbin/wpa_supplicant 
copy_with_libs /sbin/partprobe
copy_with_libs /sbin/dmsetup 
copy_with_libs /usr/bin/pkill
copy_with_libs /usr/bin/pgrep
cp --remove-destination /usr/lib/klibc/bin/ipconfig ./bin
cp --remove-destination /usr/lib/klibc/bin/run-init ./sbin

copy_with_libs /usr/bin/splash
mkdir -p ./usr/share/fonts/splash
mkdir -p ./usr/share/images/splash
cp -d --remove-destination -aR --parents /usr/share/fonts/splash ./
cp -d --remove-destination -aR --parents /usr/share/images/splash ./
cp -d --remove-destination --parents /usr/bin/splash.images ./
cp -d --remove-destination --parents /usr/bin/splash.fonts ./

copy_with_libs /usr/bin/key

cp -d --remove-destination -v --parents /lib/udev/* ./
cp -d --remove-destination -v --parents /lib/udev/keymaps/* ./
for f in "$(grep -rilve 'owner|run=+' /lib/udev/rules.d)"; do cp --parents -av --remove-destination $f ./; done

cp /etc/xbian-initramfs/init ./
cp /etc/xbian-initramfs/bootmenu ./
cp /etc/xbian-initramfs/bootmenu_timeout ./
cp /etc/xbian-initramfs/cnvres-code.sh ./
cp /etc/xbian-initramfs/splash_updater.sh ./
copy_with_libs /usr/bin/stdbuf
copy_with_libs /usr/lib/coreutils/libstdbuf.so

cp /etc/hostname ./etc
need_umount=''
if ! mountpoint -q /boot; then
        mount /boot
        need_umount="yes"
fi
test "$MAKEBACKUP" = "yes" && mv /boot/initramfs.gz /boot/initramfs.gz.old
find . | cpio -H newc -o | lzma -1v > /boot/initramfs.gz
if [ ! -e /boot/boot.cfg ]; then
        touch /boot/boot.cfg
        echo "name=Standard\ Xbian\ boot" >> /boot/boot.cfg
        echo "kernel=/kernel.img" >> /boot/boot.cfg
        echo "initrd=/initramfs.gz" >> /boot/boot.cfg
fi
[ "$need_umount" = "yes" ] && umount /boot

exit 0

