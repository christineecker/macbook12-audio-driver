#!/bin/bash

set -euo pipefail

kernel_release="${1:-$(uname -r)}"
kernel_version="${kernel_release%%-*}"
kernel_version="${kernel_version%%_*}"

if [[ ! $kernel_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?([.-]rc[0-9]+)?$ ]]; then
  echo "Unsupported kernel release: $kernel_release" >&2
  exit 2
fi

major_version="${kernel_version%%.*}"
version_tail="${kernel_version#*.}"
minor_version="${version_tail%%.*}"
kernel_short_version="$major_version.$minor_version"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

build_dir="$script_dir/build"
patch_dir="$script_dir/patch_cirrus"
hda_dir="$build_dir/hda"
base_url="https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x"

if [[ -n ${MACBOOK12_AUDIO_KERNEL_CACHE:-} ]]; then
  cache_dir="$MACBOOK12_AUDIO_KERNEL_CACHE"
elif (( EUID == 0 )); then
  cache_dir="/var/cache/macbook12-audio-driver"
else
  cache_dir="$build_dir"
fi

download() {
  local url="$1"
  local destination="$2"

  if command -v curl >/dev/null; then
    curl --fail --location --retry 3 --silent --show-error \
      --output "$destination" "$url"
  elif command -v wget >/dev/null; then
    wget --quiet --tries=3 --output-document="$destination" "$url"
  else
    echo "Install curl or wget to download the matching kernel source." >&2
    return 127
  fi
}

refresh_checksums() {
  local partial="$checksums.part"
  rm -f "$partial"
  download "$base_url/sha256sums.asc" "$partial"
  mv "$partial" "$checksums"
}

checksum_for() {
  local archive_name="$1"
  awk -v filename="$archive_name" '$2 == filename { print $1; exit }' "$checksums"
}

mkdir -p "$build_dir" "$cache_dir"
rm -rf "$hda_dir"

# Debian/Ubuntu Kernel logic adapted from https://github.com/davidjo/snd_hda_macbookpro/blob/master/install.cirrus.driver.sh
is_debian_like=0
# Check if we are dealing with Debian
if [[ $(grep '^NAME=' /etc/os-release | grep -c Debian) -eq 1 ]]; then
  is_debian_like=1
# Check if we are dealing with Ubuntu
elif [[ $(grep '^NAME=' /etc/os-release | grep -c Ubuntu) -eq 1 ]]; then
  is_debian_like=1
# For Unbuntu based distributions like Mint, ubuntu will be mentionned in ID_LIKE
elif [[ $(grep '^ID_LIKE=' /etc/os-release | grep -c "ubuntu") -eq 1 ]]; then
  is_debian_like=1
# In some other Unbuntu based distributions like Pop OS, we need to check ID
elif [ $(grep '^ID=' /etc/os-release | grep -c "ubuntu") -eq 1 ]; then
  is_debian_like=1
fi

if [ -e /usr/src/linux-source-$kernel_version.tar.bz2 ]; then
  is_debian_source_available=1
  comp_type='bz2' # Ubuntu packages provide bz2 compression
elif [ -e /usr/src/linux-source-$kernel_version.tar.xz ]; then
  is_debian_source_available=1
  comp_type='xz'  # Debian packages provde xz compression
else
  is_debian_source_available=0
fi

if [ $is_debian_like -ge 1 ] && [ $is_debian_source_available -eq 1 ]; then
  # NOTE for Ubuntu we need to use the distribution kernel sources as they seem
  # to be significantly modified from the mainline kernel sources generally with backports from later kernels
  # HWE kernels have no linux-source-... package at all, so we fall through to
  # downloading the matching mainline kernel.org tarball below instead.
  archive="/usr/src/linux-source-${kernel_version}.tar.${comp_type}"
  kernel_source_desc="distro source package linux-source-${kernel_version}"
  kernel_version="source-$kernel_version"
else
  kernel_source_desc="pristine mainline ${kernel_version}"
  checksums="$cache_dir/sha256sums-v${major_version}.asc"
  [[ -f $checksums ]] || refresh_checksums
  archive=""
  for candidate_version in "$kernel_version" "$kernel_short_version"; do
    archive_name="linux-${candidate_version}.tar.xz"
    expected_sha256="$(checksum_for "$archive_name")"

    if [[ -z $expected_sha256 ]]; then
      refresh_checksums
      expected_sha256="$(checksum_for "$archive_name")"
    fi
    [[ -n $expected_sha256 ]] || continue

    candidate_archive="$cache_dir/$archive_name"
    if [[ -f $candidate_archive ]]; then
      actual_sha256="$(sha256sum "$candidate_archive" | awk '{ print $1 }')"
    else
      actual_sha256=""
    fi

    if [[ $actual_sha256 != "$expected_sha256" ]]; then
      partial_archive="$candidate_archive.part"
      rm -f "$partial_archive"
      echo "Downloading $archive_name"
      if ! download "$base_url/$archive_name" "$partial_archive"; then
        rm -f "$partial_archive"
        continue
      fi

      actual_sha256="$(sha256sum "$partial_archive" | awk '{ print $1 }')"
      if [[ $actual_sha256 != "$expected_sha256" ]]; then
        rm -f "$partial_archive"
        echo "SHA-256 verification failed for $archive_name" >&2
        exit 3
      fi
      mv "$partial_archive" "$candidate_archive"
    fi

    archive="$candidate_archive"
    kernel_version="$candidate_version"
    break
  done

  if [[ -z $archive ]]; then
    echo "No verified kernel.org source archive found for $kernel_release" >&2
    exit 4
  fi
fi

# Ubuntu (and derivatives such as Mint, Zorin, Pop!_OS on the Ubuntu archive)
# ship HWE kernels without any linux-source-* package, yet those kernels carry
# backported patches that can change struct layouts inside sound/hda. Example:
# 7.0.0-31 backports the v7.1.4 change that adds share_spdif_kctl to
# struct hda_multi_out, shifting every later field of struct hda_gen_spec by
# 8 bytes. A module built against pristine mainline then reads garbage from
# the generic parser's state and Oopses in probe, taking the whole sound card
# with it. So when no distro source is installed, fetch the distro's own patch
# set from Launchpad and overlay its sound/hda hunks on the mainline tree.
ubuntu_overlay=""
if [ $is_debian_like -ge 1 ] && [ $is_debian_source_available -eq 0 ] \
   && command -v dpkg-query >/dev/null; then
  src_pkg=""
  src_ver=""
  if read -r src_pkg src_ver < <(dpkg-query -W \
        -f='${source:Package} ${source:Version}\n' \
        "linux-image-${kernel_release}" 2>/dev/null); then
    # Signed kernels report the linux-signed* source package, whose source on
    # Launchpad is just the binaries. The real tree lives under the unsigned name.
    src_pkg="${src_pkg/#linux-signed/linux}"
  fi
  if [[ -n $src_pkg && -n $src_ver ]]; then
    diff_name="${src_pkg}_${src_ver}.diff.gz"
    diff_file="$cache_dir/$diff_name"
    if [[ ! -s $diff_file ]]; then
      echo "Downloading Ubuntu kernel patch set $diff_name"
      if download "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/${src_pkg}/${src_ver}/${diff_name}" "$diff_file.part"; then
        mv "$diff_file.part" "$diff_file"
      else
        rm -f "$diff_file.part"
        echo "warning: could not fetch $diff_name from Launchpad;" \
             "building against pristine mainline sources" >&2
      fi
    fi
    [[ -s $diff_file ]] && ubuntu_overlay="$diff_file"
  fi
fi

# Never build against pristine mainline on a distro kernel that has no source
# package: the struct layouts would not match the running kernel and loading the
# module can Oops in probe, taking the sound card down until the next reboot.
# Fail closed instead - a warning scrolling past in a DKMS build is far too easy
# to miss for a failure that severe.
if [ $is_debian_like -ge 1 ] && [ $is_debian_source_available -eq 0 ] \
   && [[ -z $ubuntu_overlay ]]; then
  if [[ -n ${MACBOOK12_AUDIO_ALLOW_PRISTINE:-} ]]; then
    echo "warning: MACBOOK12_AUDIO_ALLOW_PRISTINE is set; building against" \
         "pristine mainline sources anyway. The module may crash at probe." >&2
  else
    echo "Refusing to build against pristine mainline sources for $kernel_release." >&2
    echo >&2
    echo "This kernel ships no linux-source package and the matching Ubuntu patch" >&2
    echo "set could not be obtained, so sound/hda struct layouts would not match" >&2
    echo "the running kernel. Loading such a module can Oops in probe and take the" >&2
    echo "sound card down until reboot." >&2
    echo >&2
    echo "Resolve one of the following:" >&2
    echo "  - install the distro kernel source:" >&2
    echo "      sudo apt install linux-source-\$(uname -r | cut -d- -f1)" >&2
    echo "  - restore network access to launchpad.net and re-run" >&2
    echo "  - override anyway (NOT recommended):" >&2
    echo "      MACBOOK12_AUDIO_ALLOW_PRISTINE=1 $0 $kernel_release" >&2
    exit 8
  fi
fi

if (( major_version > 6 || (major_version == 6 && minor_version >= 17) )); then
  makefile_name="Makefile_cs420x"
  hda_subdir="sound/hda"
  tar --strip-components=2 -xf "$archive" --directory="$build_dir" \
    "linux-${kernel_version}/sound/hda"
  mv "$hda_dir/codecs/cirrus/Makefile" "$hda_dir/codecs/cirrus/Makefile.orig"
  mv "$hda_dir/codecs/cirrus/cs420x.c" "$hda_dir/codecs/cirrus/cs420x.c.orig"
  cp "$patch_dir/cs420x.c" \
    "$patch_dir/patch_cirrus_a1534_setup.h" \
    "$patch_dir/patch_cirrus_a1534_pcm.h" \
    "$hda_dir/codecs/cirrus"
  cp "$patch_dir/$makefile_name" "$hda_dir/codecs/cirrus/Makefile"
else
  makefile_name="Makefile_cirrus"
  hda_subdir="sound/pci/hda"
  tar --strip-components=3 -xf "$archive" --directory="$build_dir" \
    "linux-${kernel_version}/sound/pci/hda"
  mv "$hda_dir/Makefile" "$hda_dir/Makefile.orig"
  mv "$hda_dir/patch_cirrus.c" "$hda_dir/patch_cirrus.c.orig"
  cp "$patch_dir/patch_cirrus.c" \
    "$patch_dir/patch_cirrus_a1534_setup.h" \
    "$patch_dir/patch_cirrus_a1534_pcm.h" \
    "$hda_dir"
  cp "$patch_dir/$makefile_name" "$hda_dir/Makefile"
fi

if [[ -n $ubuntu_overlay ]]; then
  if ! command -v patch >/dev/null; then
    echo "The 'patch' utility is required to apply the Ubuntu kernel patch set:" >&2
    echo "  sudo apt install patch" >&2
    exit 6
  fi
  overlay_diff="$build_dir/ubuntu-${hda_subdir//\//-}.diff"
  # Keep only the file diffs whose target path lies under $hda_subdir.
  zcat "$ubuntu_overlay" | awk -v dir="/$hda_subdir/" '
    /^--- / {
      hdr = $0
      if ((getline nxt) > 0) {
        if (nxt ~ /^\+\+\+ /) {
          keep = (index(nxt, dir) > 0)
          if (keep) { print hdr; print nxt }
          next
        }
        if (keep) { print hdr; print nxt }
      } else if (keep) {
        print hdr
      }
      next
    }
    keep { print }' > "$overlay_diff"
  if [[ -s $overlay_diff ]]; then
    # Diff paths look like <pkg>-<version>/sound/hda/...; strip down to $hda_dir.
    strip=$(( $(tr -cd '/' <<< "$hda_subdir" | wc -c) + 2 ))
    echo "Applying Ubuntu $hda_subdir patches from $(basename "$ubuntu_overlay")"
    if ! patch -p"$strip" -d "$hda_dir" -N -r - --no-backup-if-mismatch < "$overlay_diff"; then
      echo "Failed to apply the Ubuntu kernel patches to $hda_dir" >&2
      exit 7
    fi
    kernel_source_desc="$kernel_source_desc + Ubuntu patch set $(basename "$ubuntu_overlay")"
  fi
fi

if (( major_version > 6 || (major_version == 6 && minor_version >= 17) )); then
  sed -i 's/\.free/.remove/' "$hda_dir/codecs/cirrus/patch_cirrus_a1534_pcm.h"
fi

if (( major_version == 6 && minor_version >= 12 && minor_version < 17 )); then
  sed -i 's/snd_pci_quirk/hda_quirk/' "$hda_dir/patch_cirrus.c"
  sed -i 's/SND_PCI_QUIRK\b/HDA_CODEC_QUIRK/' "$hda_dir/patch_cirrus.c"
fi

if (( major_version == 6 && minor_version <= 11 )); then
  sed -i 's/hda_quirk/snd_pci_quirk/' "$hda_dir/patch_cirrus.c"
fi

if (( major_version < 5 || (major_version == 5 && minor_version < 6) )); then
  sed -i 's/timespec64/timespec/' "$hda_dir/patch_cirrus.c"
  sed -i 's/timespec64/timespec/' "$hda_dir/patch_cirrus_a1534_pcm.h"
  sed -i 's/ktime_get_real_ts64/getnstimeofday/' "$hda_dir/patch_cirrus_a1534_pcm.h"
fi

cp "$script_dir/$makefile_name" "$script_dir/Makefile"

# Record which of the three source paths was used. Answers the first question
# in any bug report without having to reconstruct it from the build log.
echo "Kernel source: $kernel_source_desc"
printf '%s\n' \
  "kernel_release: $kernel_release" \
  "kernel_source: $kernel_source_desc" \
  > "$build_dir/source-info.txt"
