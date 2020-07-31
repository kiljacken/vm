#!/bin/bash
if [[ $EUID -ne 0 ]]
then
    echo "This script must be run as root"
    exit 1
fi

VM_NAME="win10"

NET_INTERFACE=$(ip -o route get 8.8.8.8 | grep -Po 'dev \K[A-Za-z\d]+')
NET_BRIDGE_NAME="br0"
NET_TAP_NAME="win10"
NET_DEV_MAC="35:5A:5F:2C:B9:4A"

OVMF_CODE_PATH="/usr/share/ovmf/x64/OVMF_CODE.fd"
OVMF_VARS_PATH="/usr/share/ovmf/x64/OVMF_VARS.fd"
#OVMF_CODE_PATH="/home/kiljacken/vm/ovmf/OVMF_CODE.fd"
#OVMF_VARS_PATH="/home/kiljacken/vm/ovmf/OVMF_VARS.fd"

OVMF_TEMP_VARS=/tmp/ovmf_vars_${VM_NAME}.fd
cp $OVMF_VARS_PATH $OVMF_TEMP_VARS

#export QEMU_AUDIO_DRV=pa
#export QEMU_PA_SERVER=/run/user/1000/pulse/native

MEMORY_MB=16384
TOTAL_CORES='0-23'
HOST_CORES='0-5,12-17' # Cores reserved for host
VIRT_CORES='6-11,18-23' # Cores reserved for virtual machine(s)

setup_networking() {
    sysctl net.ipv4.ip_forward=1

    case "$NET_INTERFACE" in
    "br"*|"enp"*)
        echo "Detected ethernet, using bridging"
        setup_networking_bridge
        ;;

    "wlp"*)
        echo "Detected WiFi, using proxy arp"
        setup_networking_proxy_arp
        ;;

    *)
        echo "Couldn't detect internet type, not setting up networking"
        ;;
    esac
}

teardown_networking() {
    case "$NET_INTERFACE" in
    "enp"*) teardown_networking_bridge ;;
    "wlp"*) teardown_networking_proxy_arp ;;
    *) ;;
    esac

    sysctl net.ipv4.ip_forward=0
}

setup_networking_bridge() {
    if [ ! -d /sys/class/net/br0 ]; then
        BR_INT_OG_UUID=$(nmcli -g GENERAL.CON-UUID device show "${NET_INTERFACE}")
        nmcli con add type bridge autoconnect yes con-name "${NET_BRIDGE_NAME}" ifname "${NET_BRIDGE_NAME}"
        nmcli con modify "${NET_BRIDGE_NAME}" bridge.stp no
        nmcli con add type bridge-slave autoconnect yes con-name ${NET_INTERFACE} ifname ${NET_INTERFACE} master ${NET_BRIDGE_NAME}
        nmcli con down "${BR_INT_OG_UUID}"
        nmcli con up "${NET_BRIDGE_NAME}"
        nmcli con delete "${BR_INT_OG_UUID}"
    fi

    #ip link set $NET_TAP_NAME master br0
    iptables -I FORWARD -m physdev --physdev-is-bridged -j ACCEPT
}

teardown_networking_bridge() {
    iptables -D FORWARD -m physdev --physdev-is-bridged -j ACCEPT
    #ip link set $NET_TAP_NAME nomaster
}

setup_networking_proxy_arp() {
    ip tuntap add dev $NET_TAP_NAME mode tap
    ip link set dev $NET_TAP_NAME address '12:c7:b3:1c:eb:34'

    ip link set $NET_TAP_NAME up
    ip route add 192.168.86.123 dev $NET_TAP_NAME

    sysctl net.ipv4.conf."$NET_TAP_NAME".proxy_arp=1
    sysctl net.ipv4.conf."$NET_INTERFACE".proxy_arp=1

    # iptables routing to get steam streaming working
    iptables -t mangle -A PREROUTING -p udp --dport 27036 -j TEE --gateway 192.168.86.123
}

teardown_networking_proxy_arp() {
    iptables -t mangle -D PREROUTING -p udp --dport 27036 -j TEE --gateway 192.168.86.123

    sysctl net.ipv4.conf."$NET_TAP_NAME".proxy_arp=0
    sysctl net.ipv4.conf."$NET_INTERFACE".proxy_arp=0

    ip route del 192.168.86.123

    ip link set $NET_TAP_NAME down
    ip tuntap del $NET_TAP_NAME mode tap
}

pci_reset() {
    echo 1 > /sys/bus/pci/devices/0000:$1/reset
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

PCI_BUS_GPU_VGA="$(lspci -nn | grep 10de:1f02 | cut -d' ' -f1)"
PCI_BUS_GPU_SND="$(lspci -nn | grep 10de:10f9 | cut -d' ' -f1)"
PCI_BUS_GPU_USB="$(lspci -nn | grep 10de:1ada | cut -d' ' -f1)"
PCI_BUS_GPU_SER="$(lspci -nn | grep 10de:1adb | cut -d' ' -f1)"
PCI_BUS_NVME="$(lspci -nn | grep 8086:f1a5 | cut -d' ' -f1)"
PCI_BUS_USB="$(lspci -nn | grep 1b21:1242 | cut -d' ' -f1)"

EVDEV_MOUSE="/dev/input/by-id/usb-Logitech_USB_Receiver-if02-event-mouse"
if [ ! -e "$EVDEV_MOUSE" ]; then
    echo "Falling back to wired mouse"
    EVDEV_MOUSE="/dev/input/by-id/usb-Logitech_G502_LIGHTSPEED_Wireless_Gaming_Mouse_7C3AC0675C338494-event-mouse"
fi

#pci_reset $PCI_BUS_GPU_VGA
#pci_reset $PCI_BUS_GPU_SND
#pci_reset $PCI_BUS_GPU_USB
#pci_reset $PCI_BUS_GPU_SER

#attach_to_vfio "$PCI_BUS_VGA" "1002 687f"
#attach_to_vfio "$PCI_BUS_SND" "1002 aaf8"
#attach_to_vfio "$PCI_BUS_USB" "1b21 1242"
attach_to_vfio "$PCI_BUS_NVME" "8086 f1a5"


echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

echo "Setting IRQ affinities..."
HOST_INTERRUPTS="iwlwifi amdgpu snd_hda_intel enp9s0 xhci nvme1"
for interrupt in $HOST_INTERRUPTS; do
    echo "Limiting $interrupt interrupts to host cores"
    grep $interrupt /proc/interrupts | cut -d ":" -f 1 | while read -r i; do echo $i; MASK=8; echo $MASK > /proc/irq/$i/smp_affinity_list; done
done

echo never > /sys/kernel/mm/transparent_hugepage/enabled
sysctl vm.stat_interval=120
sysctl -w kernel.watchdog=0

echo "Clearing caches..."
sync
echo 3 > /proc/sys/vm/drop_caches
echo 1 > /proc/sys/vm/compact_memory

# grep "Hugepagesize:" /proc/meminfo
HUGEPAGE_SIZE_KB=$(cat /proc/meminfo  | grep Hugepagesize | awk '{ print $2 }')
HUGEPAGE_COUNT=$(echo "($MEMORY_MB * 1024) / $HUGEPAGE_SIZE_KB" | bc)
echo "Allocating $HUGEPAGE_COUNT hugepages..."
echo $HUGEPAGE_COUNT > /proc/sys/vm/nr_hugepages

ALLOCATED_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages)
if [ "$ALLOCATED_HUGEPAGES" != "$HUGEPAGE_COUNT" ];
then
    echo "Couldn't allocate hugepages!"
fi

setup_networking

# Pin CPU cores
cset set -c $HOST_CORES -s system
cset set -c $VIRT_CORES -s vm
cset proc --force -m -k -f root -t system

# Switch monitor to DP-1 input
#modprobe i2c_dev
#ddcutil -d 2 setvcp 60 0xf

touch /dev/shm/looking-glass
chown kiljacken:kiljacken /dev/shm/looking-glass
chmod 660 /dev/shm/looking-glass

#touch /dev/shm/scream-ivshmem
#chown kiljacken:kiljacken /dev/shm/scream-ivshmem
#chmod 660 /dev/shm/scream-ivshmem

# Copy pulseaudio cookie
# cp /home/kiljacken/.config/pulse/cookie /root/.config/pulse/cookie

(
    echo "Starting scream reciever..."
    su kiljacken -c "env XDG_RUNTIME_DIR=/run/user/1000 scream -o pulse -u -p 4011"
) &

(
    sleep 10s
    echo "Pinning QEMU threads..."
    python qemu_affinity.py $(pidof qemu-system-x86_64) -k 6 18 7 19 8 20 9 21 10 22 11 23
) &

echo "Starting QEMU"
cset proc -e -s vm -- qemu-system-x86_64 \
    -nodefaults \
    -no-user-config \
    -monitor stdio \
    -name $VM_NAME,debug-threads=on \
    -enable-kvm \
    -machine q35,accel=kvm,usb=off,dump-guest-core=off,mem-merge=off,kernel_irqchip=on \
    -cpu host,amd-stibp=off,invtsc=on,topoext=on,svm=off,hv-time,hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-vpindex,hv-runtime,hv-synic,hv-stimer,hv-stimer-direct,hv-reset,hv-vendor-id=other,hv-frequencies,hv-reenlightenment,hv-tlbflush,hv-ipi,kvm=off,host-cache-info=on,l3-cache=off \
    -m $MEMORY_MB \
    -mem-path /dev/hugepages \
    -mem-prealloc \
    -overcommit mem-lock=on,cpu-pm=on \
    -smp cpus=12,sockets=1,cores=6,threads=2 \
    -nographic \
    -vga none \
    -rtc base=localtime,clock=host,driftfix=slew \
    -global kvm-pit.lost_tick_policy=discard \
    -global ICH9-LPC.disable_s3=0 \
    -global ICH9-LPC.disable_s4=0 \
    -no-hpet \
    -drive file=$OVMF_CODE_PATH,if=pflash,format=raw,readonly=on \
    -drive file=$OVMF_TEMP_VARS,if=pflash,format=raw \
    -device vfio-pci,host=$PCI_BUS_GPU_VGA,multifunction=on \
    -device vfio-pci,host=$PCI_BUS_GPU_SND, \
    -device vfio-pci,host=$PCI_BUS_GPU_USB, \
    -device vfio-pci,host=$PCI_BUS_GPU_SER, \
    -device vfio-pci,host=$PCI_BUS_NVME \
    -device qemu-xhci,id=xhci \
    -device virtio-net-pci,netdev=net0,mac=$NET_DEV_MAC \
    -netdev bridge,br=br0,id=net0 \
    -device virtio-serial-pci,id=virtio-serial0,max_ports=16 \
    -chardev spicevmc,name=vdagent,id=vdagent \
    -device virtserialport,nr=1,bus=virtio-serial0.0,chardev=vdagent,name=com.redhat.spice.0 \
    -device ivshmem-plain,memdev=ivshmem0 \
    -object memory-backend-file,id=ivshmem0,share=on,mem-path=/dev/shm/looking-glass,size=32M
    #-object input-linux,id=mouse2,evdev=$EVDEV_MOUSE \
    #-object input-linux,id=kbd2,evdev=/dev/input/by-id/usb-04d9_USB-HID_Keyboard-if02-event-mouse \
    #-object input-linux,id=kbd3,evdev=/dev/input/by-id/usb-04d9_USB-HID_Keyboard-event-kbd,grab_all=on,repeat=on \
    #-device virtio-mouse-pci \
    #-device virtio-keyboard-pci \
    #-device ivshmem-plain,memdev=ivshmem1 \
    #-object memory-backend-file,id=ivshmem1,share=on,mem-path=/dev/shm/scream-ivshmem,size=2M
    #-object input-linux,id=mouse2,evdev=/dev/input/by-id/usb-Logitech_USB_Receiver-if02-event-mouse \
    #-object input-linux,id=mouse2,evdev=/dev/input/by-id/usb-Logitech_G502_LIGHTSPEED_Wireless_Gaming_Mouse_7C3AC0675C338494-event-mouse \
    #-netdev tap,id=net0,ifname=$NET_TAP_NAME,script=no,downscript=no \
    #-device vfio-pci,host=$PCI_BUS_USB \
    #-drive file=./Win10_1809Oct_EnglishInternational_x64.iso,media=cdrom \
    #-drive file=./virtio-win-0.1.160.iso,media=cdrom
    #-soundhw hda \
    #-boot order=dc \
    #-vga std \
    #-drive file=/dev/disk/by-id/ata-ST31000524AS_9VPDNR3W,id=disk0,format=raw,if=none,cache=none,aio=native -device scsi-hd,bus=scsi.0,drive=disk0 \
    #romfile=./hd6950-no-uefi.rom

killall scream

# Switch monitor to DP-2 input
#ddcutil -d 1 setvcp 60 0x10

# Unpin CPU cores
cset set -d system
cset set -d vm

teardown_networking

sysctl vm.stat_interval=1
sysctl -w kernel.watchdog=1

echo "0" > /proc/sys/vm/nr_hugepages

echo schedutil | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

#detach_from_vfio "$PCI_BUS_VGA"
#detach_from_vfio "$PCI_BUS_SND"
#detach_from_vfio "$PCI_BUS_USB"
detach_from_vfio "$PCI_BUS_NVME"

echo "Issuing PCI rescan"
echo 1 > /sys/bus/pci/rescan
