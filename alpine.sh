#!/bin/sh
#genetate alpine edge x86/x86_64 image: chmod +x gen-alpine.sh && sudo ./gen-alpine.sh
#depends: apk-tools-static, vim(xxd)

set -x

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

if [ "$(id -u)" -ne 0 ]; then
	die 'This script must be run as root!'
fi

which xxd >/dev/null || exit 

BUILD_DATE="$(date +%Y-%m-%d)"

usage() {
	cat <<EOF
	Usage: gen-alpine.sh [options]
	Valid options are:
		-a ARCH                 Options: x86, x86_64.
		-m ALPINE_MIRROR        URI of the mirror to fetch packages from
		                        (default is https://mirrors.tuna.tsinghua.edu.cn/alpine).
		-o OUTPUT_IMG           Output img file
		                        (default is BUILD_DATE-alpine-ARCH.img).
		-h                      Show this help message and exit.
EOF
}

while getopts 'a:m:o:h' OPTION; do
	case "$OPTION" in
		a) ARCH="$OPTARG";;
		m) ALPINE_MIRROR="$OPTARG";;
		o) OUTPUT="$OPTARG";;
		h) usage; exit 0;;
	esac
done 

: ${ARCH:="$(uname -m)"}
: ${ALPINE_MIRROR:="https://mirrors.tuna.tsinghua.edu.cn/alpine"}
: ${OUTPUT_IMG:="${BUILD_DATE}-alpine-${ARCH}.img"}

case $ARCH in
	 x86| i[3456]86 ) ARCH=x86 GRUB_EFI_TARGET=i386-efi;; 
	   x64 | x86_64 ) ARCH=X86_64 GRUB_EFI_TARGET=x86_64-efi;; 
	               *) die 'not supported arch';;
esac

#=======================  F u n c t i o n s  =======================#

gen_image() {
	fallocate -l $(( 700 * 1024 *1024 )) "$OUTPUT_IMG"
cat > fdisk.cmd <<-EOF
	o
	n
	p
	1
	
	+100MB
	t
	c
	a
	n
	p
	2
	
	
	w
EOF
fdisk "$OUTPUT_IMG" < fdisk.cmd
rm -f fdisk.cmd
}

do_format() {
	mkfs.fat -F32 "$BOOT_DEV"
	mkfs.ext4 "$ROOT_DEV"
	mkdir -p mnt
	mount "$ROOT_DEV" mnt
	mkdir -p mnt/boot
	mount "$BOOT_DEV" mnt/boot
}

setup_mirrors() {
	mv mnt/etc/apk/repositories mnt/etc/apk/repositories.old

	for ALPINE_REPOS in main community testing ; do
		echo ${ALPINE_MIRROR}/edge/${ALPINE_REPOS} >> mnt/etc/apk/repositories
	done
}

do_apkstrap() {
	apk.static -X ${ALPINE_MIRROR}/edge/main -U --allow-untrusted --root mnt --initdb add alpine-base
}

install_kernel() {
	apk add linux-vanilla
}

gen_grub_cfg() {
	cat > /boot/grub/grub.cfg <<- EOF
	set timeout=2
	insmod all_video
	menuentry "Alpine Linux" {
	    search --no-floppy --fs-uuid --set=root ${BOOT_UUID}
	    echo	'Loading Linux vanilla ...'
	    linux   /vmlinuz-vanilla root=UUID=${ROOT_UUID} rw  modules=sd-mod,usb-storage,ext4 nomodeset quiet rootfstype=ext4
	    echo	'Loading initial ramdisk ...'
	    initrd  /initramfs-vanilla
	}
	EOF
}	

install_bootloader() {

	# grub-bios

	apk add grub grub-bios
	grub-install --target=i386-pc --recheck --boot-directory /boot ${LOOP_DEV}
	
	# grub-efi
	apk add grub-efi efibootmgr
	grub-install --target=${GRUB_EFI_TARGET} --efi-directory=/boot --boot-directory=/boot --bootloader-id=grub --removable

	gen_grub_cfg

	# sometimes after reboot, the bootloader work not normal, seems need to reboot again
	# alpine x86 efi bootloader not support x64 pc
}

gen_fstabs() {
	echo "PARTUUID=${BOOT_PARTUUID}  /boot           vfat    defaults          0       2
PARTUUID=${ROOT_PARTUUID}  /               ext4    defaults,noatime         0       1"
}

gen_resize2fs_once_service() {
	cat > /etc/init.d/resize2fs-once <<'EOF'
#!/sbin/openrc-run
command="/usr/bin/resize2fs-once"
command_background=false
depend() {
        after modules
        need localmount
}
EOF

	cat > /usr/bin/resize2fs-once <<'EOF'
#!/bin/sh 
set -xe
ROOT_DEV=$(findmnt / -o source -n)
cat > /tmp/fdisk.cmd <<-EOF
	d
	2
	
	n
	p
	2
	
	
	w
	EOF
fdisk "$(echo "$ROOT_DEV" | sed -E 's/p?2$//')" < /tmp/fdisk.cmd
rm -f /tmp/fdisk.cmd
partprobe
resize2fs "$ROOT_DEV"
rc-update del resize2fs-once default
#reboot
EOF

chmod +x /etc/init.d/resize2fs-once /usr/bin/resize2fs-once
rc-update add resize2fs-once default
}

gen_nm_ntpd_dispatcher_scripts() {
        cat > /etc/NetworkManager/dispatcher.d/10-ntpd <<'EOF'
#!/bin/sh

set -xe

case "$2" in
        up)
                rc-service ntpd restart
        ;;
        down)
                rc-service ntpd stop
        ;;
esac
EOF

chmod +x /etc/NetworkManager/dispatcher.d/10-ntpd
}

make_bash_fancy() {
	su alpine <<-'EOF'
	sh -c 'cat > /home/alpine/.profile << "EOF"
	if [ -f "$HOME/.bashrc" ] ; then
	    source $HOME/.bashrc
	fi
	EOF'
	
	wget https://gist.github.com/yangxuan8282/f2537770982a5dec74095ce4f32de59c/raw/ce003332eff55d50738b726f68a1b493c6867594/.bashrc -P /home/alpine
	EOF
}

add_normal_user() {
	addgroup alpine
	adduser -G alpine -s /bin/bash -D alpine
	echo "alpine:alpine" | /usr/sbin/chpasswd
	echo "alpine ALL=NOPASSWD: ALL" >> /etc/sudoers
}

add_user_groups() {
	for USER_GROUP in adm dialout cdrom audio users wheel video games plugdev input netdev; do
		adduser alpine $USER_GROUP
	done
}

setup_ntp_server() {
	sed -i 's/pool.ntp.org/cn.pool.ntp.org/' /etc/init.d/ntpd
}

install_xorg_driver() {
	apk add xorg-server xf86-video-intel xf86-video-fbdev xf86-input-libinput
}

install_xfce4() {

	install_xorg_driver

	apk add xfce4 xfce4-mixer xfce4-wavelan-plugin lxdm paper-icon-theme arc-theme \
		gvfs gvfs-smb sshfs \
        	network-manager-applet gnome-keyring

	mkdir -p /usr/share/wallpapers &&
	curl https://img2.goodfon.com/original/2048x1820/3/b6/android-5-0-lollipop-material-5355.jpg \
		--output /usr/share/wallpapers/android-5-0-lollipop-material-5355.jpg

	su alpine sh -c 'mkdir -p /home/alpine/.config && \
	wget https://github.com/yangxuan8282/dotfiles/archive/master.tar.gz -O- | \
		tar -C /home/alpine/.config -xzf - --strip=2 dotfiles-master/alpine-config'

	sed -i 's/^# autologin=dgod/autologin=alpine/' /etc/lxdm/lxdm.conf
	sed -i 's|^# session=/usr/bin/startlxde|session=/usr/bin/startxfce4|' /etc/lxdm/lxdm.conf

	rc-update add lxdm default
}

# take from postmarketOS

setup_openrc_service() {
	setup-udev -n

	for service in devfs dmesg; do
		rc-update add $service sysinit
	done
	for service in hwclock modules sysctl hostname bootmisc swclock syslog; do
		rc-update add $service boot
	done
	for service in dbus haveged sshd wpa_supplicant ntpd local networkmanager; do
		rc-update add $service default
	done
	for service in mount-ro killprocs savecache; do
		rc-update add $service shutdown
	done

	mkdir -p /run/openrc
	touch /run/openrc/shutdowntime
}

gen_nm_config() {
	cat <<EOF
[main]
plugins+=ifupdown
dhcp=dhcpcd

[ifupdown]
managed=true

[logging]
level=INFO

[device-mac-randomization]
wifi.scan-rand-mac-address=yes
EOF
}

gen_wpa_supplicant_config() {
	sed -i 's/wpa_supplicant_args=\"/wpa_supplicant_args=\" -u -Dwext,nl80211/' /etc/conf.d/wpa_supplicant
	touch /etc/wpa_supplicant/wpa_supplicant.conf
}

gen_syslog_config() {
	sed s/=\"/=\""-C4048 "/  -i /etc/conf.d/syslog
}

gen_env() {
	echo "LOOP_DEV=${LOOP_DEV}
	ROOT_PARTUUID=${ROOT_PARTUUID}
	BOOT_UUID=${BOOT_UUID}
	ROOT_UUID=${ROOT_UUID}
	GRUB_EFI_TARGET=${GRUB_EFI_TARGET}"
}

setup_chroot() {
	chroot mnt /bin/sh <<-EOF
		set -xe
		source /root/env_file
		source /root/functions
		rm -f /root/functions /root/env_file
		echo "root:toor" | chpasswd
		apk --update add sudo
		add_normal_user
		echo "alpine" > /etc/hostname
		echo "127.0.0.1    alpine alpine.localdomain" > /etc/hosts
		apk add dbus eudev haveged openssh util-linux shadow e2fsprogs e2fsprogs-extra tzdata
		apk add iw wireless-tools crda wpa_supplicant networkmanager
		apk add nano htop bash bash-completion curl tar
		apk add ca-certificates wget && update-ca-certificates
		setup_openrc_service
		add_user_groups
		gen_nm_config > /etc/NetworkManager/conf.d/networkmanager.conf
		gen_nm_ntpd_dispatcher_scripts
		gen_wpa_supplicant_config
		gen_syslog_config
		setup_ntp_server
		ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		make_bash_fancy
		gen_resize2fs_once_service		
		install_bootloader
		install_kernel
		#install_xfce4
EOF
}

mounts() {
	mount -t proc none mnt/proc
	mount -o bind /sys mnt/sys
	mount -o bind /dev mnt/dev
}

umounts() {
	umount mnt/dev
	umount mnt/sys
	umount mnt/proc
	umount mnt/boot
	umount mnt
	losetup -d "$LOOP_DEV"
}

#=======================  F u n c t i o n s  =======================#

pass_function() {
	sed -nE '/^#===.*F u n c t i o n s.*===#/,/^#===.*F u n c t i o n s.*===#/p' "$0"
}

gen_image

LOOP_DEV=$(losetup --partscan --show --find "${OUTPUT_IMG}")
BOOT_DEV="$LOOP_DEV"p1
ROOT_DEV="$LOOP_DEV"p2

do_format

do_apkstrap

IMGID="$(dd if="${OUTPUT_IMG}" skip=440 bs=1 count=4 2>/dev/null | xxd -e | cut -f 2 -d' ')"

BOOT_PARTUUID="${IMGID}-01"
ROOT_PARTUUID="${IMGID}-02"

BOOT_UUID=$(blkid ${BOOT_DEV} | cut -f 2 -d '"')
ROOT_UUID=$(blkid ${ROOT_DEV} | cut -f 2 -d '"')

gen_fstabs > mnt/etc/fstab

gen_env > mnt/root/env_file

pass_function > mnt/root/functions

mounts

setup_mirrors

cp /etc/resolv.conf mnt/etc/resolv.conf

setup_chroot

umounts

cat >&2 <<-EOF
	---
	Installation is complete
	Flash to usb disk with: dd if=${OUTPUT_IMG} of=/dev/TARGET_DEV bs=4M
	
EOF
