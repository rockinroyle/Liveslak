#!/bin/bash
# $Id: iso2usb.sh,v 1.6 2015/11/29 15:07:35 root Exp root $
#
# Copyright 2015, 2016  Eric Hameleers, Eindhoven, NL
# All rights reserved.
#
# Redistribution and use of this script, with or without modification, is
# permitted provided that the following conditions are met:
#
# 1. Redistributions of this script must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#  THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
#  WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
#  MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO
#  EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
#  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
#  OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
#  WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
#  OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
#  ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Be careful:
set -e

# Set to '1' if you want to ignore all warnings:
FORCE=0

# By default, we use 'persistence' as the name of the persistence directory,
# or 'persistence.img' as the name of the persistence container:
PERSISTENCE="persistence"

# Default persistence type is a directory:
PERSISTTYPE="dir"

# Set to '1' if the script should not ask any questions:
UNATTENDED=0

# By default do not show file operations in detail:
VERBOSE=0

# Seconds to add to the initrd as wait-for-root value:
WAIT=5

# No LUKS encryption by default:
DOLUKS=0

# Initialize more variables:
CNTDEV=""
CNTFILE=""
LUKSHOME=""
LODEV=""

# Define ahead of time, so that cleanup knows about them:
IMGDIR=""
EFIMNT=""
ISOMNT=""
CNTMNT=""
USBMNT=""

# Compressor used on the initrd ("gzip" or "xz --check=crc32");
# Note that the kernel's XZ decompressor does not understand CRC64:
COMPR="xz --check=crc32"

#
#  -- function definitions --
#

# Clean up in case of failure:
cleanup() {
  # Clean up by unmounting our loopmounts, deleting tempfiles:
  echo "--- Cleaning up the staging area..."
  # During cleanup, do not abort due to non-zero exit code:
  set +e
  sync
  if [ $DOLUKS -eq 1 ]; then
    # In case of failure, only the most recent device should still be open:
    if mount |grep -q ${CNTDEV} ; then
      umount -f ${CNTDEV}
      cryptsetup luksClose ${CNTBASE}
      losetup -d ${LODEV}
    fi
  fi
  [ -n "${EFIMNT}" ] && ( /sbin/umount -f ${EFIMNT} 2>/dev/null; rmdir $EFIMNT )
  [ -n "${ISOMNT}" ] && ( /sbin/umount -f ${ISOMNT} 2>/dev/null; rmdir $ISOMNT )
  [ -n "${CNTMNT}" ] && ( /sbin/umount -f ${CNTMNT} 2>/dev/null; rmdir $CNTMNT )
  [ -n "${USBMNT}" ] && ( /sbin/umount -f ${USBMNT} 2>/dev/null; rmdir $USBMNT )
  [ -n "${IMGDIR}" ] && ( rm -rf $IMGDIR )
  set -e
}
trap 'echo "*** $0 FAILED at line $LINENO ***"; cleanup; exit 1' ERR INT TERM

showhelp() {
cat <<EOT
#
# Purpose: to transfer the content of Slackware's Live ISO image
#   to a standard USB thumb drive (which will be formatted and wiped!)
#   and thus create a Slackware Live USB media. 
#
# Your USB thumb drive may contain data!
# This data will be *erased* !
#
# $(basename $0) accepts the following parameters:
#   -c|--crypt size|perc       Add LUKS encrypted /home ; parameter is the
#                              requested size of the container in kB, MB, GB,
#                              or as a percentage of free space.
#                              Examples: '-c 125M', '-c 1.3G', '-c 20%'.
#   -f|--force                 Ignore most warnings (except the back-out).
#   -h|--help                  This help.
#   -i|--infile <filename>     Full path to the ISO image file.
#   -o|--outdev <filename>     The device name of your USB drive.
#   -p|--persistence <dirname> Custom name of the 'persistence' directory.
#   -u|--unattended            Do not ask any questions.
#   -v|--verbose               Show verbose messages.
#   -w|--wait<number>          Add <number> seconds wait time to initialize USB.
#   -C|--cryptpersistfile size|perc
#                              Use a LUKS-encrypted 'persistence' file instead
#                              of a directory (for use on FAT filesystem).
#   -P|--persistfile           Use a 'persistence' container file instead of
#                              a directory (for use on FAT filesystem).
#
# Examples:
#
# $(basename $0) -i ~/download/slackware64-live-14.2.iso -o /dev/sdX
# $(basename $0) -i slackware64-live-xfce-current.iso -o /dev/sdX -c 750M -w 15
#
EOT
}

# Uncompress the initrd based on the compression algorithm used:
uncompressfs () {
  if $(file "${1}" | grep -qi ": gzip"); then
    gzip -cd "${1}"
  elif $(file "${1}" | grep -qi ": XZ"); then
    xz -cd "${1}"
  fi
}

# Add longer USB WAIT to the initrd:
update_initrd() {
  IMGFILE="$1"

  # USB boot medium needs a few seconds boot delay else the overlay will fail.
  # Check if we need to update the wait-for-root file in the initrd:
  OLDWAIT=$(uncompressfs ${IMGFILE} |cpio -i --to-stdout wait-for-root 2>/dev/null)
  if [ "$OLDWAIT" = "$WAIT" -a $DOLUKS -eq 0 ]; then
    return
  fi
  
  if [ -z "$IMGDIR" ]; then
    # Create a temporary extraction directory for the initrd:
    mkdir -p /mnt
    IMGDIR=$(mktemp -d -p /mnt -t alienimg.XXXXXX)
    if [ ! -d $IMGDIR ]; then
      echo "*** Failed to create a temporary extraction directory for the initrd!"
      exit 1
    fi
  fi
  chmod 711 $IMGDIR

  echo "--- Extracting Slackware initrd and adding rootdelay for USB..."
  cd ${IMGDIR}
    uncompressfs ${IMGFILE} \
      | cpio -i -d -H newc --no-absolute-filenames
    echo "--- Updating 'waitforroot' time from '$OLDWAIT' to '$WAIT':"
    echo ${WAIT} > wait-for-root

    if [ $DOLUKS -eq 1 -a -n "${LUKSHOME}" ]; then
      if ! grep -q ${LUKSHOME} luksdev ; then
        echo "--- Adding '${LUKSHOME}' as LUKS /home:"
        echo "${LUKSHOME}" >> luksdev
      fi
    fi

    echo "--- Compressing the initrd image again:"
    chmod 0755 ${IMGDIR}
    find . |cpio -o -H newc |$COMPR > ${IMGFILE}
  cd - 2>/dev/null
  rm -rf $IMGDIR/*
} # End of update_initrd()

# Create a container file in the empty space of the partition
create_container() {
  CNTPART=$1
  CNTSIZE=$2
  CNTBASE=$3
  CNTENCR=$4 # 'none' or 'luks'
  CNTUSED=$5 # '/home' or 'persistence'

  # Determine size of the target partition (in MB), and the free space:
  PARTSIZE=$(df -P -BM ${CNTPART} |tail -1 |tr -s '\t' ' ' |cut -d' ' -f2)
  PARTSIZE=${PARTSIZE%M}
  PARTFREE=$(df -P -BM ${CNTPART} |tail -1 |tr -s '\t' ' ' |cut -d' ' -f4)
  PARTFREE=${PARTFREE%M}

  if [ $PARTFREE -lt 10 ]; then
    echo "** Free space on USB partition is less than 10 MB;"
    echo "** Not creating a container file!"
    exit 1
  fi

  # Determine requested container size (allow for '%|k|K|m|M|g|G' suffix):
  case "${CNTSIZE: -1}" in
     "%") CNTSIZE="$(( $PARTFREE * ${CNTSIZE%\%} / 100 ))" ;;
     "k") CNTSIZE="$(( ${CNTSIZE%k} / 1024 ))" ;;
     "K") CNTSIZE="$(( ${CNTSIZE%K} / 1024 ))" ;;
     "m") CNTSIZE="${CNTSIZE%m}" ;;
     "M") CNTSIZE="${CNTSIZE%M}" ;;
     "g") CNTSIZE="$(( ${CNTSIZE%g} * 1024 ))" ;;
     "G") CNTSIZE="$(( ${CNTSIZE%G} * 1024 ))" ;;
       *) ;;
  esac

  if [ $CNTSIZE -le 0 ]; then
    echo "** Container size must be larger than ZERO!"
    echo "** Check your '-c' commandline parameter."
    exit 1
  elif [ $CNTSIZE -ge $PARTFREE ]; then
    echo "** Not enough free space for container file!"
    echo "** Check your '-c' commandline parameter."
    exit 1
  fi

  # Create an empty container file (re-use previously created one):
  if [ -f $USBMNT/${CNTBASE}.img ]; then
    CNTFILE="${CNTBASE}.img"
    CNTSIZE=$(( $(du -sk ${CNTFILE}) / 1024 ))
    if [ $UNATTENDED -eq 0 ]; then
      echo "*** File '${CNTFILE}' already exists (size ${CNTSIZE} MB). ***"
      echo "*** If you do not want to re-use it for '$CNTUSED', ***"
      echo "*** then press CONTROL-C now and rename that file! ***"
      read -p "Else press ENTER to continue: " JUNK
      # OK... the user was sure about the file...
    fi
  else
    echo "--- Creating ${CNTSIZE} MB container file using 'dd if=/dev/urandom', patience please..."
    CNTFILE="${CNTBASE}.img"
    # Create a sparse file (not allocating any space yet):
    dd of=$USBMNT/${CNTFILE} bs=1M count=0 seek=$CNTSIZE
  fi

  # Setup a loopback device that we can use with cryptsetup:
  LODEV=$(losetup -f)
  losetup $LODEV $USBMNT/${CNTFILE}
  if [ "${CNTENCR}" = "luks" ]; then
    # Format the loop device with LUKS:
    echo "--- Encrypting the container file with LUKS; enter 'YES' and a passphrase..."
    cryptsetup -y luksFormat $LODEV
    # Unlock the LUKS encrypted container:
    echo "--- Unlocking the LUKS container requires your passphrase again..."
    cryptsetup luksOpen $LODEV ${CNTBASE}
    CNTDEV=/dev/mapper/${CNTBASE}
    # Now we allocate blocks for the LUKS device. We write encrypted zeroes,
    # so that the file looks randomly filled from the outside.
    # Take care not to write more bytes than the internal size of the container:
    CNTIS=$(( $(lsblk -b -n -o SIZE  $(readlink -f ${CNTDEV})) / 512))
    dd if=/dev/zero of=${CNTDEV} bs=512 count=${CNTIS} || true
  else
    CNTDEV=$LODEV
    # Un-encrypted container files remain sparse.
  fi

  # Format the now available block device with a linux fs:
  mkfs.ext4 ${CNTDEV}
  # Tune the ext4 filesystem:
  tune2fs -m 0 -c 0 -i 0 ${CNTDEV}

  if [ "${CNTUSED}" != "persistence" ]; then
    # Create a mount point for the unlocked container:
    CNTMNT=$(mktemp -d -p /mnt -t aliencnt.XXXXXX)
    if [ ! -d $CNTMNT ]; then
      echo "*** Failed to create temporary mount point for the LUKS container!"
      cleanup
      exit 1
    else
      chmod 711 $CNTMNT
    fi
    # Copy the original /home (or whatever mount) content into the container:
    echo "--- Copying '${CNTUSED}' from LiveOS to container..."
    HOMESRC=$(find ${USBMNT} -name "0099-slackware_zzzconf*" |tail -1)
    mount ${CNTDEV} ${CNTMNT}
    unsquashfs -n -d ${CNTMNT}/temp ${HOMESRC} ${CNTUSED}
    mv ${CNTMNT}/temp/${CNTUSED}/* ${CNTMNT}/
    rm -rf ${CNTMNT}/temp
    umount ${CNTDEV}
  fi

  # Don't forget to clean up after ourselves:
  if [ "${CNTENCR}" = "luks" ]; then
    cryptsetup luksClose ${CNTBASE}
  fi
  losetup -d ${LODEV} || true

} # End of create_container() {

#
#  -- end of function definitions --
#

# Parse the commandline parameters:
if [ -z "$1" ]; then
  showhelp
  exit 1
fi
while [ ! -z "$1" ]; do
  case $1 in
    -c|--crypt)
      HLUKSSIZE="$2"
      DOLUKS=1
      shift 2
      ;;
    -f|--force)
      FORCE=1
      shift
      ;;
    -h|--help)
      showhelp
      exit
      ;;
    -i|--infile)
      SLISO="$(cd $(dirname $2); pwd)/$(basename $2)"
      shift 2
      ;;
    -o|--outdev)
      TARGET="$2"
      shift 2
      ;;
    -p|--persistence)
      PERSISTENCE="$2"
      shift 2
      ;;
    -u|--unattended)
      UNATTENDED=1
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      RVERBOSE=" -v --progress "
      shift
      ;;
    -w|--wait)
      WAIT="$2"
      shift 2
      ;;
    -C|--cryptpersistfile)
      DOLUKS=1
      PLUKSSIZE="$2"
      PERSISTTYPE="file"
      shift 2
      ;;
    -P|--persistfile)
      PERSISTTYPE="file"
      shift
      ;;
    *)
      echo "*** Unknown parameter '$1'!"
      exit 1
      ;;
  esac
done

# Before we start:
[ -x /bin/id ] && CMD_ID="/bin/id" || CMD_ID="/usr/bin/id"
if [ "$($CMD_ID -u)" != "0" -a $FORCE -eq 0 ]; then
  echo "*** You need to be root to run $(basename $0)."
  exit 1
fi

# More sanity checks:
if [ -z "$TARGET" -o -z "$SLISO" ]; then
  echo "*** You must specify both the Live ISO filename and the USB devicename!"
  exit 1
fi

if [ ! -f $SLISO -a $FORCE -eq 0 ]; then
  echo "*** This is not a useable file: '$SLISO' !"
  exit 1
fi

if [ ! -b $TARGET -a $FORCE -eq 0 ]; then
  echo "*** Not a block device: '$TARGET' !"
  exit 1
elif [ "$(echo ${TARGET%[0-9]})" != "$TARGET" -a $FORCE -eq 0 ]; then
  echo "*** You need to point to the USB device, not a partition ($TARGET)!"
  exit 1
fi

# Are all the required not-so-common add-on tools present?
PROG_MISSING=""
for PROGN in blkid cpio extlinux fdisk gdisk iso-info mkdosfs sgdisk unsquashfs ; do
  if ! PATH="/sbin:$PATH" which $PROGN 1>/dev/null 2>/dev/null ; then
    PROG_MISSING="${PROG_MISSING}--   $PROGN\n"
  fi
done
if [ ! -z "$PROG_MISSING" ] ; then
  echo "-- Required program(s) not found in root's PATH!"
  echo -e ${PROG_MISSING}
  echo "-- Exiting."
  exit 1
fi

# Confirm wipe:
cat <<EOT
#
# We are going to format this device (erase all data) - '$TARGET':
# Vendor : $(cat /sys/block/$(basename $TARGET)/device/vendor)
# Model  : $(cat /sys/block/$(basename $TARGET)/device/model)
# Size   : $(( $(cat /sys/block/$(basename $TARGET)/size) / 2048)) MB
#
# FDISK OUTPUT:
EOT
echo q |/sbin/gdisk -l $TARGET 2>/dev/null | while read LINE ; do echo "# $LINE" ; done

if [ $UNATTENDED -eq 0 ]; then
  cat <<EOT

***                                                       ***
*** If this is the wrong drive, then press CONTROL-C now! ***
***                                                       ***

EOT
  read -p "Or press ENTER to continue: " JUNK
  # OK... the user was sure about the drive...
fi

# Get the LABEL used for the ISO:
LIVELABEL=$(/sbin/blkid -s LABEL -o value ${SLISO})

# Use sgdisk to wipe and then setup the USB device:
# - 1 MB BIOS boot partition
# - 100 MB EFI system partition
# - Let Slackware have the rest
# - Make the Linux partition "legacy BIOS bootable"
# Make sure that there is no MBR nor a partition table anymore:
dd if=/dev/zero of=$TARGET bs=512 count=1 conv=notrunc
# The first sgdisk command is allowed to have non-zero exit code:
/sbin/sgdisk -og $TARGET || true
/sbin/sgdisk \
  -n 1:2048:4095 -c 1:"BIOS Boot Partition" -t 1:ef02 \
  -n 2:4096:208895 -c 2:"EFI System Partition" -t 2:ef00 \
  -n 3:208896:0 -c 3:"Slackware Linux" -t 3:8300 \
  $TARGET
/sbin/sgdisk -A 3:set:2 $TARGET
# Show what we did to the USB stick:
/sbin/sgdisk -p -A 3:show $TARGET

# Create filesystems:
# Not enough clusters for a 32 bit FAT:
/sbin/mkdosfs -s 2 -n "DOS" ${TARGET}1
/sbin/mkdosfs -F32 -s 2 -n "EFI" ${TARGET}2
# KDE tends to automount.. so try an umount:
if /sbin/mount |grep -qw ${TARGET}3 ; then /sbin/umount ${TARGET}3 || true ; fi
/sbin/mkfs.ext4 -F -F -L "${LIVELABEL}" -m 0 ${TARGET}3
/sbin/tune2fs -c 0 -i 0 ${TARGET}3

# Create temporary mount points for the ISO file:
mkdir -p /mnt
EFIMNT=$(mktemp -d -p /mnt -t alienefi.XXXXXX)
if [ ! -d $EFIMNT ]; then
  echo "*** Failed to create a temporary mount point for the ISO!"
  cleanup
  exit 1
else
  chmod 711 $EFIMNT
fi
ISOMNT=$(mktemp -d -p /mnt -t alieniso.XXXXXX)
if [ ! -d $ISOMNT ]; then
  echo "*** Failed to create a temporary mount point for the ISO!"
  cleanup
  exit 1
else
  chmod 711 $ISOMNT
fi

# Find out if the ISO contains an EFI bootloader and use it:
EFIBOOT=0
EFIOFFSET=$(/sbin/fdisk -lu ${SLISO} 2>/dev/null |grep EFI |tr -s ' ' | cut -d' ' -f 2)
if [ -n "$EFIOFFSET" ]; then
  # Mount the EFI partition so we can retrieve the EFI bootloader:
  /sbin/mount -o loop,offset=$((512*$EFIOFFSET))  ${SLISO} ${EFIMNT}
  if [ ! -f ${EFIMNT}/EFI/BOOT/bootx64.efi ]; then
    echo "-- Note: UEFI boot file 'bootx64.efi' not found on ISO."
    echo "-- UEFI boot will not be supported"
  elif [ ! -f ${EFIMNT}/EFI/BOOT/bootia32.efi ]; then
    echo "-- Note: UEFI boot file 'bootia32.efi' not found on ISO."
    echo "-- 32-bit UEFI boot will not be supported"
  else
    EFIBOOT=1
  fi
fi

# Create a temporary mount point for the USB device:
mkdir -p /mnt
USBMNT=$(mktemp -d -p /mnt -t alienusb.XXXXXX)
if [ ! -d $USBMNT ]; then
  echo "*** Failed to create a temporary mount point for the USB device!"
  cleanup
  exit 1
else
  chmod 711 $USBMNT
fi

# Mount the Linux partition:
/sbin/mount -t auto ${TARGET}3 ${USBMNT}

# Loop-mount the ISO (or 1st partition if this is a hybrid ISO):
/sbin/mount -o loop ${SLISO} ${ISOMNT}

# Copy the ISO content into the USB Linux partition:
echo "--- Copying files from ISO to USB... takes some time."
rsync -a ${RVERBOSE} --exclude=EFI ${ISOMNT}/* ${USBMNT}/

# Write down the version of the ISO image:
VERSION=$(iso-info ${SLISO} |grep Application |cut -d: -f2- 2>/dev/null)
if [ -n "$VERSION" ]; then
  echo "$VERSION" > ${USBMNT}/.isoversion
fi

if [ $DOLUKS -eq 1 ]; then
  # Create LUKS container file:
  create_container ${TARGET}3 ${HLUKSSIZE} slhome luks /home
  LUKSHOME=${CNTFILE}
fi

# Add more USB WAIT seconds to the initrd:
update_initrd ${USBMNT}/boot/initrd.img

if [ "${PERSISTTYPE}" = "dir" ]; then
  # Create persistence directory:
  mkdir -p ${USBMNT}/${PERSISTENCE}
elif [ "${PERSISTTYPE}" = "file" ]; then
  # Create container file for persistent storage.
  # If it is not going to be LUKS encrypted, we create a sparse file
  # that will at most eat up 90% of free space. Sparse means, the actual
  # block allocation will start small and grows as more changes are written.
  # Note: the word "persistence" below is a keyword for create_container:
  if [ -z "${PLUKSSIZE}" ]; then
    # Un-encrypted container:
    create_container ${TARGET}3 90% ${PERSISTENCE} none persistence
  else
    # LUKS-encrypted container:
    create_container ${TARGET}3 ${PLUKSSIZE} ${PERSISTENCE} luks persistence
  fi
else
  echo "*** Unknown persistence type '${PERSISTTYPE}'!"
  cleanup
  exit 1 
fi

# Use extlinux to make the USB device bootable:
echo "--- Making the USB drive '$TARGET' bootable using extlinux..."
mv ${USBMNT}/boot/syslinux ${USBMNT}/boot/extlinux
mv ${USBMNT}/boot/extlinux/isolinux.cfg ${USBMNT}/boot/extlinux/extlinux.conf
rm ${USBMNT}/boot/extlinux/isolinux.*
/sbin/extlinux --install ${USBMNT}/boot/extlinux

# No longer needed:
/sbin/umount ${USBMNT}

if [ $EFIBOOT -eq 1 ]; then
  # Mount the EFI partition and copy /EFI as well as /boot directories into it:
  /sbin/mount -t vfat -o shortname=mixed ${TARGET}2 ${USBMNT}
  mkdir -p ${USBMNT}/EFI/BOOT
  rsync -rlptD ${ISOMNT}/EFI/BOOT/* ${USBMNT}/EFI/BOOT/
  mkdir -p ${USBMNT}/boot
  rsync -rlptD ${ISOMNT}/boot/* ${USBMNT}/boot/
  # Add more USB WAIT seconds to the initrd:
  update_initrd ${USBMNT}/boot/initrd.img
fi

# No longer needed:
/sbin/umount ${USBMNT}
/sbin/umount ${EFIMNT}

# Unmount/remove stuff:
cleanup

# Install a GPT compatible MBR record:
if [ -f /usr/share/syslinux/gptmbr.bin ]; then
  cat /usr/share/syslinux/gptmbr.bin > ${TARGET}
else
  echo "*** Failed to make USB device bootable - 'gptmbr.bin' not found!"
  cleanup
  exit 1 
fi

# THE END

