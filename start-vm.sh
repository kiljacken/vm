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
OVMF_CODE_PATH="/home/kiljacken/vm/ovmf/OVMF_CODE-pure-efi.fd"
OVMF_VARS_PATH="/home/kiljacken/vm/ovmf/OVMF_VARS-pure-efi.fd"

OVMF_TEMP_VARS=/tmp/ovmf_vars_${VM_NAME}.fd
cp $OVMF_VARS_PATH $OVMF_TEMP_VARS

DISK_NAME="vfio-win10.raw"
DISK_FORMAT="raw"

EVDEV_KEYBOARD="/dev/input/event4"
EVDEV_MOUSE="/dev/input/by-id/usb-Logitech_USB_Receiver-if02-event-mouse"

export QEMU_AUDIO_DRV=pa
export QEMU_PA_SERVER=/run/user/1000/pulse/native

TOTAL_CORES='0-11'
TOTAL_CORES_MASK=FFF            # 0-11, bitmask 0b111111111111
HOST_CORES='0-1,6-7'            # Cores reserved for host
HOST_CORES_MASK=C3              # 0-1,6-7, bitmask 0b000011000011
VIRT_CORES='2-5,8-11'           # Cores reserved for virtual machine(s)

HUGEPAGES_SIZE=$(grep Hugepagesize /proc/meminfo | awk {'print $2'})
HUGEPAGES_SIZE=$((HUGEPAGES_SIZE * 1024))

VM_HUGEPAGES_NEED=$(( VM_MEMORY / HUGEPAGES_SIZE ))

shield_vm() {
    cset set -c $TOTAL_CORES -s machine.slice
    # Shield two cores cores for host and rest for VM(s)
    cset shield --kthread on --cpu $VIRT_CORES
}

unshield_vm() {
    echo $TOTAL_CORES_MASK > /sys/bus/workqueue/devices/writeback/cpumask
    cset shield --reset
}

setup_networking() {
    ip tuntap add dev $NET_TAP_NAME mode tap
    ip link set dev $NET_TAP_NAME address '12:c7:b3:1c:eb:34'
    ip addr add 172.20.0.1/24 dev $NET_TAP_NAME
    ip link set $NET_TAP_NAME up

    sysctl net.ipv4.ip_forward=1
    sysctl net.ipv4.conf."$NET_INTERFACE".forwarding=1

    iptables -t nat -A POSTROUTING -o $NET_INTERFACE -j MASQUERADE
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i $NET_TAP_NAME -o $NET_INTERFACE -j ACCEPT
}

teardown_networking() {
    iptables -t nat -D POSTROUTING -o $NET_INTERFACE -j MASQUERADE
    iptables -D FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -D FORWARD -i $NET_TAP_NAME -o $NET_INTERFACE -j ACCEPT

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

#attach_to_vfio "$PCI_BUS_VGA" "1002 67df"
#attach_to_vfio "$PCI_BUS_SND" "1002 aaf0"
setup_networking

echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory

sysctl vm.nr_hugepages=$VM_HUGEPAGES_NEED

shield_vm

sysctl vm.stat_interval=120

sysctl -w kernel.watchdog=0
# the kernel's dirty page writeback mechanism uses kthread workers. They introduce
# massive arbitrary latencies when doing disk writes on the host and aren't
# migrated by cset. Restrict the workqueue to use only cpu 0.
echo $HOST_CORES_MASK > /sys/bus/workqueue/devices/writeback/cpumask
# THP can allegedly result in jitter. Better keep it off.
echo never > /sys/kernel/mm/transparent_hugepage/enabled
# Force P-states to P0
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo 0 > /sys/bus/workqueue/devices/writeback/numa
>&2 echo "VM Shielded"

#allocate_hugepages
#set_governor "performance"


# Pin CPU cores
#cset set -c 0,1,6,7 -s system
#cset set -c 0-11 -s vm
#cset proc --force -m -k -f root -t system

echo "Starting QEMU"
#cset proc -e -s vm --
taskset -c $TOTAL_CORES qemu-system-x86_64 \
    -name $VM_NAME \
    -nodefaults \
    -nodefconfig \
    -no-user-config \
    -enable-kvm \
    -cpu host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time \
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
    -rtc base=localtime,clock=host,driftfix=slew \
    -no-hpet \
    -object input-linux,id=mouse1,evdev=$EVDEV_MOUSE \
    -object input-linux,id=kbd1,evdev=$EVDEV_KEYBOARD,grab_all=on,repeat=on \
    -device ioh3420,bus=pci.0,addr=1c.0,multifunction=on,port=1,chassis=1,id=root \
    -device vfio-pci,host=$PCI_BUS_VGA,bus=root,addr=00.0,multifunction=on \
    -device vfio-pci,host=$PCI_BUS_SND,bus=root,addr=00.1 \
    -device virtio-net-pci,netdev=net0,mac=$NET_DEV_MAC \
    -netdev tap,id=net0,ifname=$NET_TAP_NAME,script=no,downscript=no \
    -soundhw hda \
    -object iothread,id=iothread0 \
    -device virtio-scsi-pci,id=scsi,iothread=iothread0 \
    -drive file=$DISK_NAME,id=disk0,format=$DISK_FORMAT,if=none,cache=none,aio=native -device scsi-hd,bus=scsi.0,drive=disk0 \
    -drive file=/dev/sda,id=disk1,format=raw,if=none,cache=writeback,aio=threads -device scsi-hd,bus=scsi.0,drive=disk1
    #-drive file=./Win10_1709_EnglishInternational_x64.iso,media=cdrom \
    #-drive file=./virtio-win-0.1.141.iso,media=cdrom

# Unpin CPU cores
#cset set -d system
#cset set -d vm

#set_governor "powersave"
#free_hugepages

sysctl vm.nr_hugepages=0
sysctl vm.stat_interval=1
sysctl -w kernel.watchdog=1
unshield_vm
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo 1 > /sys/bus/workqueue/devices/writeback/numa
>&2 echo "VMs UnShielded"

teardown_networking
#detach_from_vfio "$PCI_BUS_VGA" "$PCI_BUS_SND"