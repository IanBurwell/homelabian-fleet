#!/usr/bin/env bash
# Prepare an official Raspberry Pi OS Lite (64-bit) image pre-configured for
# headless Ansible provisioning (SSH enabled, user/password hash, SSH key, and
# homelabian.local hostname), and either flash it directly to an SD card or
# save the customized .img file to disk (e.g. to flash from Windows).
#
# Usage:
#   sudo ./scripts/provision_rpi_sdcard.sh --device /dev/sdX [options]
#   sudo ./scripts/provision_rpi_sdcard.sh --output ./homelabian-rpi.img [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOMELABIAN_ENV="${REPO_ROOT}/../homelabian/.env"

RASPIOS_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest"
CACHE_DIR="/var/cache/homelabian"
CACHE_IMAGE="${CACHE_DIR}/raspios_lite_arm64_latest.img.xz"

TARGET_DEVICE=""
OUTPUT_IMAGE=""
IMAGE_PATH=""
INIT_HOSTNAME="homelabian"
NEW_USER=""
NEW_USER_PASS_SHA=""
AUTHORIZED_SSH_PUB_KEY=""
ASSUME_YES=false

# Load literal KEY=VALUE defaults from ../homelabian/.env if present
# (Do not `source` because systemd/mkosi .env files contain unquoted $6$... SHA-512 hashes)
if [[ -f "${HOMELABIAN_ENV}" ]]; then
    while IFS='=' read -r key val || [[ -n "${key}" ]]; do
        key="${key%$'\r'}"
        val="${val%$'\r'}"
        [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
        case "${key}" in
            NEW_USER) NEW_USER="${val}" ;;
            NEW_USER_PASS_SHA) NEW_USER_PASS_SHA="${val}" ;;
            AUTHORIZED_SSH_PUB_KEY) AUTHORIZED_SSH_PUB_KEY="${val}" ;;
        esac
    done < "${HOMELABIAN_ENV}"
fi

NEW_USER="${NEW_USER:-en}"

usage() {
    cat <<EOF
Usage:
  sudo $(basename "$0") --device /dev/sdX [options]
  sudo $(basename "$0") --output ./homelabian-rpi.img [options]

Target (specify one):
  -d, --device <path>          Target SD card block device (e.g. /dev/sdb or /dev/mmcblk0)
  -o, --output <path.img>      Save customized image to a file instead of flashing an SD card

Optional:
  -i, --image <path>           Local Raspberry Pi OS .img or .img.xz file
                               (defaults to downloading ${RASPIOS_URL})
  -u, --user <username>        Initial username (default: ${NEW_USER})
  -p, --password-hash <hash>   SHA-512 password hash from 'openssl passwd -6'
                               (default: read from ../homelabian/.env or become.pass)
  -k, --ssh-key <key-or-file>  SSH public key string or path to .pub file
                               (default: read from ../homelabian/.env or ~/.ssh/*.pub)
  -n, --hostname <name>        Initial hostname for mDNS discovery (default: ${INIT_HOSTNAME})
  -y, --yes                    Skip interactive confirmation prompt
  -h, --help                   Show this help message
EOF
}

require_arg() {
    if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "Error: Option '$1' requires a non-empty argument." >&2
        usage >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            require_arg "$@"
            TARGET_DEVICE="$2"
            shift 2
            ;;
        -o|--output)
            require_arg "$@"
            OUTPUT_IMAGE="$2"
            shift 2
            ;;
        -i|--image)
            require_arg "$@"
            IMAGE_PATH="$2"
            shift 2
            ;;
        -u|--user)
            require_arg "$@"
            NEW_USER="$2"
            shift 2
            ;;
        -p|--password-hash)
            require_arg "$@"
            NEW_USER_PASS_SHA="$2"
            shift 2
            ;;
        -k|--ssh-key)
            require_arg "$@"
            AUTHORIZED_SSH_PUB_KEY="$2"
            shift 2
            ;;
        -n|--hostname)
            require_arg "$@"
            INIT_HOSTNAME="$2"
            shift 2
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)." >&2
    exit 1
fi

for cmd in awk curl dd findmnt install losetup lsblk mktemp mount openssl sed udevadm umount xz; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Error: Required command '${cmd}' is not installed." >&2
        exit 1
    fi
done

INIT_HOSTNAME="${INIT_HOSTNAME%.local}"
if [[ ! "${INIT_HOSTNAME}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "Error: Invalid hostname '${INIT_HOSTNAME}' (must be a valid RFC 1123 single label)." >&2
    exit 1
fi

if [[ ! "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "Error: Invalid username '${NEW_USER}'." >&2
    exit 1
fi

if [[ -z "${TARGET_DEVICE}" && -z "${OUTPUT_IMAGE}" ]]; then
    echo "Error: Specify either --device <block-device> or --output <file.img>." >&2
    usage >&2
    exit 1
fi

if [[ -n "${TARGET_DEVICE}" && -n "${OUTPUT_IMAGE}" ]]; then
    echo "Error: Specify only one of --device or --output, not both." >&2
    exit 1
fi

if [[ -n "${TARGET_DEVICE}" ]]; then
    TARGET_DEVICE="$(readlink -f "${TARGET_DEVICE}")"
    if [[ ! -b "${TARGET_DEVICE}" ]]; then
        echo "Error: '${TARGET_DEVICE}' is not a valid block device." >&2
        exit 1
    fi

    DEV_TYPE="$(lsblk -dn -o TYPE "${TARGET_DEVICE}" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${DEV_TYPE}" != "disk" ]]; then
        echo "Error: '${TARGET_DEVICE}' has type '${DEV_TYPE:-unknown}'; specify a whole-disk device (not a partition or virtual volume)." >&2
        exit 1
    fi

    # Prevent accidentally wiping a disk backing critical host mounts, swap, LVM, LUKS, or RAID
    while read -r node_type node_mnt; do
        case "${node_type}" in
            lvm|crypt|raid*|md)
                echo "Error: Refusing to write to '${TARGET_DEVICE}' because it contains active '${node_type}' storage." >&2
                exit 1
                ;;
        esac
        case "${node_mnt}" in
            /|/boot|/boot/*|/home|/home/*|/var|/var/*|/usr|/usr/*|/etc|/opt|/srv|\[SWAP\])
                echo "Error: Refusing to write to '${TARGET_DEVICE}' because it backs critical host mount '${node_mnt}'." >&2
                exit 1
                ;;
        esac
    done < <(lsblk -rn -o TYPE,MOUNTPOINT "${TARGET_DEVICE}")
else
    if [[ -b "${OUTPUT_IMAGE}" || -d "${OUTPUT_IMAGE}" ]]; then
        echo "Error: --output '${OUTPUT_IMAGE}' cannot be a block device or directory." >&2
        exit 1
    fi
fi

# Collect all unique SSH public keys from --ssh-key / ../homelabian/.env AND local ~/.ssh/*.pub folders
declare -a SSH_PUB_KEYS=()
add_ssh_pubkey() {
    local raw_key="${1%$'\r'}"
    [[ -z "${raw_key}" || "${raw_key}" =~ ^[[:space:]]*# ]] && return 0
    if [[ ! "${raw_key}" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+ ]]; then
        echo "Warning: Skipping invalid SSH public key line: ${raw_key}" >&2
        return 0
    fi
    # Compare key type + base64 blob (fields 1 and 2) to avoid duplicates even if comments differ
    local key_id
    key_id="$(awk '{print $1, $2}' <<< "${raw_key}")"
    local existing
    for existing in "${SSH_PUB_KEYS[@]:-}"; do
        if [[ "$(awk '{print $1, $2}' <<< "${existing}")" == "${key_id}" ]]; then
            return 0
        fi
    done
    SSH_PUB_KEYS+=("${raw_key}")
}

if [[ -n "${AUTHORIZED_SSH_PUB_KEY}" ]]; then
    if [[ -f "${AUTHORIZED_SSH_PUB_KEY}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            add_ssh_pubkey "${line}"
        done < "${AUTHORIZED_SSH_PUB_KEY}"
    else
        add_ssh_pubkey "${AUTHORIZED_SSH_PUB_KEY}"
    fi
fi

INVOKING_HOME="$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)"
for ssh_dir in "${INVOKING_HOME}/.ssh" "${HOME}/.ssh" "${REPO_ROOT}/.ssh" "${REPO_ROOT}/../.ssh"; do
    [[ -d "${ssh_dir}" ]] || continue
    for pub_file in "${ssh_dir}"/*.pub; do
        [[ -f "${pub_file}" ]] || continue
        while IFS= read -r line || [[ -n "${line}" ]]; do
            add_ssh_pubkey "${line}"
        done < "${pub_file}"
    done
done

if [[ "${#SSH_PUB_KEYS[@]}" -eq 0 ]]; then
    echo "Error: No valid SSH public key found. Provide one via --ssh-key, ~/.ssh/*.pub, or ../homelabian/.env." >&2
    exit 1
fi
echo "Collected ${#SSH_PUB_KEYS[@]} unique SSH public key(s) for ${NEW_USER}."
AUTHORIZED_SSH_PUB_KEY="$(printf '%s\n' "${SSH_PUB_KEYS[@]}")"

# Resolve password hash if not provided
if [[ -z "${NEW_USER_PASS_SHA}" ]]; then
    if [[ -f "${REPO_ROOT}/become.pass" ]]; then
        echo "Generating SHA-512 password hash from become.pass..."
        NEW_USER_PASS_SHA="$(tr -d '\r' < "${REPO_ROOT}/become.pass" | openssl passwd -6 -stdin)"
    else
        echo "Error: No password hash provided. Pass --password-hash or set NEW_USER_PASS_SHA in ../homelabian/.env." >&2
        exit 1
    fi
fi

NEW_USER_PASS_SHA="${NEW_USER_PASS_SHA%$'\r'}"
if [[ ! "${NEW_USER_PASS_SHA}" =~ ^\$[0-9a-zA-Z]+\$ ]]; then
    echo "Error: Invalid password hash format (expected crypt hash starting with '\$6\$' or similar)." >&2
    exit 1
fi

# Download Raspberry Pi OS Lite 64-bit if no local image was supplied
if [[ -z "${IMAGE_PATH}" ]]; then
    install -d -m 0755 -o 0 -g 0 "${CACHE_DIR}"
    IMAGE_PATH="${CACHE_IMAGE}"
    if [[ ! -f "${IMAGE_PATH}" ]]; then
        echo "Downloading official Raspberry Pi OS Lite (64-bit) to ${IMAGE_PATH}..."
        curl -fL "${RASPIOS_URL}" -o "${IMAGE_PATH}.part"
        mv "${IMAGE_PATH}.part" "${IMAGE_PATH}"
    else
        echo "Using cached Raspberry Pi OS image at ${IMAGE_PATH}"
    fi
fi

if [[ ! -f "${IMAGE_PATH}" ]]; then
    echo "Error: Image file '${IMAGE_PATH}' does not exist." >&2
    exit 1
fi

if [[ -n "${OUTPUT_IMAGE}" && -e "${OUTPUT_IMAGE}" ]] && [[ "$(readlink -f "${IMAGE_PATH}")" == "$(readlink -f "${OUTPUT_IMAGE}")" ]]; then
    echo "Error: --image and --output must not point to the same file." >&2
    exit 1
fi

if [[ "${IMAGE_PATH}" == *.xz ]]; then
    echo "Verifying xz archive integrity of ${IMAGE_PATH}..."
    xz -t "${IMAGE_PATH}"
fi

echo "=================================================================="
if [[ -n "${TARGET_DEVICE}" ]]; then
    echo "Target SD Card Device : ${TARGET_DEVICE}"
else
    echo "Output Image File     : ${OUTPUT_IMAGE}"
fi
echo "Source Image          : ${IMAGE_PATH}"
echo "Initial Hostname      : ${INIT_HOSTNAME}.local"
echo "Initial User          : ${NEW_USER}"
echo "=================================================================="

if [[ -n "${TARGET_DEVICE}" ]]; then
    lsblk -o NAME,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINT "${TARGET_DEVICE}"
    echo "=================================================================="
    if [[ "${ASSUME_YES}" != "true" ]]; then
        read -r -p "ALL DATA ON ${TARGET_DEVICE} WILL BE ERASED. Type 'YES' to continue: " confirm
        if [[ "${confirm}" != "YES" ]]; then
            echo "Aborted."
            exit 1
        fi
    fi

    echo "Unmounting any existing partitions on ${TARGET_DEVICE}..."
    while read -r dev_name; do
        [[ -z "${dev_name}" ]] && continue
        dev_path="/dev/${dev_name}"
        if findmnt -rn -S "${dev_path}" >/dev/null 2>&1; then
            umount "${dev_path}"
        fi
    done < <(lsblk -ln -o NAME "${TARGET_DEVICE}" | tail -n +2)

    if [[ -n "$(lsblk -no MOUNTPOINT "${TARGET_DEVICE}" | tr -d '[:space:]')" ]]; then
        echo "Error: Failed to unmount all partitions on ${TARGET_DEVICE}." >&2
        exit 1
    fi

    echo "Flashing ${IMAGE_PATH} to ${TARGET_DEVICE}..."
    if [[ "${IMAGE_PATH}" == *.xz ]]; then
        xz -dc "${IMAGE_PATH}" | dd of="${TARGET_DEVICE}" bs=4M conv=fsync status=progress
    else
        dd if="${IMAGE_PATH}" of="${TARGET_DEVICE}" bs=4M conv=fsync status=progress
    fi

    sync
    partprobe "${TARGET_DEVICE}" 2>/dev/null || blockdev --rereadpt "${TARGET_DEVICE}" 2>/dev/null || partx -u "${TARGET_DEVICE}" 2>/dev/null || true
    udevadm settle || sleep 2

    if [[ "${TARGET_DEVICE}" =~ [0-9]$ ]]; then
        BOOT_PART="${TARGET_DEVICE}p1"
        ROOT_PART="${TARGET_DEVICE}p2"
    else
        BOOT_PART="${TARGET_DEVICE}1"
        ROOT_PART="${TARGET_DEVICE}2"
    fi
else
    mkdir -p "$(dirname "${OUTPUT_IMAGE}")"
    echo "Writing base image to ${OUTPUT_IMAGE}..."
    if [[ "${IMAGE_PATH}" == *.xz ]]; then
        xz -dc "${IMAGE_PATH}" > "${OUTPUT_IMAGE}.part"
        mv -f "${OUTPUT_IMAGE}.part" "${OUTPUT_IMAGE}"
    else
        cp -f "${IMAGE_PATH}" "${OUTPUT_IMAGE}.part"
        mv -f "${OUTPUT_IMAGE}.part" "${OUTPUT_IMAGE}"
    fi
fi

LOOP_DEV=""
MNT_DIR="$(mktemp -d /tmp/rpi-sdcard.XXXXXX)"
BOOT_MNT="${MNT_DIR}/boot"
ROOT_MNT="${MNT_DIR}/root"
mkdir -p "${BOOT_MNT}" "${ROOT_MNT}"

cleanup() {
    sync
    if findmnt -rn -M "${BOOT_MNT}" >/dev/null 2>&1; then
        umount "${BOOT_MNT}" 2>/dev/null || true
    fi
    if findmnt -rn -M "${ROOT_MNT}" >/dev/null 2>&1; then
        umount "${ROOT_MNT}" 2>/dev/null || true
    fi
    if [[ -n "${LOOP_DEV}" ]]; then
        losetup -d "${LOOP_DEV}" 2>/dev/null || true
    fi
    rmdir "${BOOT_MNT}" "${ROOT_MNT}" "${MNT_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -n "${OUTPUT_IMAGE}" ]]; then
    LOOP_DEV="$(losetup --find --show --partscan "${OUTPUT_IMAGE}")"
    udevadm settle || sleep 1
    BOOT_PART="${LOOP_DEV}p1"
    ROOT_PART="${LOOP_DEV}p2"
fi

for _ in {1..10}; do
    [[ -b "${BOOT_PART}" && -b "${ROOT_PART}" ]] && break
    udevadm settle 2>/dev/null || true
    sleep 1
done

if [[ ! -b "${BOOT_PART}" || ! -b "${ROOT_PART}" ]]; then
    echo "Error: Partition device nodes (${BOOT_PART}, ${ROOT_PART}) did not appear." >&2
    exit 1
fi

echo "Mounting ${BOOT_PART} and ${ROOT_PART} for headless configuration..."
mount "${BOOT_PART}" "${BOOT_MNT}"
mount "${ROOT_PART}" "${ROOT_MNT}"

# 1. Enable SSH daemon on first boot
touch "${BOOT_MNT}/ssh"

# 2. Configure user and password hash via Raspberry Pi OS userconf.txt
printf '%s:%s\n' "${NEW_USER}" "${NEW_USER_PASS_SHA}" > "${BOOT_MNT}/userconf.txt"

# 3. Configure initial hostname so avahi advertises <hostname>.local
printf '%s\n' "${INIT_HOSTNAME}" > "${ROOT_MNT}/etc/hostname"
if grep -q '^127\.0\.1\.1' "${ROOT_MNT}/etc/hosts"; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${INIT_HOSTNAME}/" "${ROOT_MNT}/etc/hosts"
else
    printf '127.0.1.1\t%s\n' "${INIT_HOSTNAME}" >> "${ROOT_MNT}/etc/hosts"
fi

# 4. Install SSH public key in:
#    - /etc/ssh/authorized_keys/<user> owned by UID 1000 (satisfies OpenSSH StrictModes)
#    - /etc/skel/.ssh/authorized_keys (copied if userconf creates a new user)
#    - UID 1000's existing home directory (moved if userconf renames the default user)
install -d -m 0755 -o 0 -g 0 "${ROOT_MNT}/etc/ssh/authorized_keys"
printf '%s\n' "${AUTHORIZED_SSH_PUB_KEY}" > "${ROOT_MNT}/etc/ssh/authorized_keys/${NEW_USER}"
chown 1000:1000 "${ROOT_MNT}/etc/ssh/authorized_keys/${NEW_USER}"
chmod 0600 "${ROOT_MNT}/etc/ssh/authorized_keys/${NEW_USER}"

install -d -m 0755 -o 0 -g 0 "${ROOT_MNT}/etc/ssh/sshd_config.d"
cat > "${ROOT_MNT}/etc/ssh/sshd_config.d/20-homelabian-bootstrap.conf" <<EOF
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
EOF
chown 0:0 "${ROOT_MNT}/etc/ssh/sshd_config.d/20-homelabian-bootstrap.conf"
chmod 0644 "${ROOT_MNT}/etc/ssh/sshd_config.d/20-homelabian-bootstrap.conf"

install -d -m 0700 -o 0 -g 0 "${ROOT_MNT}/etc/skel/.ssh"
printf '%s\n' "${AUTHORIZED_SSH_PUB_KEY}" > "${ROOT_MNT}/etc/skel/.ssh/authorized_keys"
chmod 0600 "${ROOT_MNT}/etc/skel/.ssh/authorized_keys"

EXISTING_UID1000_HOME="$(awk -F: '$3 == 1000 {print $6; exit}' "${ROOT_MNT}/etc/passwd" || true)"
if [[ -n "${EXISTING_UID1000_HOME}" && -d "${ROOT_MNT}${EXISTING_UID1000_HOME}" ]]; then
    USER_HOME_DIR="${ROOT_MNT}${EXISTING_UID1000_HOME}"
    install -d -m 0700 -o 1000 -g 1000 "${USER_HOME_DIR}/.ssh"
    printf '%s\n' "${AUTHORIZED_SSH_PUB_KEY}" > "${USER_HOME_DIR}/.ssh/authorized_keys"
    chown 1000:1000 "${USER_HOME_DIR}/.ssh/authorized_keys"
    chmod 0600 "${USER_HOME_DIR}/.ssh/authorized_keys"
fi

sync
umount "${BOOT_MNT}"
umount "${ROOT_MNT}"
if [[ -n "${LOOP_DEV}" ]]; then
    losetup -d "${LOOP_DEV}"
    LOOP_DEV=""
fi

if [[ -n "${OUTPUT_IMAGE}" && -n "${SUDO_USER:-}" ]]; then
    chown "${SUDO_UID:-${SUDO_USER}}:${SUDO_GID:-$(id -gn "${SUDO_USER}")}" "${OUTPUT_IMAGE}" || true
fi

echo "Provisioning complete!"
if [[ -n "${OUTPUT_IMAGE}" ]]; then
    echo "Customized image saved to: ${OUTPUT_IMAGE}"
    echo "Flash this .img to your SD card on Windows (e.g. with BalenaEtcher, Rufus, or Raspberry Pi Imager with OS customization disabled)."
fi
echo "Once booted on the Raspberry Pi 3B, run:"
echo "  ansible-playbook playbooks/provision_pi3b.yml -e \"tailscale_authkey=\$(cat tailscale.pass)\""
