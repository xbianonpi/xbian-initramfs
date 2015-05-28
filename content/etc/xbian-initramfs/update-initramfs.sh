#!/bin/bash

exec 2>/dev/null

if [ ! -e /usr/local/bin/busybox ]; then
    [ ! -e /bin/busybox ] && exit 99
    cp /bin/busybox /usr/local/bin/busybox
fi
if [ ! -e /etc/xbian_version ]; then
    sed -i 's/ --startup-event mountall//g' /boot/boot.scr.txt
fi

. /etc/default/xbian-initramfs

test -e /run/trigger-xbian-update-initramfs && MODVER=$(cat /run/trigger-xbian-update-initramfs)
grep -q initramfs.gz /var/lib/dpkg/info/xbian-update.list && sed -i "/\(\/boot\/initramfs.gz\)/d" /var/lib/dpkg/info/xbian-update.list


if [ -z "$MODVER" ]; then
	test -z "$1" && MODVER=$(uname -r)
	test -z "$MODVER" && MODVER="$1"
fi

depmod -a $MODVER

echo "Updating initramfs as requested by trigger. Kernel modules $MODVER."
mod_done=''
lib_done=''

copy_modules() {

        tlist="$1"
        for f in $tlist; do
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

put_to_modules(){
    for m in $1; do
        echo "$(cat ./etc/modules 2>/dev/null)" | grep -qx $m  || echo $m >> ./etc/modules
        copy_modules $m
    done
}

copy_file() {
        cp -d --remove-destination -v --parents $3 "$1" "$2"
        test -h "$1" || return
        dr=$(dirname "$1")
        fl=$(readlink "$1")
        test -e "$fl" || fl="$dr/$fl"
        case $lib_done in
                *" $fl "*)
                        echo "again $fl"
                        return 
                        ;;
                *)
                        cp -d -v --remove-destination --parents $3 "$fl" "$2" 
                        lib_done="$lib_done $fl"
                        ;;
        esac
}

copy_with_libs() {

        dst="$2"
        test -z "$dst" && dst="./"

        [ -h "$dst" ] && rm "$dst"

        if [ -d "$1" ]; then
                cp -a --parents "$1"/* "$dst"
                return 0
        fi


        if [ -f "$1" ]; then 
                copy_file "$1" "$dst"
                [ -x $1 ] || return 0
                oldIFS=$IFS
                IFS=$'\n'
                for fff in $(ldd $1 2>&1| cat ); do
                        echo "$fff" | grep -q "not a dynamic exec" && continue

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
trap "{ cd ..; { rm -fr '${TMPDIR}' & }; exit 0; }" INT TERM EXIT

mkdir bin dev etc lib proc rootfs run sbin sys tmp usr mnt var
cat << \EOF > ./.profile
export PS1='\w # '
alias rum='umount -a'
alias reb='umount -a; sync; reboot -nf'
alias rch='chroot /rootfs /bin/bash'
EOF
cp .profile .bashrc
ln -s /run ./var/run
mkdir usr/bin
mkdir etc/udhcpc etc/network etc/wpa_supplicant
mkdir etc/network/if-down.d etc/network/if-up.d etc/network/if-post-down.d etc/network/if-pre-up.d
mkdir lib/modules
mkdir -p usr/bin
mkdir -p usr/lib/arm-linux-gnueabihf

copy_with_libs /usr/local/bin/busybox
/usr/local/bin/busybox --install -s $(readlink -f ./bin)
( cd ./bin; ln -s /usr/local/bin/busybox ./; )

cp -d --remove-destination --parents /etc/udev/* ./
cp -d --remove-destination --parents /etc/default/{tmpfs,rcS,xbian-rnd} ./

mkdir -p etc/udev/.dev
cp -d --remove-destination --parents /etc/modprobe.d/*.conf ./
cp -d --remove-destination /etc/xbian-initramfs/blacklist.conf ./etc/modprobe.d
#cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/hid ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/scsi ./
cp -d --remove-destination -av --parents /lib/modules/$MODVER/kernel/drivers/usb/storage ./
cp --remove-destination -av --parents /lib/modules/$MODVER/modules.builtin ./
cp --remove-destination -av --parents /lib/modules/$MODVER/modules.order ./
cp /etc/xbian_version ./etc/

cat /etc/modules | grep -v ^# | grep -v lirc_ >> ./etc/modules
copy_modules "ext4 usb_storage vchiq spl zfs"
put_to_modules "nfs sunrpc rpcsec_gss_krb5 lz4 cfq-iosched f2fs spl zavl znvpair zcommon zunicode zfs"
copy_modules "$(cat ./etc/modules)"
echo "$(cat /etc/fstab) $(cat /etc/fstab.d/*)" | awk '{print $3}' | uniq | grep -v ^$ | grep 'nfs\|nfs4\|cifs' \
    | while read fstype; do
        case $fstype in
            nfs|nfs4)
                list="nfsv4 nfsv3 nfs sunrpc rpcsec_gss_krb5"
                copy_modules "$list"
                put_to_modules "$list"
                ;;
            cifs)
                list=cifs
                copy_modules "$list"
                put_to_modules "$list"
                ;;
        esac
    done

## lvm
if [ "$LVM" = "yes" ] && [ -e /sbin/lvm ]; then
   if [ -e /etc/lvm/lvm.conf ]; then
	mkdir -p ./etc/lvm
	cp /etc/lvm/lvm.conf ./etc/lvm/
   fi

   mkdir -p ./lib/udev/rules.d/
   for rules in 56-lvm.rules 60-persistent-storage-lvm.rules; do
        if   [ -e /etc/udev/rules.d/$rules ]; then
                cp -p /etc/udev/rules.d/$rules ./lib/udev/rules.d/
        elif [ -e /lib/udev/rules.d/$rules ]; then
                cp -p /lib/udev/rules.d/$rules ./lib/udev/rules.d/
        fi
   done

   copy_with_libs /sbin/dmsetup
   copy_with_libs /sbin/lvm
   ln -s lvm ./sbin/vgchange

   copy_modules "dm-mod"
fi
### end lvm

depmod -b ./ $MODVER

cp -d --remove-destination -a --parents /lib/klibc* ./

for f in /usr/local/sbin/{xbian-hwrng,xbian-frandom,xbian-arch}; do
    copy_with_libs $f ./
done
copy_with_libs /usr/bin/whiptail ./
#copy_with_libs /bin/bash ./
#copy_with_libs /bin/dash ./
#copy_with_libs /bin/sh ./
copy_with_libs /sbin/kexec ./
copy_with_libs /bin/findmnt ./
copy_with_libs /usr/bin/pkill ./
copy_with_libs /usr/sbin/chroot
cp /etc/xbian-initramfs/bootmenu ./
cp /etc/xbian-initramfs/bootmenu_timeout ./
copy_with_libs /bin/mountpoint ./
copy_with_libs /sbin/udevd ./
copy_with_libs /sbin/udevadm ./
copy_with_libs /lib/systemd/systemd-udevd ./
copy_with_libs /sbin/findfs
copy_with_libs /sbin/blkid 
copy_with_libs /sbin/sfdisk
copy_with_libs /sbin/tune2fs
copy_with_libs /sbin/e2fsck 
copy_with_libs /sbin/resize2fs 
#copy_with_libs /usr/local/sbin/dispman_vncserver

#copy_with_libs /bin/kmod
#rm -fr ./bin/modprobe
#copy_with_libs /sbin/modprobe
#copy_with_libs /sbin/lsmod
#copy_with_libs /sbin/rmmod
#copy_with_libs /sbin/insmod
for f in lsmod rmmod insmod modprobe; do
    ln -s /bin/$f ./sbin/$f
done

rm -fr ./bin/awk
copy_with_libs /usr/bin/mawk
ln ./usr/bin/mawk ./usr/bin/awk
rm -fr ./bin/mount
rm -fr ./bin/umount
rm -fr ./bin/date
rm -fr ./bin/grep
copy_with_libs /bin/mount
copy_with_libs /bin/umount
copy_with_libs /bin/date
copy_with_libs /bin/grep
copy_with_libs /sbin/killall5
copy_with_libs /bin/pidof
rm /bin/switch_root
copy_with_libs /sbin/switch_root
#rm -fr ./bin/find
#copy_with_libs /usr/bin/find
copy_with_libs /sbin/btrfs 
copy_with_libs /sbin/btrfs-convert 
copy_with_libs /sbin/btrfs-zero-log
copy_with_libs /usr/sbin/thd
copy_with_libs /usr/sbin/th-cmd
copy_with_libs /usr/bin/nice
copy_with_libs /sbin/partprobe

#copy_with_libs /sbin/iwconfig 
#copy_with_libs /sbin/wpa_supplicant 
cp --remove-destination /usr/lib/klibc/bin/ipconfig ./bin
cp --remove-destination /usr/lib/klibc/bin/run-init ./sbin
cp --remove-destination /usr/lib/klibc/bin/kinit ./sbin
cp --remove-destination /usr/lib/klibc/bin/nuke ./sbin
cp --remove-destination /usr/lib/klibc/bin/nfsmount ./sbin

copy_with_libs /lib/terminfo

cp --parents /usr/share/consolefonts/Lat2-Fixed16.psf.gz ./

#if [ -e ./usr/local/sbin/dispman_vncserver ]; then
#    copy_with_libs /sbin/ldconfig
#    cp --parents /etc/ld.so.conf.d/xbian-firmware.conf ./
#    cp --parents /etc/ld.so.conf ./
#    chroot ./ /sbin/ldconfig 
#fi

copy_with_libs /sbin/ip

copy_with_libs /usr/bin/splash
cp -d --remove-destination --parents /etc/default/template.json ./
cp -d --remove-destination -aR --parents /usr/local/lib/splash ./
copy_with_libs /usr/local/bin/splash-send
copy_with_libs /usr/local/sbin/splash-daemon

copy_with_libs /usr/local/bin/modes-cubox
cp -d --remove-destination -v --parents /lib/udev/{hotplug.functions,firmware.agent,ata_id,edd_id,scsi_id,vio_type,keymap,keyboard-force-release.sh,udev-acl} ./
#cp -d --remove-destination -v --parents -R /lib/udev/keymaps/* ./
cp -d --remove-destination -av --parents /lib/udev/rules.d/{50-udev-default.rules,60-persistent-storage.rules,80-drivers.rules,91-permissions.rules,60-persistent-storage-lvm.rules,60-persistent-input.rules,55-dm.rules,60-persistent-storage-dm.rules} ./
cp -d --remove-destination -av --parents /lib/udev/rules.d/{95-keymap.rules,95-keyboard-force-release.rules,??-local-xbian.rules} ./
#cat /lib/udev/findkeyboards | sed 's/--dry-run//g' > ./lib/udev/findkeyboards
#chmod +x ./lib/udev/findkeyboards
cp /etc/group ./etc

cp /etc/xbian-initramfs/init ./
grep . /etc/motd -m10 > ./motd
cp /etc/xbian-initramfs/howto ./bin
cp /etc/xbian-initramfs/howto.txt ./

cp /etc/xbian-initramfs/trigg.shift ./
cp /etc/xbian-initramfs/bootmenu ./
cp /etc/xbian-initramfs/bootmenu_timeout ./
cp /etc/xbian-initramfs/cnvres-code.sh ./
cp /etc/xbian-initramfs/splash_updater.sh ./

copy_with_libs /usr/bin/stdbuf
copy_with_libs /usr/lib/coreutils/libstdbuf.so
copy_with_libs /usr/bin/setterm
copy_with_libs /usr/bin/mkimage

### zfs
copy_with_libs /usr/sbin/zpool
copy_with_libs /usr/sbin/zfs
copy_with_libs /usr/sbin/mount.zfs
copy_with_libs /etc/zfs/zpool.cache
copy_with_libs /etc/modprobe.d/zfs.conf

need_umount=''
if ! mountpoint -q /boot; then
        mount /boot || { echo "FATAL: /boot can't be mounted"; exit 1; }
        need_umount="yes"
fi

if [ "$MAKEBACKUP" = "yes" ]; then
    test -e /boot/initramfs.gz && mv /boot/initramfs.gz /boot/initramfs.gz.old
    test -e /boot/initramfs.gz.notinuse && mv /boot/initramfs.gz.notinuse /boot/initramfs.gz.old
fi

echo "Creating initram fs."

#find . | cpio -H newc -o | lz4 -cl > /boot/initramfs.gz
find . | cpio -H newc -o | gzip > /boot/initramfs.gz
case "$(xbian-arch)" in
    iMX6|BPI)
            echo "Creating image."
            mv /boot/initramfs.gz /tmp
            mkimage -O linux -A arm -T ramdisk -C gzip -d /tmp/initramfs.gz /boot/initramfs.gz
            ( cd /boot; ./mks; )
            ;;
    *)
            ;;
esac

[ "$need_umount" = "yes" ] && umount /boot

echo initramfs-tools >> /run/reboot-required
sync

exit 0

