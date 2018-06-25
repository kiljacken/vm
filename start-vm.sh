#!/bin/bash
if [[ $EUID -ne 0 ]]
then
    echo "This script must be run as root"
    exit 1
fi

VM_NAME="win10"
VM_MEMORY=$((16 * 1024 * 1024 * 1024))

NET_INTERFACE="wlp5s0"
NET_TAP_NAME="win10"
NET_DEV_MAC="35:5A:5F:2C:B9:4A"

#OVMF_CODE_PATH="/usr/share/ovmf/ovmf_code_x64.bin"
#OVMF_VARS_PATH="/usr/share/ovmf/ovmf_vars_x64.bin"
OVMF_CODE_PATH="/home/kiljacken/vm/ovmf/OVMF_CODE.fd"
OVMF_VARS_PATH="/home/kiljacken/vm/ovmf/OVMF_VARS.fd"

OVMF_TEMP_VARS=/tmp/ovmf_vars_${VM_NAME}.fd
cp $OVMF_VARS_PATH $OVMF_TEMP_VARS

EVDEV_KEYBOARD="/dev/input/event4"
EVDEV_MOUSE="/dev/input/by-id/usb-Logitech_USB_Receiver-if02-event-mouse"

export QEMU_AUDIO_DRV=pa
export QEMU_PA_SERVER=/run/user/1000/pulse/native

TOTAL_CORES='0-11'
HOST_CORES='0-1,6-7'            # Cores reserved for host
VIRT_CORES='2-5,8-11'           # Cores reserved for virtual machine(s)

HUGEPAGES_SIZE=$(grep Hugepagesize /proc/meminfo | awk {'print $2'})
HUGEPAGES_SIZE=$((HUGEPAGES_SIZE * 1024))

VM_HUGEPAGES_NEED=$(( VM_MEMORY / HUGEPAGES_SIZE ))

setup_networking() {
    ip tuntap add dev $NET_TAP_NAME mode tap
    ip link set dev $NET_TAP_NAME address '12:c7:b3:1c:eb:34'
    ip link set $NET_TAP_NAME up
    ip route add 192.168.0.123 dev $NET_TAP_NAME

    sysctl net.ipv4.conf."$NET_TAP_NAME".proxy_arp=1
    sysctl net.ipv4.conf."$NET_INTERFACE".proxy_arp=1
    sysctl net.ipv4.ip_forward=1

    # iptables routing to get steam streaming working
    iptables -t mangle -A PREROUTING -p udp --dport 27036 -j TEE --gateway 192.168.0.123
}

teardown_networking() {
    iptables -t mangle -D PREROUTING -p udp --dport 27036 -j TEE --gateway 192.168.0.123

    sysctl net.ipv4.conf."$NET_TAP_NAME".proxy_arp=0
    sysctl net.ipv4.conf."$NET_INTERFACE".proxy_arp=0
    sysctl net.ipv4.ip_forward=0

    ip route del 192.168.0.123
    ip link set $NET_TAP_NAME down
    ip tuntap del $NET_TAP_NAME mode tap
}

attach_to_vfio() {
    modprobe vfio-pci
    echo "Attaching device to vfio-pci: $1 ($2)"
    echo $2 > /sys/bus/pci/drivers/vfio-pci/new_id
    echo "0000:$1" > /sys/bus/pci/devices/0000:$1/driver/unbind
    echo "0000:$1" > /sys/bus/pci/drivers/vfio-pci/bind
    echo $2 > /sys/bus/pci/drivers/vfio-pci/remove_id
}

detach_from_vfio() {
    for device in $@; do
       echo "Detaching device from vfio-pci: $device";
       echo 1 > /sys/bus/pci/devices/0000:$device/remove
    done
    echo "Issuing PCI rescan"
    echo 1 > /sys/bus/pci/rescan
}

allocate_hugepages() {
    echo "Allocating $num_hugepages hugepages"
    echo $num_hugepages  > /proc/sys/vm/nr_hugepages
}

free_hugepages() {
    echo "Freeing hugepages"
    echo 0 > /proc/sys/vm/nr_hugepages
}

set_governor() {
    echo $1 | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null
}

PCI_BUS_VGA="01:00.0"
PCI_BUS_SND="01:00.1"
PCI_BUS_NVME="06:00.0"
PCI_BUS_USB="04:00.0"

#attach_to_vfio "$PCI_BUS_VGA" "1002 67df"
#attach_to_vfio "$PCI_BUS_SND" "1002 aaf0"
attach_to_vfio "$PCI_BUS_NVME" "144d a804"
attach_to_vfio "$PCI_BUS_USB" "1b21 1242"

echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory

sysctl vm.nr_hugepages=$VM_HUGEPAGES_NEED
sysctl vm.stat_interval=120
sysctl -w kernel.watchdog=0
# THP can allegedly result in jitter. Better keep it off.
echo never > /sys/kernel/mm/transparent_hugepage/enabled
# Force P-states to P0
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo 0 > /sys/bus/workqueue/devices/writeback/numa

#allocate_hugepages
#set_governor "performance"
setup_networking

# Pin CPU cores
cset set -c $HOST_CORES -s system
cset set -c $VIRT_CORES -s vm
cset proc --force -m -k -f root -t system

# Switch monitor to DP input
modprobe i2c_dev
ddcutil setvcp 60 0x0f

echo "Starting QEMU"
cset proc -e -s vm -- qemu-system-x86_64 \
    -name $VM_NAME \
    -nodefaults \
    -nodefconfig \
    -no-user-config \
    -enable-kvm \
    -cpu host,kvm=off,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time,hv_vendor_id=nuckfvidia \
    -smp cpus=8,sockets=1,cores=4,threads=2 \
    -machine pc-i440fx-2.11,accel=kvm,mem-merge=off \
    -vcpu vcpunum=0,affinity=2 -vcpu vcpunum=1,affinity=8 \
    -vcpu vcpunum=2,affinity=3 -vcpu vcpunum=3,affinity=9 \
    -vcpu vcpunum=4,affinity=4 -vcpu vcpunum=5,affinity=10 \
    -vcpu vcpunum=6,affinity=5 -vcpu vcpunum=7,affinity=11 \
    -m 16384 \
    -mem-path /dev/hugepages \
    -mem-prealloc \
    -drive file=$OVMF_CODE_PATH,if=pflash,format=raw,readonly=on \
    -drive file=$OVMF_TEMP_VARS,if=pflash,format=raw \
    -vga none \
    -nographic \
    -monitor stdio \
    -rtc base=localtime,clock=host,driftfix=slew \
    -no-hpet \
    -object input-linux,id=mouse1,evdev=$EVDEV_MOUSE \
    -object input-linux,id=kbd1,evdev=$EVDEV_KEYBOARD,grab_all=on,repeat=on \
    -device ioh3420,bus=pci.0,addr=1c.0,multifunction=on,port=1,chassis=1,id=root \
    -device vfio-pci,host=$PCI_BUS_VGA,bus=root,addr=00.0,multifunction=on \
    -device vfio-pci,host=$PCI_BUS_SND,bus=root,addr=00.1 \
    -device vfio-pci,host=$PCI_BUS_NVME,bus=root,addr=01.0 \
    -device vfio-pci,host=$PCI_BUS_USB,bus=root,addr=02.0 \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -device virtio-net-pci,netdev=net0,mac=$NET_DEV_MAC \
    -netdev tap,id=net0,ifname=$NET_TAP_NAME,script=no,downscript=no \
    -soundhw hda \
    -object iothread,id=iothread0 \
    -device virtio-scsi-pci,id=scsi,iothread=iothread0 \
    -drive file=/dev/disk/by-id/ata-ST31000524AS_9VPDNR3W,id=disk0,format=raw,if=none,cache=none,aio=native -device scsi-hd,bus=scsi.0,drive=disk0
    #-drive file=./Win10_1803_EnglishInternational_x64.iso,media=cdrom \
    #-drive file=./virtio-win-0.1.141.iso,media=cdrom

# Switch monitor to HDMI input
ddcutil setvcp 60 0x11

# Unpin CPU cores
cset set -d system
cset set -d vm

#set_governor "powersave"
#free_hugepages
teardown_networking

sysctl vm.nr_hugepages=0
sysctl vm.stat_interval=1
sysctl -w kernel.watchdog=1
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo 1 > /sys/bus/workqueue/devices/writeback/numa

#detach_from_vfio "$PCI_BUS_VGA" "$PCI_BUS_SND"
detach_from_vfio "$PCI_BUS_NVME" "$PCI_BUS_USB"
