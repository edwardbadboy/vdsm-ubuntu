#!/bin/sh --
export LC_ALL=C

# copied from vdsm.spec
# Packages names
VDSM_NAME=vdsm
VDSM_BOOTSTRAP=vdsm-bootstrap
VDSM_REG=vdsm-reg

# copied from vdsm.spec
# Required users and groups
VDSM_USER=vdsm
VDSM_GROUP=kvm
# Fedora QEMU_GROUP=qemu, on Ubuntu qemu process started by libvirt is in group kvm
QEMU_GROUP=kvm
SNLK_GROUP=sanlock
SNLK_USER=sanlock

# copied from autogen.sh
PREFIX=/usr
LIBDIR=$PREFIX/lib
SYSCONFDIR=/etc
LOCALSTATEDIR=/var
if [ -d /usr/lib64 ]; then
  LIBDIR=$PREFIX/lib64
fi

DATADIR="$PREFIX/share"
INITRDDIR=/etc/init.d
BINDIR="$PREFIX/bin"

echo "------ clean ------"
if [ -f "Makefile" ]; then
	make clean
	make distclean
fi

echo "------ build ------"
./autogen.sh --system && make

if [ "$?" -ne 0 ]; then
	echo "build fail"
	exit 1
fi

echo "------ make check ------"
if [ "$NOSE_EXCLUDE" = "" ]; then
	NOSE_EXCLUDE='test_aligned_image|test_bad_path|test_help_response|test_nonaligned_image' make check
else
	NOSE_EXCLUDE="$NOSE_EXCLUDE|"'test_aligned_image|test_bad_path|test_help_response|test_nonaligned_image' make check
fi

if [ "$?" -ne 0 ]; then
	echo "make check fail"
	exit 1
fi

echo "------ pre install ------"
/usr/bin/getent passwd "$VDSM_USER" >/dev/null || \
    /usr/sbin/useradd -r -u 36 -g "$VDSM_GROUP" -d /var/lib/vdsm \
        -s /usr/sbin/nologin -c "Node Virtualization Manager" "$VDSM_USER"
/usr/sbin/usermod -a -G "$QEMU_GROUP","$SNLK_GROUP" "$VDSM_USER"
/usr/sbin/usermod -a -G "$QEMU_GROUP","$VDSM_GROUP" "$SNLK_USER"

if [ "$?" -ne 0 ]; then
	echo "pre install fail"
	exit 1
fi

echo "------ make install ------"
make install

if [ "$?" -ne 0 ]; then
	echo "install fail"
	exit 1
fi

echo "------ install ------"
install -Dm 0755 vdsm/respawn \
                 "$DATADIR"/"$VDSM_NAME"/respawn

# Install the lvm rules
install -Dm 0644 vdsm/storage/86-vdsm-lvm.rules \
                 /lib/udev/rules.d/86-vdsm-lvm.rules

install -Dm 0644 vdsm/limits.conf \
                 /etc/security/limits.d/99-vdsm.conf

install -Dm 0755 vdsm/vdsmd.init "$INITRDDIR"/vdsmd
install -Dm 0755 vdsm_reg/vdsm-reg.init "$INITRDDIR"/vdsm-reg

# This is not commonplace, but we want /var/log/core to be a world-writable
# dropbox for core dumps
install -dDm 1777 "$LOCALSTATEDIR"/log/core

# Install the configuration sample
install -Dm 0644 vdsm/vdsm.conf.sample \
                 "$SYSCONFDIR"/vdsm/vdsm.conf

if [ "$?" -ne 0 ]; then
	echo "install fail"
	exit 1
fi

echo "------ post install ------"
"$BINDIR"/vdsm-tool sebool-config || :
# set the vdsm "secret" password for libvirt
"$BINDIR"/vdsm-tool set-saslpasswd

# Have moved vdsm section in /etc/sysctl.conf to /etc/sysctl.d/vdsm.
# So Remove them if it is played with /etc/sysctl.conf.
if grep -q "# VDSM section begin" /etc/sysctl.conf; then
    /bin/sed -i '/# VDSM section begin/,/# VDSM section end/d' \
        /etc/sysctl.conf
fi

# Make the /etc/sysctl.d/vdsm take effect immediately after installation.
/sbin/sysctl -q -p /etc/sysctl.d/vdsm

# there is no chkconfig in latest Ubunt, use update-rc.d instead
# /sbin/chkconfig --add vdsmd
/usr/sbin/update-rc.d vdsmd start 99 2 3 4 5 . stop 0 0 1 6 .

if [ "$?" -ne 0 ]; then
	echo "post install fail"
	exit 1
fi

chown -R vdsm:kvm /rhev
chown -R vdsm:kvm /var/log/vdsm
chown -R vdsm:kvm /var/lib/libvirt/qemu/channels
chmod 644 /etc/iscsi/initiatorname.iscsi

echo "------ disable apparmor ------"
service apparmor stop
update-rc.d -f apparmor remove
echo "you have to restart the system to fully disable apparmor"

echo "done"
