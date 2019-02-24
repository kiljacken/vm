#!/bin/bash
if [[ $EUID -ne 0 ]]
then
    echo "This script must be run as root"
    exit 1
fi

VM_NAME="win10"

NET_INTERFACE="wlp8s0"
NET_TAP_NAME="win10"
NET_DEV_MAC="35:5A:5F:2C:B9:4A"

OVMF_CODE_PATH="/usr/share/ovmf/x64/OVMF_CODE.fd"
OVMF_VARS_PATH="/usr/share/ovmf/x64/OVMF_VARS.fd"
#OVMF_CODE_PATH="/home/kiljacken/vm/ovmf/OVMF_CODE.fd"
#OVMF_VARS_PATH="/home/kiljacken/vm/ovmf/OVMF_VARS.fd"

OVMF_TEMP_VARS=/tmp/ovmf_vars_${VM_NAME}.fd
cp $OVMF_VARS_PATH $OVMF_TEMP_VARS

EVDEV_KEYBOARD="/dev/input/by-path/platform-i8042-serio-0-event-kbd"
EVDEV_MOUSE="/dev/input/by-id/usb-SteelSeries_SteelSeries_Sensei_310_eSports_Mouse_000000000000-if01-event-mouse"

export QEMU_AUDIO_DRV=pa
export QEMU_PA_SERVER=/run/user/1000/pulse/native

TOTAL_CORES='0-11'
HOST_CORES='0-1,6-7'            # Cores reserved for host
VIRT_CORES='2-5,8-11'           # Cores reserved for virtual machine(s)

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
    echo "Detaching device from vfio-pci: $1";
    echo 1 > /sys/bus/pci/devices/0000:$1/remove
}

PCI_BUS_VGA="$(lspci -nn | grep 1002:6719 | cut -d' ' -f1)"
PCI_BUS_SND="$(lspci -nn | grep 1002:aa80 | cut -d' ' -f1)"
PCI_BUS_NVME="$(lspci -nn | grep 8086:f1a5 | cut -d' ' -f1)"
PCI_BUS_USB="$(lspci -nn | grep 1b21:1242 | cut -d' ' -f1)"

#attach_to_vfio "$PCI_BUS_VGA" "1002 687f"
#attach_to_vfio "$PCI_BUS_SND" "1002 aaf8"
#attach_to_vfio "$PCI_BUS_USB" "1b21 1242"
attach_to_vfio "$PCI_BUS_NVME" "8086 f1a5"

echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory

echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

setup_networking

# Pin CPU cores
cset set -c $HOST_CORES -s system
cset set -c $VIRT_CORES -s vm
cset proc --force -m -k -f root -t system

# Switch monitor to DP-1 input
modprobe i2c_dev
ddcutil -d 1 setvcp 60 0x10

touch /dev/shm/looking-glass
chown kiljacken:kiljacken /dev/shm/looking-glass
chmod 660 /dev/shm/looking-glass

echo "Starting QEMU"
cset proc -e -s vm -- qemu-system-x86_64 \
    -name $VM_NAME \
    -enable-kvm \
    -cpu host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_time \
    -smp cpus=8,sockets=1,cores=4,threads=2 \
    -machine q35,accel=kvm,mem-merge=off \
    -vcpu vcpunum=0,affinity=2 -vcpu vcpunum=1,affinity=8 \
    -vcpu vcpunum=2,affinity=3 -vcpu vcpunum=3,affinity=9 \
    -vcpu vcpunum=4,affinity=4 -vcpu vcpunum=5,affinity=10 \
    -vcpu vcpunum=6,affinity=5 -vcpu vcpunum=7,affinity=11 \
    -m 8192 \
    -mem-prealloc \
    -nographic \
    -vga none \
    -rtc base=localtime,clock=host,driftfix=slew \
    -no-hpet \
    -object input-linux,id=mouse1,evdev=$EVDEV_MOUSE \
    -object input-linux,id=kbd1,evdev=$EVDEV_KEYBOARD,grab_all=on,repeat=on \
    -device vfio-pci,host=$PCI_BUS_VGA,multifunction=on,x-vga=on,romfile=./hd6950-no-uefi.rom \
    -device vfio-pci,host=$PCI_BUS_SND, \
    -device vfio-pci,host=$PCI_BUS_NVME \
    -device virtio-mouse-pci \
    -device virtio-keyboard-pci \
    -device virtio-net-pci,netdev=net0,mac=$NET_DEV_MAC \
    -device ivshmem-plain,memdev=ivshmem \
    -object memory-backend-file,id=ivshmem,share=on,mem-path=/dev/shm/looking-glass,size=32M \
    -netdev tap,id=net0,ifname=$NET_TAP_NAME,script=no,downscript=no \
    -soundhw hda \
    -boot order=dc \
    -drive file=./Win10_1809Oct_EnglishInternational_x64.iso,media=cdrom \
    -drive file=./virtio-win-0.1.160.iso,media=cdrom
    #-monitor stdio \
    #-nodefaults \
    #-no-user-config \
    #-drive file=$OVMF_CODE_PATH,if=pflash,format=raw,readonly=on \
    #-drive file=$OVMF_TEMP_VARS,if=pflash,format=raw \
    #-device vfio-pci,host=$PCI_BUS_USB,bus=root_port1,addr=02.0 \
    #-vga std \
    #-drive file=/dev/disk/by-id/ata-ST31000524AS_9VPDNR3W,id=disk0,format=raw,if=none,cache=none,aio=native -device scsi-hd,bus=scsi.0,drive=disk0 \
    #romfile=./hd6950-no-uefi.rom

# Switch monitor to DP-2 input
ddcutil -d 1 setvcp 60 0x10

# Unpin CPU cores
cset set -d system
cset set -d vm

teardown_networking

echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

#detach_from_vfio "$PCI_BUS_VGA"
#detach_from_vfio "$PCI_BUS_SND"
#detach_from_vfio "$PCI_BUS_USB"
detach_from_vfio "$PCI_BUS_NVME"

echo "Issuing PCI rescan"
echo 1 > /sys/bus/pci/rescan