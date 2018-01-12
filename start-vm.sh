#!/bin/bash
if [[ $EUID -ne 0 ]]
then
	echo "This script must be run as root"
	exit 1
fi

vm_name="win10"

pci_id_vga="1002 67df"
pci_id_snd="1002 aaf0"
pci_bus_vga="01:00.0"
pci_bus_snd="01:00.1"

num_hugepages=8200

net_interface="wlp5s0"
net_tap_name="win10"
net_dev_mac="35:5A:5F:2C:B9:4A"

#ovmf_code_path="/usr/share/ovmf/ovmf_code_x64.bin"
#ovmf_vars_path="/usr/share/ovmf/ovmf_vars_x64.bin"
ovmf_code_path="/home/kiljacken/vm/ovmf/OVMF_CODE-pure-efi.fd"
ovmf_vars_path="/home/kiljacken/vm/ovmf/OVMF_VARS-pure-efi.fd"

disk_name="vfio-win10.raw"
disk_format="raw"

evdev_keyboard="/dev/input/event4"
evdev_mouse="/dev/input/by-id/usb-Logitech_USB_Receiver-if02-event-mouse"

machine_type="pc-i440fx-2.11"

export QEMU_AUDIO_DRV=pa
export QEMU_PA_SERVER=/run/user/1000/pulse/native


function setup_networking() {
	ip tuntap add dev $net_tap_name mode tap
	ip link set dev $net_tap_name address '12:c7:b3:1c:eb:34'
	ip addr add 172.20.0.1/24 dev $net_tap_name
	ip link set $net_tap_name up

    sysctl net.ipv4.ip_forward=1
    sysctl net.ipv4.conf."$net_interface".forwarding=1

    iptables -t nat -A POSTROUTING -o $net_interface -j MASQUERADE
	iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -i $net_tap_name -o $net_interface -j ACCEPT
}

function teardown_networking() {
    iptables -t nat -D POSTROUTING -o $net_interface -j MASQUERADE
	iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	iptables -D FORWARD -i $net_tap_name -o $net_interface -j ACCEPT

	ip link set $net_tap_name down
	ip tuntap del $net_tap_name mode tap
}

function attach_to_vfio() {
	modprobe vfio-pci
	echo "Attaching device to vfio-pci: $1 ($2)"
	echo $2 > /sys/bus/pci/drivers/vfio-pci/new_id
	echo "0000:$1" > /sys/bus/pci/devices/0000:$1/driver/unbind
	echo "0000:$1" > /sys/bus/pci/drivers/vfio-pci/bind
	echo $2 > /sys/bus/pci/drivers/vfio-pci/remove_id
}

function detach_from_vfio() {
	for device in $@; do
		echo "Detaching device from vfio-pci: $device";
		echo 1 > /sys/bus/pci/devices/0000:$device/remove
	done
	echo "Issuing PCI rescan"
	echo 1 > /sys/bus/pci/rescan
}

function allocate_hugepages() {
	echo "Allocating $num_hugepages hugepages"
	echo $num_hugepages  > /proc/sys/vm/nr_hugepages
}

function free_hugepages() {
	echo "Freeing hugepages"
	echo 0 > /proc/sys/vm/nr_hugepages
}

function set_governor() {
	echo $1 | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
}

attach_to_vfio "$pci_bus_vga" "$pci_id_vga"
attach_to_vfio "$pci_bus_snd" "$pci_id_snd"
setup_networking
allocate_hugepages
set_governor "performance"

ovmf_tmp_vars=/tmp/ovmf_vars_${vm_name}.fd
cp $ovmf_vars_path $ovmf_tmp_vars

# Pin CPU cores
cset set -c 0,1,6,7 -s system
cset set -c 0-11 -s vm
cset proc --force -m -k -f root -t system

echo "Starting QEMU"
cset proc -e -s vm -- qemu-system-x86_64 \
	-name $vm_name \
	-nodefaults \
	-nodefconfig \
	-no-user-config \
	-enable-kvm \
	-cpu host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time \
	-smp cpus=8,sockets=1,cores=4,threads=2 \
	-machine $machine_type,accel=kvm,mem-merge=off \
	-vcpu vcpunum=0,affinity=2 -vcpu vcpunum=1,affinity=8 \
	-vcpu vcpunum=2,affinity=3 -vcpu vcpunum=3,affinity=9 \
	-vcpu vcpunum=4,affinity=4 -vcpu vcpunum=5,affinity=10 \
	-vcpu vcpunum=6,affinity=5 -vcpu vcpunum=7,affinity=11 \
	-m 16384 \
	-mem-path /dev/hugepages \
	-mem-prealloc \
	-drive file=$ovmf_code_path,if=pflash,format=raw,readonly=on \
	-drive file=$ovmf_tmp_vars,if=pflash,format=raw \
	-vga none \
	-nographic \
	-rtc base=localtime,clock=host,driftfix=slew \
	-no-hpet \
	-object input-linux,id=mouse1,evdev=$evdev_mouse \
	-object input-linux,id=kbd1,evdev=$evdev_keyboard,grab_all=on,repeat=on \
	-device vfio-pci,host=$pci_bus_vga,multifunction=on \
	-device vfio-pci,host=$pci_bus_snd \
	-device virtio-net-pci,netdev=net0,mac=$net_dev_mac \
	-netdev tap,id=net0,ifname=$net_tap_name,script=no,downscript=no \
	-soundhw hda \
	-object iothread,id=iothread0 \
	-device virtio-scsi-pci,id=scsi,iothread=iothread0 \
	-drive file=$disk_name,id=disk0,format=$disk_format,if=none,cache=none,aio=native -device scsi-hd,bus=scsi.0,drive=disk0 \
	-drive file=/dev/sda,id=disk1,format=raw,if=none,cache=writeback,aio=threads -device scsi-hd,bus=scsi.0,drive=disk1
	#-drive file=./Win10_1709_EnglishInternational_x64.iso,media=cdrom \
	#-drive file=./virtio-win-0.1.141.iso,media=cdrom

# Unpin CPU cores
cset set -d system
cset set -d vm

set_governor "powersave"
free_hugepages
teardown_networking
detach_from_vfio "$pci_bus_vga" "$pci_bus_snd"