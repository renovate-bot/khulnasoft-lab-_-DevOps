#!/bin/sh

# SPDX-License-Identifier: GPL-3.0-or-later

# Next unused error code: I0012

export PATH="${PATH}:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
uniquepath() {
  path=""
  tmp="$(mktemp)"
  (echo  "${PATH}" | tr ":" "\n") > "$tmp"
  while read -r REPLY;
  do
    if echo "${path}" | grep -v "(^|:)${REPLY}(:|$)"; then
      [ -n "${path}" ] && path="${path}:"
      path="${path}${REPLY}"
    fi
  done < "$tmp"
rm "$tmp"
  [ -n "${path}" ]
export PATH="${path%:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin}"
} > /dev/null
uniquepath

PROGRAM="$0"
KHULNASOFT_SOURCE_DIR="$(pwd)"
INSTALLER_DIR="$(dirname "${PROGRAM}")"

if [ "${KHULNASOFT_SOURCE_DIR}" != "${INSTALLER_DIR}" ] && [ "${INSTALLER_DIR}" != "." ]; then
  echo >&2 "Warning: you are currently in '${KHULNASOFT_SOURCE_DIR}' but the installer is in '${INSTALLER_DIR}'."
fi

# -----------------------------------------------------------------------------
# reload the user profile

# shellcheck source=/dev/null
[ -f /etc/profile ] && . /etc/profile

# make sure /etc/profile does not change our current directory
cd "${KHULNASOFT_SOURCE_DIR}" || exit 1

# -----------------------------------------------------------------------------
# load the required functions

if [ -f "${INSTALLER_DIR}/packaging/installer/functions.sh" ]; then
  # shellcheck source=packaging/installer/functions.sh
  . "${INSTALLER_DIR}/packaging/installer/functions.sh" || exit 1
else
  # shellcheck source=packaging/installer/functions.sh
  . "${KHULNASOFT_SOURCE_DIR}/packaging/installer/functions.sh" || exit 1
fi

# Used to enable saved warnings support in functions.sh
# shellcheck disable=SC2034
KHULNASOFT_SAVE_WARNINGS=1

# -----------------------------------------------------------------------------
# figure out an appropriate temporary directory
_cannot_use_tmpdir() {
  testfile="$(TMPDIR="${1}" mktemp -q -t khulnasoft-lab-test.XXXXXXXXXX)"
  ret=0

  if [ -z "${testfile}" ]; then
    return "${ret}"
  fi

  if printf '#!/bin/sh\necho SUCCESS\n' > "${testfile}"; then
    if chmod +x "${testfile}"; then
      if [ "$("${testfile}")" = "SUCCESS" ]; then
        ret=1
      fi
    fi
  fi

  rm -f "${testfile}"
  return "${ret}"
}

if [ -z "${TMPDIR}" ] || _cannot_use_tmpdir "${TMPDIR}"; then
  if _cannot_use_tmpdir /tmp; then
    if _cannot_use_tmpdir "${PWD}"; then
      fatal "Unable to find a usable temporary directory. Please set \$TMPDIR to a path that is both writable and allows execution of files and try again." I0000
    else
      TMPDIR="${PWD}"
    fi
  else
    TMPDIR="/tmp"
  fi
fi

# -----------------------------------------------------------------------------
# set up handling for deferred error messages
#
# This leverages the saved warnings functionality shared with some functions from functions.sh

print_deferred_errors() {
  if [ -n "${SAVED_WARNINGS}" ]; then
    printf >&2 "\n"
    printf >&2 "%b\n" "The following warnings and non-fatal errors were encountered during the installation process:"
    printf >&2 "%b\n" "${SAVED_WARNINGS}"
    printf >&2 "\n"
  fi
}

download_go() {
  download_file "${1}" "${2}" "go.d plugin" "go"
}

# make sure we save all commands we run
# Variable is used by code in the packaging/installer/functions.sh
# shellcheck disable=SC2034
run_logfile="khulnasoft-lab-installer.log"


# -----------------------------------------------------------------------------
# fix PKG_CHECK_MODULES error

if [ -d /usr/share/aclocal ]; then
  ACLOCAL_PATH=${ACLOCAL_PATH-/usr/share/aclocal}
  export ACLOCAL_PATH
fi

export LC_ALL=C
umask 002

# Be nice on production environments
renice 19 $$ > /dev/null 2> /dev/null

# you can set CFLAGS before running installer
# shellcheck disable=SC2269
LDFLAGS="${LDFLAGS}"
CFLAGS="${CFLAGS-"-O2 -pipe"}"
[ "z${CFLAGS}" = "z-O3" ] && CFLAGS="-O2"
# shellcheck disable=SC2269
ACLK="${ACLK}"

# keep a log of this command
{
  printf "\n# "
  date
  printf 'CFLAGS="%s" ' "${CFLAGS}"
  printf 'LDFLAGS="%s" ' "${LDFLAGS}"
  printf "%s" "${PROGRAM}" "${@}"
  printf "\n"
} >> khulnasoft-lab-installer.log

REINSTALL_OPTIONS="$(
  printf "%s" "${*}"
  printf "\n"
)"
# remove options that shown not be inherited by khulnasoft-lab-updater.sh
REINSTALL_OPTIONS="$(echo "${REINSTALL_OPTIONS}" | sed 's/--dont-wait//g' | sed 's/--dont-start-it//g')"

banner_nonroot_install() {
  cat << NONROOTNOPREFIX

  ${TPUT_RED}${TPUT_BOLD}Sorry! This will fail!${TPUT_RESET}

  You are attempting to install khulnasoft-lab as a non-root user, but you plan
  to install it in system paths.

  Please set an installation prefix, like this:

      $PROGRAM ${@} --install-prefix /tmp

  or, run the installer as root:

      sudo $PROGRAM ${@}

  We suggest to install it as root, or certain data collectors will
  not be able to work. Khulnasoft-lab drops root privileges when running.
  So, if you plan to keep it, install it as root to get the full
  functionality.

NONROOTNOPREFIX
}

banner_root_notify() {
  cat << NONROOT

  ${TPUT_RED}${TPUT_BOLD}IMPORTANT${TPUT_RESET}:
  You are about to install khulnasoft-lab as a non-root user.
  Khulnasoft-lab will work, but a few data collection modules that
  require root access will fail.

  If you are installing khulnasoft-lab permanently on your system, run
  the installer like this:

     ${TPUT_YELLOW}${TPUT_BOLD}sudo $PROGRAM ${@}${TPUT_RESET}

NONROOT
}

usage() {
  khulnasoft-lab_banner
  progress "installer command line options"
  cat << HEREDOC

USAGE: ${PROGRAM} [options]
       where options include:

  --install-prefix <path>    Install khulnasoft-lab in <path>. Ex. --install-prefix /opt will put khulnasoft-lab in /opt/khulnasoft-lab.
  --dont-start-it            Do not (re)start khulnasoft-lab after installation.
  --dont-wait                Run installation in non-interactive mode.
  --stable-channel           Use packages from GitHub release pages instead of nightly updates.
                             This results in less frequent updates.
  --nightly-channel          Use most recent nightly updates instead of GitHub releases.
                             This results in more frequent updates.
  --disable-go               Disable installation of go.d.plugin.
  --disable-ebpf             Disable eBPF Kernel plugin. Default: enabled.
  --disable-cloud            Disable all Khulnasoft-lab Cloud functionality.
  --require-cloud            Fail the install if it can't build Khulnasoft-lab Cloud support.
  --enable-plugin-freeipmi   Enable the FreeIPMI plugin. Default: enable it when libipmimonitoring is available.
  --disable-plugin-freeipmi  Explicitly disable the FreeIPMI plugin.
  --disable-https            Explicitly disable TLS support.
  --disable-dbengine         Explicitly disable DB engine support.
  --enable-plugin-nfacct     Enable nfacct plugin. Default: enable it when libmnl and libnetfilter_acct are available.
  --disable-plugin-nfacct    Explicitly disable the nfacct plugin.
  --enable-plugin-xenstat    Enable the xenstat plugin. Default: enable it when libxenstat and libyajl are available.
  --disable-plugin-xenstat   Explicitly disable the xenstat plugin.
  --enable-plugin-systemd-journal Enable the the systemd journal plugin. Default: enable it when libsystemd is available.
  --disable-plugin-systemd-journal Explicitly disable the systemd journal plugin.
  --enable-exporting-kinesis Enable AWS Kinesis exporting connector. Default: enable it when libaws_cpp_sdk_kinesis
                             and its dependencies are available.
  --disable-exporting-kinesis Explicitly disable AWS Kinesis exporting connector.
  --enable-exporting-prometheus-remote-write Enable Prometheus remote write exporting connector. Default: enable it
                             when libprotobuf and libsnappy are available.
  --disable-exporting-prometheus-remote-write Explicitly disable Prometheus remote write exporting connector.
  --enable-exporting-mongodb Enable MongoDB exporting connector. Default: enable it when libmongoc is available.
  --disable-exporting-mongodb Explicitly disable MongoDB exporting connector.
  --enable-exporting-pubsub  Enable Google Cloud PubSub exporting connector. Default: enable it when
                             libgoogle_cloud_cpp_pubsub_protos and its dependencies are available.
  --disable-exporting-pubsub Explicitly disable Google Cloud PubSub exporting connector.
  --enable-lto               Enable link-time optimization. Default: disabled.
  --disable-lto              Explicitly disable link-time optimization.
  --enable-ml                Enable anomaly detection with machine learning. Default: autodetect.
  --disable-ml               Explicitly disable anomaly detection with machine learning.
  --disable-x86-sse          Disable SSE instructions & optimizations. Default: enabled.
  --use-system-protobuf      Use a system copy of libprotobuf instead of bundled copy. Default: bundled.
  --zlib-is-really-here
  --libs-are-really-here     If you see errors about missing zlib or libuuid but you know it is available, you might
                             have a broken pkg-config. Use this option to proceed without checking pkg-config.
  --disable-telemetry        Opt-out from our anonymous telemetry program. (DISABLE_TELEMETRY=1)
  --skip-available-ram-check Skip checking the amount of RAM the system has and pretend it has enough to build safely.
  --disable-logsmanagement   Disable the logs management plugin. Default: autodetect.
  --enable-logsmanagement-tests Enable the logs management tests. Default: disabled.

Khulnasoft-lab will by default be compiled with gcc optimization -O2
If you need to pass different CFLAGS, use something like this:

  CFLAGS="<gcc options>" ${PROGRAM} [options]

If you also need to provide different LDFLAGS, use something like this:

  LDFLAGS="<extra ldflag options>" ${PROGRAM} [options]

or use the following if both LDFLAGS and CFLAGS need to be overridden:

  CFLAGS="<gcc options>" LDFLAGS="<extra ld options>" ${PROGRAM} [options]

For the installer to complete successfully, you will need these packages installed:

  gcc
  make
  autoconf
  automake
  pkg-config
  zlib1g-dev (or zlib-devel)
  uuid-dev (or libuuid-devel)

For the plugins, you will at least need:

  curl
  bash (v4+)
  python (v2 or v3)
  node.js

HEREDOC
}

DONOTSTART=0
DONOTWAIT=0
KHULNASOFT_PREFIX=
LIBS_ARE_HERE=0
KHULNASOFT_ENABLE_ML=""
ENABLE_DBENGINE=1
ENABLE_EBPF=1
ENABLE_H2O=1
ENABLE_CLOUD=1
ENABLE_LOGS_MANAGEMENT=1
ENABLE_LOGS_MANAGEMENT_TESTS=0
KHULNASOFT_CMAKE_OPTIONS="${KHULNASOFT_CMAKE_OPTIONS-}"

RELEASE_CHANNEL="nightly" # valid values are 'nightly' and 'stable'
IS_KHULNASOFT_STATIC_BINARY="${IS_KHULNASOFT_STATIC_BINARY:-"no"}"
while [ -n "${1}" ]; do
  case "${1}" in
    "--zlib-is-really-here") LIBS_ARE_HERE=1 ;;
    "--libs-are-really-here") LIBS_ARE_HERE=1 ;;
    "--use-system-protobuf") USE_SYSTEM_PROTOBUF=1 ;;
    "--dont-scrub-cflags-even-though-it-may-break-things") DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS=1 ;;
    "--dont-start-it") DONOTSTART=1 ;;
    "--dont-wait") DONOTWAIT=1 ;;
    "--auto-update" | "-u") ;;
    "--auto-update-type") ;;
    "--stable-channel") RELEASE_CHANNEL="stable" ;;
    "--nightly-channel") RELEASE_CHANNEL="nightly" ;;
    "--enable-plugin-freeipmi") ENABLE_FREEIPMI=1 ;;
    "--disable-plugin-freeipmi") ENABLE_FREEIPMI=0 ;;
    "--disable-https")
      ENABLE_DBENGINE=0
      ENABLE_H2O=0
      ENABLE_CLOUD=0
      ;;
    "--disable-dbengine") ENABLE_DBENGINE=0 ;;
    "--enable-plugin-nfacct") ENABLE_NFACCT=1 ;;
    "--disable-plugin-nfacct") ENABLE_NFACCT=0 ;;
    "--enable-plugin-xenstat") ENABLE_XENSTAT=1 ;;
    "--disable-plugin-xenstat") ENABLE_XENSTAT=0 ;;
    "--enable-plugin-systemd-journal") ENABLE_SYSTEMD_JOURNAL=1 ;;
    "--disable-plugin-systemd-journal") ENABLE_SYSTEMD_JOURNAL=0 ;;
    "--enable-exporting-kinesis" | "--enable-backend-kinesis")
      # TODO: Needs CMake Support
      ;;
    "--disable-exporting-kinesis" | "--disable-backend-kinesis")
      # TODO: Needs CMake Support
      ;;
    "--enable-exporting-prometheus-remote-write" | "--enable-backend-prometheus-remote-write") EXPORTER_PROMETHEUS=1 ;;
    "--disable-exporting-prometheus-remote-write" | "--disable-backend-prometheus-remote-write") EXPORTER_PROMETHEUS=0 ;;
    "--enable-exporting-mongodb" | "--enable-backend-mongodb") EXPORTER_MONGODB=1 ;;
    "--disable-exporting-mongodb" | "--disable-backend-mongodb") EXPORTER_MONGODB=0 ;;
    "--enable-exporting-pubsub")
      # TODO: Needs CMake support
      ;;
    "--disable-exporting-pubsub")
      # TODO: Needs CMake support
      ;;
    "--enable-ml") KHULNASOFT_ENABLE_ML=1 ;;
    "--disable-ml") KHULNASOFT_ENABLE_ML=0 ;;
    "--enable-lto")
      # TODO: Needs CMake support
      ;;
    "--enable-logs-management") ENABLE_LOGS_MANAGEMENT=1 ;;
    "--disable-logsmanagement") ENABLE_LOGS_MANAGEMENT=0 ;;
    "--enable-logsmanagement-tests") ENABLE_LOGS_MANAGEMENT_TESTS=1 ;;
    "--disable-lto")
      # TODO: Needs CMake support
      ;;
    "--disable-x86-sse")
      # XXX: No longer supported.
      ;;
    "--disable-telemetry") KHULNASOFT_DISABLE_TELEMETRY=1 ;;
    "--disable-go") KHULNASOFT_DISABLE_GO=1 ;;
    "--enable-ebpf")
      ENABLE_EBPF=1
      KHULNASOFT_DISABLE_EBPF=0
      ;;
    "--disable-ebpf")
      ENABLE_EBPF=0
      KHULNASOFT_DISABLE_EBPF=1
      ;;
    "--skip-available-ram-check") SKIP_RAM_CHECK=1 ;;
    "--one-time-build")
      # XXX: No longer supported
      ;;
    "--disable-cloud")
      if [ -n "${KHULNASOFT_REQUIRE_CLOUD}" ]; then
        warning "Cloud explicitly enabled, ignoring --disable-cloud."
      else
        ENABLE_CLOUD=0
        KHULNASOFT_DISABLE_CLOUD=1
      fi
      ;;
    "--require-cloud")
      if [ -n "${KHULNASOFT_DISABLE_CLOUD}" ]; then
        warning "Cloud explicitly disabled, ignoring --require-cloud."
      else
        ENABLE_CLOUD=1
        KHULNASOFT_REQUIRE_CLOUD=1
      fi
      ;;
    "--build-json-c")
      KHULNASOFT_BUILD_JSON_C=1
      ;;
    "--install-prefix")
      KHULNASOFT_PREFIX="${2}/khulnasoft-lab"
      shift 1
      ;;
    "--install-no-prefix")
      KHULNASOFT_PREFIX="${2}"
      shift 1
      ;;
    "--prepare-only")
      KHULNASOFT_DISABLE_TELEMETRY=1
      KHULNASOFT_PREPARE_ONLY=1
      DONOTWAIT=1
      ;;
    "--help" | "-h")
      usage
      exit 1
      ;;
    *)
      echo >&2 "Unrecognized option '${1}'."
      exit_reason "Unrecognized option '${1}'." I000E
      usage
      exit 1
      ;;
  esac
  shift 1
done

if [ ! "${DISABLE_TELEMETRY:-0}" -eq 0 ] ||
  [ -n "$DISABLE_TELEMETRY" ] ||
  [ ! "${DO_NOT_TRACK:-0}" -eq 0 ] ||
  [ -n "$DO_NOT_TRACK" ]; then
  KHULNASOFT_DISABLE_TELEMETRY=1
fi

if [ -n "${MAKEOPTS}" ]; then
  JOBS="$(echo "${MAKEOPTS}" | grep -oE '\-j *[[:digit:]]+' | tr -d '\-j ')"
else
  JOBS="$(find_processors)"
fi

if [ "$(uname -s)" = "Linux" ] && [ -f /proc/meminfo ]; then
  mega="$((1024 * 1024))"
  base=1024
  scale=256

  target_ram="$((base * mega + (scale * mega * (JOBS - 1))))"
  total_ram="$(grep MemTotal /proc/meminfo | cut -d ':' -f 2 | tr -d ' kB')"
  total_ram="$((total_ram * 1024))"

  if [ "${total_ram}" -le "$((base * mega))" ] && [ -z "${KHULNASOFT_ENABLE_ML}" ]; then
    KHULNASOFT_ENABLE_ML=0
  fi

  if [ -z "${MAKEOPTS}" ]; then
    MAKEOPTS="-j${JOBS}"

    while [ "${target_ram}" -gt "${total_ram}" ] && [ "${JOBS}" -gt 1 ]; do
      JOBS="$((JOBS - 1))"
      target_ram="$((base * mega + (scale * mega * (JOBS - 1))))"
      MAKEOPTS="-j${JOBS}"
    done
  else
    if [ "${target_ram}" -gt "${total_ram}" ] && [ "${JOBS}" -gt 1 ] && [ -z "${SKIP_RAM_CHECK}" ]; then
      target_ram="$(echo "${target_ram}" | awk '{$1/=1024*1024*1024;printf "%.2fGiB\n",$1}')"
      total_ram="$(echo "${total_ram}" | awk '{$1/=1024*1024*1024;printf "%.2fGiB\n",$1}')"
      run_failed "Khulnasoft-lab needs ${target_ram} of RAM to safely install, but this system only has ${total_ram}. Try reducing the number of processes used for the install using the \$MAKEOPTS variable."
      exit_reason "Insufficient RAM to safely install." I000F
      exit 2
    fi
  fi
fi

enable_feature() {
  KHULNASOFT_CMAKE_OPTIONS="$(echo "${KHULNASOFT_CMAKE_OPTIONS}" | sed -e "s/-DENABLE_${1}=Off[[:space:]]*//g" -e "s/-DENABLE_${1}=On[[:space:]]*//g")"
  if [ "${2}" -eq 1 ]; then
    KHULNASOFT_CMAKE_OPTIONS="$(echo "${KHULNASOFT_CMAKE_OPTIONS}" | sed "s/$/ -DENABLE_${1}=On/")"
  else
    KHULNASOFT_CMAKE_OPTIONS="$(echo "${KHULNASOFT_CMAKE_OPTIONS}" | sed "s/$/ -DENABLE_${1}=Off/")"
  fi
}

# set default make options
if [ -z "${MAKEOPTS}" ]; then
  MAKEOPTS="-j$(find_processors)"
elif echo "${MAKEOPTS}" | grep -vqF -e "-j"; then
  MAKEOPTS="${MAKEOPTS} -j$(find_processors)"
fi

if [ "$(id -u)" -ne 0 ] && [ -z "${KHULNASOFT_PREPARE_ONLY}" ]; then
  if [ -z "${KHULNASOFT_PREFIX}" ]; then
    khulnasoft-lab_banner
    banner_nonroot_install "${@}"
    exit_reason "Attempted install as non-root user to /." I0010
    exit 1
  else
    banner_root_notify "${@}"
  fi
fi

khulnasoft-lab_banner
progress "real-time performance monitoring, done right!"
cat << BANNER1

  You are about to build and install khulnasoft-lab to your system.

  The build process will use ${TPUT_CYAN}${TMPDIR}${TPUT_RESET} for
  any temporary files. You can override this by setting \$TMPDIR to a
  writable directory where you can execute files.

  It will be installed at these locations:

   - the daemon     at ${TPUT_CYAN}${KHULNASOFT_PREFIX}/usr/sbin/khulnasoft-lab${TPUT_RESET}
   - config files   in ${TPUT_CYAN}${KHULNASOFT_PREFIX}/etc/khulnasoft-lab${TPUT_RESET}
   - web files      in ${TPUT_CYAN}${KHULNASOFT_PREFIX}/usr/share/khulnasoft-lab${TPUT_RESET}
   - plugins        in ${TPUT_CYAN}${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab${TPUT_RESET}
   - cache files    in ${TPUT_CYAN}${KHULNASOFT_PREFIX}/var/cache/khulnasoft-lab${TPUT_RESET}
   - db files       in ${TPUT_CYAN}${KHULNASOFT_PREFIX}/var/lib/khulnasoft-lab${TPUT_RESET}
   - log files      in ${TPUT_CYAN}${KHULNASOFT_PREFIX}/var/log/khulnasoft-lab${TPUT_RESET}
BANNER1

[ "$(id -u)" -eq 0 ] && cat << BANNER2
   - pid file       at ${TPUT_CYAN}${KHULNASOFT_PREFIX}/var/run/khulnasoft-lab.pid${TPUT_RESET}
   - logrotate file at ${TPUT_CYAN}/etc/logrotate.d/khulnasoft-lab${TPUT_RESET}
BANNER2

cat << BANNER3

  This installer allows you to change the installation path.
  Press Control-C and run the same command with --help for help.

BANNER3

if [ -z "$KHULNASOFT_DISABLE_TELEMETRY" ]; then
  cat << BANNER4

  ${TPUT_YELLOW}${TPUT_BOLD}NOTE${TPUT_RESET}:
  Anonymous usage stats will be collected and sent to Khulnasoft-lab.
  To opt-out, pass --disable-telemetry option to the installer or export
  the environment variable DISABLE_TELEMETRY to a non-zero or non-empty value
  (e.g: export DISABLE_TELEMETRY=1).

BANNER4
fi

if ! command -v cmake >/dev/null 2>&1; then
    fatal "Could not find CMake, which is required to build Khulnasoft-lab." I0012
else
    cmake="$(command -v cmake)"
    progress "Found CMake at ${cmake}. CMake version: $(${cmake} --version | head -n 1)"
fi

if ! command -v "ninja" >/dev/null 2>&1; then
    progress "Could not find Ninja, will use Make instead."
else
    ninja="$(command -v ninja)"
    progress "Found Ninja at ${ninja}. Ninja version: $(${ninja} --version)"
    progress "Will use Ninja for this build instead of Make when possible."
fi

make="$(command -v make 2>/dev/null)"

if [ -z "${make}" ] && [ -z "${ninja}" ]; then
    fatal "Could not find a usable underlying build system (we support make and ninja)." I0014
fi

CMAKE_OPTS="${ninja:+-G Ninja}"
BUILD_OPTS="VERBOSE=1"
[ -n "${ninja}" ] && BUILD_OPTS="-v"

if [ ${DONOTWAIT} -eq 0 ]; then
  if [ -n "${KHULNASOFT_PREFIX}" ]; then
    printf '%s' "${TPUT_BOLD}${TPUT_GREEN}Press ENTER to build and install khulnasoft-lab to '${TPUT_CYAN}${KHULNASOFT_PREFIX}${TPUT_YELLOW}'${TPUT_RESET} > "
  else
    printf '%s' "${TPUT_BOLD}${TPUT_GREEN}Press ENTER to build and install khulnasoft-lab to your system${TPUT_RESET} > "
  fi
  read -r REPLY
  if [ "$REPLY" != '' ]; then
    exit_reason "User did not accept install attempt." I0011
    exit 1
  fi

fi

cmake_install() {
    # run cmake --install ${1}
    # The above command should be used to replace the logic below once we no longer support
    # versions of CMake less than 3.15.
    if [ -n "${ninja}" ]; then
        run ${ninja} -C "${1}" install
    else
        run ${make} -C "${1}" install
    fi
}

build_error() {
  khulnasoft-lab_banner
  trap - EXIT
  fatal "Khulnasoft-lab failed to build for an unknown reason." I0002
}

if [ ${LIBS_ARE_HERE} -eq 1 ]; then
  shift
  echo >&2 "ok, assuming libs are really installed."
  export ZLIB_CFLAGS=" "
  export ZLIB_LIBS="-lz"
  export UUID_CFLAGS=" "
  export UUID_LIBS="-luuid"
fi

trap build_error EXIT

# -----------------------------------------------------------------------------
build_protobuf() {
  env_cmd=''

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS='-fPIC -pipe' CXXFLAGS='-fPIC -pipe' LDFLAGS="
  fi

  cd "${1}" > /dev/null || return 1
  if ! run eval "${env_cmd} ./configure --disable-shared --without-zlib --disable-dependency-tracking --with-pic"; then
    cd - > /dev/null || return 1
    return 1
  fi

  if ! run eval "${env_cmd} ${make} ${MAKEOPTS}"; then
    cd - > /dev/null || return 1
    return 1
  fi

  cd - > /dev/null || return 1
}

copy_protobuf() {
  target_dir="${PWD}/externaldeps/protobuf"

  run mkdir -p "${target_dir}" || return 1
  run cp -a "${1}/src" "${target_dir}" || return 1
}

bundle_protobuf() {
  if [ -n "${KHULNASOFT_DISABLE_CLOUD}" ] && [ -n "${EXPORTER_PROMETHEUS}" ] && [ "${EXPORTER_PROMETHEUS}" -eq 0 ]; then
    echo "Skipping protobuf"
    return 0
  fi

  if [ -n "${USE_SYSTEM_PROTOBUF}" ]; then
    echo "Skipping protobuf"
    warning "You have requested use of a system copy of protobuf. This should work, but it is not recommended as it's very likely to break if you upgrade the currently installed version of protobuf."
    return 0
  fi

  if [ -z "${make}" ]; then
    warning "No usable copy of Make found, which is required for bundling protobuf. Attempting to use a system copy of protobuf instead."
    USE_SYSTEM_PROTOBUF=1
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Bundling protobuf."

  PROTOBUF_PACKAGE_VERSION="$(cat packaging/protobuf.version)"

  if [ -f "${PWD}/externaldeps/protobuf/.version" ] && [ "${PROTOBUF_PACKAGE_VERSION}" = "$(cat "${PWD}/externaldeps/protobuf/.version")" ]
  then
    echo >&2 "Found compiled protobuf, same version, not compiling it again. Remove file '${PWD}/externaldeps/protobuf/.version' to recompile."
    USE_SYSTEM_PROTOBUF=0
    return 0
  fi

  tmp="$(mktemp -d -t khulnasoft-lab-protobuf-XXXXXX)"
  PROTOBUF_PACKAGE_BASENAME="protobuf-cpp-${PROTOBUF_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "protobuf" \
    "https://github.com/protocolbuffers/protobuf/releases/download/v${PROTOBUF_PACKAGE_VERSION}/${PROTOBUF_PACKAGE_BASENAME}" \
    "${PROTOBUF_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${KHULNASOFT_LOCAL_TARBALL_VERRIDE_PROTOBUF}"; then
    if run tar --no-same-owner -xf "${tmp}/${PROTOBUF_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_protobuf "${tmp}/protobuf-${PROTOBUF_PACKAGE_VERSION}" &&
      copy_protobuf "${tmp}/protobuf-${PROTOBUF_PACKAGE_VERSION}" &&
      echo "${PROTOBUF_PACKAGE_VERSION}" >"${PWD}/externaldeps/protobuf/.version" &&
      rm -rf "${tmp}"; then
      run_ok "protobuf built and prepared."
      USE_SYSTEM_PROTOBUF=0
    else
      run_failed "Failed to build protobuf. Khulnasoft-lab Cloud support will not be available in this build."
    fi
  else
    run_failed "Unable to fetch sources for protobuf. Khulnasoft-lab Cloud support will not be available in this build."
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

bundle_protobuf

# -----------------------------------------------------------------------------
build_jsonc() {
  env_cmd=''

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS='-fPIC -pipe' CXXFLAGS='-fPIC -pipe' LDFLAGS="
  fi

  cd "${1}" > /dev/null || exit 1
  run eval "${env_cmd} ${cmake} ${CMAKE_OPTS} -DBUILD_SHARED_LIBS=OFF -DDISABLE_WERROR=On ."
  run eval "${env_cmd} ${cmake} --build . --parallel ${JOBS} -- ${BUILD_OPTS}"
  cd - > /dev/null || return 1
}

copy_jsonc() {
  target_dir="${PWD}/externaldeps/jsonc"

  run mkdir -p "${target_dir}" "${target_dir}/json-c" || return 1

  run cp "${1}/libjson-c.a" "${target_dir}/libjson-c.a" || return 1
  # shellcheck disable=SC2086
  run cp ${1}/*.h "${target_dir}/json-c" || return 1
}

bundle_jsonc() {
  # If --build-json-c flag or not json-c on system, then bundle our own json-c
  if [ -z "${KHULNASOFT_BUILD_JSON_C}" ] && pkg-config json-c; then
    KHULNASOFT_BUILD_JSON_C=0
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Bundling JSON-C."

  progress "Prepare JSON-C"

  JSONC_PACKAGE_VERSION="$(cat packaging/jsonc.version)"

  tmp="$(mktemp -d -t khulnasoft-lab-jsonc-XXXXXX)"
  JSONC_PACKAGE_BASENAME="json-c-${JSONC_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "jsonc" \
    "https://github.com/json-c/json-c/archive/${JSONC_PACKAGE_BASENAME}" \
    "${JSONC_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_JSONC}"; then
    if run tar --no-same-owner -xf "${tmp}/${JSONC_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_jsonc "${tmp}/json-c-json-c-${JSONC_PACKAGE_VERSION}" &&
      copy_jsonc "${tmp}/json-c-json-c-${JSONC_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "JSON-C built and prepared."
      KHULNASOFT_BUILD_JSON_C=1
    else
      run_failed "Failed to build JSON-C, Khulnasoft-lab Cloud support will be disabled in this build."
      KHULNASOFT_BUILD_JSON_C=0
      ENABLE_CLOUD=0
    fi
  else
    run_failed "Unable to fetch sources for JSON-C, Khulnasoft-lab Cloud support will be disabled in this build."
    KHULNASOFT_BUILD_JSON_C=0
    ENABLE_CLOUD=0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

bundle_jsonc

# -----------------------------------------------------------------------------
build_yaml() {
  env_cmd=''

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS='-fPIC -pipe -Wno-unused-value' CXXFLAGS='-fPIC -pipe' LDFLAGS="
  fi

  cd "${1}" > /dev/null || return 1
  run eval "${env_cmd} ./configure --disable-shared --disable-dependency-tracking --with-pic"
  run eval "${env_cmd} ${make} ${MAKEOPTS}"
  cd - > /dev/null || return 1
}

copy_yaml() {
  target_dir="${PWD}/externaldeps/libyaml"

  run mkdir -p "${target_dir}" || return 1

  run cp "${1}/src/.libs/libyaml.a" "${target_dir}/libyaml.a" || return 1
  run cp "${1}/include/yaml.h" "${target_dir}/" || return 1
}

bundle_yaml() {
  if pkg-config yaml-0.1; then
    BUNDLE_YAML=0
    return 0
  fi

  if [ -z "${make}" ]; then
    fatal "Need to bundle libyaml but cannot find a copy of Make to build it with. Either install development files for libyaml, or install a usable copy fo Make." I0016
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Bundling YAML."

  progress "Prepare YAML"

  YAML_PACKAGE_VERSION="$(cat packaging/yaml.version)"

  tmp="$(mktemp -d -t khulnasoft-lab-yaml-XXXXXX)"
  YAML_PACKAGE_BASENAME="yaml-${YAML_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "yaml" \
    "https://github.com/yaml/libyaml/releases/download/${YAML_PACKAGE_VERSION}/${YAML_PACKAGE_BASENAME}" \
    "${YAML_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_YAML}"; then
    if run tar --no-same-owner -xf "${tmp}/${YAML_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_yaml "${tmp}/yaml-${YAML_PACKAGE_VERSION}" &&
      copy_yaml "${tmp}/yaml-${YAML_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "YAML built and prepared."
      BUNDLE_YAML=1
    else
      run_failed "Failed to build YAML, critical error."
      BUNDLE_YAML=0
    fi
  else
    run_failed "Unable to fetch sources for YAML, critical error."
    BUNDLE_YAML=0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

bundle_yaml

# -----------------------------------------------------------------------------

get_kernel_version() {
  r="$(uname -r | cut -f 1 -d '-')"

  tmpfile="$(mktemp)"
  echo "${r}" | tr '.' ' ' > "${tmpfile}"

  read -r maj min patch _ < "${tmpfile}"

  rm -f "${tmpfile}"

  printf "%03d%03d%03d" "${maj}" "${min}" "${patch}"
}

detect_libc() {
  libc=
  if ldd --version 2>&1 | grep -q -i glibc; then
    echo >&2 " Detected GLIBC"
    libc="glibc"
  elif ldd --version 2>&1 | grep -q -i 'gnu libc'; then
    echo >&2 " Detected GLIBC"
    libc="glibc"
  elif ldd --version 2>&1 | grep -q -i musl; then
    echo >&2 " Detected musl"
    libc="musl"
  else
      cmd=$(ldd /bin/sh | grep -w libc | cut -d" " -f 3)
      if bash -c "${cmd}" 2>&1 | grep -q -i "GNU C Library"; then
        echo >&2 " Detected GLIBC"
        libc="glibc"
      fi
  fi

  if [ -z "$libc" ]; then
    warning "Cannot detect a supported libc on your system, eBPF support will be disabled."
    return 1
  fi

  echo "${libc}"
  return 0
}

build_libbpf() {
  cd "${1}/src" > /dev/null || return 1
  mkdir root build
  # shellcheck disable=SC2086
  run env CFLAGS='-fPIC -pipe' CXXFLAGS='-fPIC -pipe' LDFLAGS= BUILD_STATIC_ONLY=y OBJDIR=build DESTDIR=.. ${make} ${MAKEOPTS} install
  cd - > /dev/null || return 1
}

copy_libbpf() {
  target_dir="${PWD}/externaldeps/libbpf"

  if [ "$(uname -m)" = x86_64 ]; then
    lib_subdir="lib64"
  else
    lib_subdir="lib"
  fi

  run mkdir -p "${target_dir}" || return 1

  run cp "${1}/usr/${lib_subdir}/libbpf.a" "${target_dir}/libbpf.a" || return 1
  run cp -r "${1}/usr/include" "${target_dir}" || return 1
  run cp -r "${1}/include/uapi" "${target_dir}/include" || return 1
}

bundle_libbpf() {
  if { [ -n "${KHULNASOFT_DISABLE_EBPF}" ] && [ "${KHULNASOFT_DISABLE_EBPF}" = 1 ]; } || [ "$(uname -s)" != Linux ]; then
    ENABLE_EBPF=0
    KHULNASOFT_DISABLE_EBPF=1
    return 0
  fi

  if [ -z "${make}" ]; then
    warning "No usable copy of Make found, which is required to bundle libbpf. Disabling eBPF support."
    ENABLE_EBPF=0
    KHULNASOFT_DISABLE_EBPF=1
    return 0
  fi

  # When libc is not detected, we do not have necessity to compile libbpf and we should not do download of eBPF programs
  libc="${EBPF_LIBC:-"$(detect_libc)"}"
  if [ -z "$libc" ]; then
    KHULNASOFT_DISABLE_EBPF=1
    ENABLE_EBPF=0
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Bundling libbpf."

  progress "Prepare libbpf"

  if [ "$(get_kernel_version)" -ge "004014000" ]; then
    LIBBPF_PACKAGE_VERSION="$(cat packaging/current_libbpf.version)"
    LIBBPF_PACKAGE_COMPONENT="current_libbpf"
  else
    LIBBPF_PACKAGE_VERSION="$(cat packaging/libbpf_0_0_9.version)"
    LIBBPF_PACKAGE_COMPONENT="libbpf_0_0_9"
  fi

  tmp="$(mktemp -d -t khulnasoft-lab-libbpf-XXXXXX)"
  LIBBPF_PACKAGE_BASENAME="v${LIBBPF_PACKAGE_VERSION}.tar.gz"

  if fetch_and_verify "${LIBBPF_PACKAGE_COMPONENT}" \
    "https://github.com/khulnasoft-lab/libbpf/archive/${LIBBPF_PACKAGE_BASENAME}" \
    "${LIBBPF_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_LIBBPF}"; then
    if run tar --no-same-owner -xf "${tmp}/${LIBBPF_PACKAGE_BASENAME}" -C "${tmp}" &&
      build_libbpf "${tmp}/libbpf-${LIBBPF_PACKAGE_VERSION}" &&
      copy_libbpf "${tmp}/libbpf-${LIBBPF_PACKAGE_VERSION}" &&
      rm -rf "${tmp}"; then
      run_ok "libbpf built and prepared."
      ENABLE_EBPF=1
    else
      if [ -n "${KHULNASOFT_DISABLE_EBPF}" ] && [ "${KHULNASOFT_DISABLE_EBPF}" = 0 ]; then
        fatal "failed to build libbpf." I0005
      else
        run_failed "Failed to build libbpf. eBPF support will be disabled"
        ENABLE_EBPF=0
        KHULNASOFT_DISABLE_EBPF=1
      fi
    fi
  else
    if [ -n "${KHULNASOFT_DISABLE_EBPF}" ] && [ "${KHULNASOFT_DISABLE_EBPF}" = 0 ]; then
      fatal "Failed to fetch sources for libbpf." I0006
    else
      run_failed "Unable to fetch sources for libbpf. eBPF support will be disabled"
      ENABLE_EBPF=0
      KHULNASOFT_DISABLE_EBPF=1
    fi
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

bundle_libbpf

copy_co_re() {
  cp -R "${1}/includes" "collectors/ebpf.plugin/"
}

bundle_ebpf_co_re() {
  if { [ -n "${KHULNASOFT_DISABLE_EBPF}" ] && [ "${KHULNASOFT_DISABLE_EBPF}" = 1 ]; } || [ "$(uname -s)" != Linux ]; then
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Bundling libbpf."

  progress "eBPF CO-RE"

  CORE_PACKAGE_VERSION="$(cat packaging/ebpf-co-re.version)"

  tmp="$(mktemp -d -t khulnasoft-lab-ebpf-co-re-XXXXXX)"
  CORE_PACKAGE_BASENAME="khulnasoft-lab-ebpf-co-re-glibc-${CORE_PACKAGE_VERSION}.tar.xz"

  if fetch_and_verify "ebpf-co-re" \
    "https://github.com/khulnasoft-lab/ebpf-co-re/releases/download/${CORE_PACKAGE_VERSION}/${CORE_PACKAGE_BASENAME}" \
    "${CORE_PACKAGE_BASENAME}" \
    "${tmp}" \
    "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_CORE}"; then
    if run tar --no-same-owner -xf "${tmp}/${CORE_PACKAGE_BASENAME}" -C "${tmp}" &&
      copy_co_re "${tmp}" &&
      rm -rf "${tmp}"; then
      run_ok "libbpf built and prepared."
      ENABLE_EBPF=1
    else
      if [ -n "${KHULNASOFT_DISABLE_EBPF}" ] && [ "${KHULNASOFT_DISABLE_EBPF}" = 0 ]; then
        fatal "Failed to get eBPF CO-RE files." I0007
      else
        run_failed "Failed to get eBPF CO-RE files. eBPF support will be disabled"
        KHULNASOFT_DISABLE_EBPF=1
        ENABLE_EBPF=0
        enable_feature PLUGIN_EBPF 0
      fi
    fi
  else
    if [ -n "${KHULNASOFT_DISABLE_EBPF}" ] && [ "${KHULNASOFT_DISABLE_EBPF}" = 0 ]; then
      fatal "Failed to fetch eBPF CO-RE files." I0008
    else
      run_failed "Failed to fetch eBPF CO-RE files. eBPF support will be disabled"
      KHULNASOFT_DISABLE_EBPF=1
      ENABLE_EBPF=0
      enable_feature PLUGIN_EBPF 0
    fi
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

bundle_ebpf_co_re

# -----------------------------------------------------------------------------
build_fluentbit() {
  env_cmd="env CFLAGS='-w' CXXFLAGS='-w' LDFLAGS="

  if [ -z "${DONT_SCRUB_CFLAGS_EVEN_THOUGH_IT_MAY_BREAK_THINGS}" ]; then
    env_cmd="env CFLAGS='-fPIC -pipe -w' CXXFLAGS='-fPIC -pipe -w' LDFLAGS="
  fi

  mkdir -p fluent-bit/build || return 1
  cd fluent-bit/build > /dev/null || return 1

  rm CMakeCache.txt > /dev/null 2>&1

  if ! run eval "${env_cmd} $1 -C ../../logsmanagement/fluent_bit_build/config.cmake -B./ -S../"; then
    cd - > /dev/null || return 1
    rm -rf fluent-bit/build > /dev/null 2>&1
    return 1
  fi

  if ! run eval "${env_cmd} ${make} ${MAKEOPTS}"; then
    cd - > /dev/null || return 1
    rm -rf fluent-bit/build > /dev/null 2>&1
    return 1
  fi

  cd - > /dev/null || return 1
}

bundle_fluentbit() {
  progress "Prepare Fluent-Bit"

  if [ "${ENABLE_LOGS_MANAGEMENT}" = 0 ]; then
    warning "You have explicitly requested to disable Khulnasoft-lab Logs Management support, Fluent-Bit build is skipped."
    return 0
  fi

  if [ ! -d "fluent-bit" ]; then
    warning "Missing submodule Fluent-Bit. The install process will continue, but Khulnasoft-lab Logs Management support will be disabled."
    ENABLE_LOGS_MANAGEMENT=0
    return 0
  fi

  patch -N -p1 fluent-bit/CMakeLists.txt -i logsmanagement/fluent_bit_build/CMakeLists.patch
  patch -N -p1 fluent-bit/src/flb_log.c -i logsmanagement/fluent_bit_build/flb-log-fmt.patch

  # If musl is used, we need to patch chunkio, providing fts has been previously installed.
  libc="$(detect_libc)"
  if [ "${libc}" = "musl" ]; then
    patch -N -p1 fluent-bit/lib/chunkio/src/CMakeLists.txt -i logsmanagement/fluent_bit_build/chunkio-static-lib-fts.patch
    patch -N -p1 fluent-bit/cmake/luajit.cmake -i logsmanagement/fluent_bit_build/exclude-luajit.patch
    patch -N -p1 fluent-bit/src/flb_network.c -i logsmanagement/fluent_bit_build/xsi-strerror.patch
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Bundling Fluent-Bit."

  if build_fluentbit "$cmake"; then
    # If Fluent-Bit built with inotify support, use it.
    if [ "$(grep -o '^FLB_HAVE_INOTIFY:INTERNAL=.*' fluent-bit/build/CMakeCache.txt | cut -d '=' -f 2)" ]; then
      CFLAGS="${CFLAGS} -DFLB_HAVE_INOTIFY"
    fi
    FLUENT_BIT_BUILD_SUCCESS=1
    run_ok "Fluent-Bit built successfully."
  else
    warning "Failed to build Fluent-Bit, Khulnasoft-lab Logs Management support will be disabled in this build."
    ENABLE_LOGS_MANAGEMENT=0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

bundle_fluentbit

# -----------------------------------------------------------------------------
# If we have the dashboard switching logic, make sure we're on the classic
# dashboard during the install (updates don't work correctly otherwise).
if [ -x "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab-switch-dashboard.sh" ]; then
  "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab-switch-dashboard.sh" classic
fi

# -----------------------------------------------------------------------------
# By default, `git` does not update local tags based on remotes. Because
# we use the most recent tag as part of our version determination in
# our build, this can lead to strange versions that look ancient but are
# actually really recent. To avoid this, try and fetch tags if we're
# working in a git checkout.
if [ -d ./.git ] ; then
  echo >&2
  progress "Updating tags in git to ensure a consistent version number"
  run git fetch -t || true
fi

# -----------------------------------------------------------------------------

echo >&2

[ -n "${GITHUB_ACTIONS}" ] && echo "::group::Configuring Khulnasoft-lab."
KHULNASOFT_BUILD_DIR="${KHULNASOFT_BUILD_DIR:-./cmake-build-release/}"
rm -rf "${KHULNASOFT_BUILD_DIR}"

check_for_module() {
  if [ -z "${pkgconf}" ]; then
    pkgconf="$(command -v pkgconf 2>/dev/null)"
    [ -z "${pkgconf}" ] && pkgconf="$(command -v pkg-config 2>/dev/null)"
    [ -z "${pkgconf}" ] && fatal "Unable to find a usable pkgconf/pkg-config command, cannot build Khulnasoft-lab." I0013
  fi

  "${pkgconf}" "${1}"
  return "${?}"
}

check_for_feature() {
  feature_name="${1}"
  feature_state="${2}"
  shift 2
  feature_modules="${*}"

  if [ -z "${feature_state}" ]; then
    # shellcheck disable=SC2086
    if check_for_module ${feature_modules}; then
      enable_feature "${feature_name}" 1
    else
      enable_feature "${feature_name}" 0
    fi
  else
    enable_feature "${feature_name}" "${feature_state}"
  fi
}

# function to extract values from the config file
config_option() {
  section="${1}"
  key="${2}"
  value="${3}"

  if [ -x "${KHULNASOFT_PREFIX}/usr/sbin/khulnasoft-lab" ] && [ -r "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf" ]; then
    "${KHULNASOFT_PREFIX}/usr/sbin/khulnasoft-lab" \
      -c "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf" \
      -W get "${section}" "${key}" "${value}" ||
      echo "${value}"
  else
    echo "${value}"
  fi
}

# the user khulnasoft-lab will run as
if [ "$(id -u)" = "0" ]; then
  KHULNASOFT_USER="$(config_option "global" "run as user" "khulnasoft-lab")"
  ROOT_USER="root"
else
  KHULNASOFT_USER="${USER}"
  ROOT_USER="${USER}"
fi
KHULNASOFT_GROUP="$(id -g -n "${KHULNASOFT_USER}" 2> /dev/null)"
[ -z "${KHULNASOFT_GROUP}" ] && KHULNASOFT_GROUP="${KHULNASOFT_USER}"
echo >&2 "Khulnasoft-lab user and group set to: ${KHULNASOFT_USER}/${KHULNASOFT_GROUP}"

KHULNASOFT_CMAKE_OPTIONS="-S ./ -B ${KHULNASOFT_BUILD_DIR} ${CMAKE_OPTS} -DCMAKE_INSTALL_PREFIX=${KHULNASOFT_PREFIX} ${KHULNASOFT_USER:+-DKHULNASOFT_USER=${KHULNASOFT_USER}} ${KHULNASOFT_CMAKE_OPTIONS} "

# Feature autodetection code starts here

if [ "${USE_SYSTEM_PROTOBUF}" -eq 1 ]; then
  enable_feature BUNDLED_PROTOBUF 0
else
  enable_feature BUNDLED_PROTOBUF 1
fi

if [ -z "${ENABLE_SYSTEMD_PLUGIN}" ]; then
    if check_for_module libsystemd; then
        if check_for_module libelogind; then
            ENABLE_SYSTEMD_JOURNAL=0
        else
            ENABLE_SYSTEMD_JOURNAL=1
        fi
    else
        ENABLE_SYSTEMD_JOURNAL=0
    fi
fi

enable_feature PLUGIN_SYSTEMD_JOURNAL "${ENABLE_SYSTEMD_JOURNAL}"

[ -z "${KHULNASOFT_ENABLE_ML}" ] && KHULNASOFT_ENABLE_ML=1
enable_feature ML "${KHULNASOFT_ENABLE_ML}"

if command -v cups-config >/dev/null 2>&1 || check_for_module libcups || check_for_module cups; then
  ENABLE_CUPS=1
else
  ENABLE_CUPS=0
fi

enable_feature PLUGIN_CUPS "${ENABLE_CUPS}"

IS_LINUX=0
[ "$(uname -s)" = "Linux" ] && IS_LINUX=1
enable_feature PLUGIN_DEBUGFS "${IS_LINUX}"
enable_feature PLUGIN_PERF "${IS_LINUX}"
enable_feature PLUGIN_SLABINFO "${IS_LINUX}"
enable_feature PLUGIN_CGROUP_NETWORK "${IS_LINUX}"
enable_feature PLUGIN_LOCAL_LISTENERS "${IS_LINUX}"
enable_feature PLUGIN_LOGS_MANAGEMENT "${ENABLE_LOGS_MANAGEMENT}"
enable_feature LOGS_MANAGEMENT_TESTS "${ENABLE_LOGS_MANAGEMENT_TESTS}"

enable_feature ACLK "${ENABLE_CLOUD}"
enable_feature CLOUD "${ENABLE_CLOUD}"
enable_feature BUNDLED_JSONC "${KHULNASOFT_BUILD_JSON_C}"
enable_feature BUNDLED_YAML "${BUNDLE_YAML}"
enable_feature DBENGINE "${ENABLE_DBENGINE}"
enable_feature H2O "${ENABLE_H2O}"
enable_feature PLUGIN_EBPF "${ENABLE_EBPF}"

ENABLE_APPS=0

if [ "${IS_LINUX}" = 1 ] || [ "$(uname -s)" = "FreeBSD" ]; then
    ENABLE_APPS=1
fi

enable_feature PLUGIN_APPS "${ENABLE_APPS}"

check_for_feature EXPORTER_PROMETHEUS_REMOTE_WRITE "${EXPORTER_PROMETHEUS}" snappy
check_for_feature EXPORTER_MONGODB "${EXPORTER_MONGODB}" libmongoc-1.0
check_for_feature PLUGIN_FREEIPMI "${ENABLE_FREEIPMI}" libipmimonitoring
check_for_feature PLUGIN_NFACCT "${ENABLE_NFACCT}" libnetfilter_acct libnml
check_for_feature PLUGIN_XENSTAT "${ENABLE_XENSTAT}" xenstat xenlight

# End of feature autodetection code

if [ -n "${KHULNASOFT_PREPARE_ONLY}" ]; then
    progress "Exiting before building Khulnasoft-lab as requested."
    printf "Would have used the following CMake command line for configuration: %s\n" "${cmake} ${KHULNASOFT_CMAKE_OPTIONS}"
    trap - EXIT
    exit 0
fi

# Let cmake know we don't want to link shared libs
if [ "${IS_KHULNASOFT_STATIC_BINARY}" = "yes" ]; then
    KHULNASOFT_CMAKE_OPTIONS="${KHULNASOFT_CMAKE_OPTIONS} -DBUILD_SHARED_LIBS=Off"
fi

# shellcheck disable=SC2086
if ! run ${cmake} ${KHULNASOFT_CMAKE_OPTIONS}; then
  fatal "Failed to configure Khulnasoft-lab sources." I000A
fi

[ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"

# remove the build_error hook
trap - EXIT

# -----------------------------------------------------------------------------
[ -n "${GITHUB_ACTIONS}" ] && echo "::group::Building Khulnasoft-lab."

# -----------------------------------------------------------------------------
progress "Compile khulnasoft-lab"

# shellcheck disable=SC2086
if ! run ${cmake} --build "${KHULNASOFT_BUILD_DIR}" --parallel ${JOBS} -- ${BUILD_OPTS}; then
  fatal "Failed to build Khulnasoft-lab." I000B
fi

[ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"

# -----------------------------------------------------------------------------
[ -n "${GITHUB_ACTIONS}" ] && echo "::group::Installing Khulnasoft-lab."

# -----------------------------------------------------------------------------
progress "Install khulnasoft-lab"

if ! cmake_install "${KHULNASOFT_BUILD_DIR}"; then
  fatal "Failed to install Khulnasoft-lab." I000C
fi

# -----------------------------------------------------------------------------
progress "Creating standard user and groups for khulnasoft-lab"

KHULNASOFT_WANTED_GROUPS="docker nginx varnish haproxy adm nsd proxy squid ceph nobody"
KHULNASOFT_ADDED_TO_GROUPS=""
if [ "$(id -u)" -eq 0 ]; then
  progress "Adding group 'khulnasoft-lab'"
  portable_add_group khulnasoft-lab || :

  progress "Adding user 'khulnasoft-lab'"
  portable_add_user khulnasoft-lab "${KHULNASOFT_PREFIX}/var/lib/khulnasoft-lab" || :

  progress "Assign user 'khulnasoft-lab' to required groups"
  for g in ${KHULNASOFT_WANTED_GROUPS}; do
    # shellcheck disable=SC2086
    portable_add_user_to_group ${g} khulnasoft-lab && KHULNASOFT_ADDED_TO_GROUPS="${KHULNASOFT_ADDED_TO_GROUPS} ${g}"
  done
  # Khulnasoft-lab must be able to read /etc/pve/qemu-server/* and /etc/pve/lxc/*
  # for reading VMs/containers names, CPU and memory limits on Proxmox.
  if [ -d "/etc/pve" ]; then
    portable_add_user_to_group "www-data" khulnasoft-lab && KHULNASOFT_ADDED_TO_GROUPS="${KHULNASOFT_ADDED_TO_GROUPS} www-data"
  fi
else
  run_failed "The installer does not run as root. Nothing to do for user and groups"
fi

# -----------------------------------------------------------------------------
progress "Install logrotate configuration for khulnasoft-lab"

install_khulnasoft-lab_logrotate

# -----------------------------------------------------------------------------
progress "Read installation options from khulnasoft-lab.conf"

# create an empty config if it does not exist
[ ! -f "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf" ] &&
  touch "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf"

# port
defport=19999
KHULNASOFT_PORT="$(config_option "web" "default port" ${defport})"

# directories
KHULNASOFT_LIB_DIR="$(config_option "global" "lib directory" "${KHULNASOFT_PREFIX}/var/lib/khulnasoft-lab")"
KHULNASOFT_CACHE_DIR="$(config_option "global" "cache directory" "${KHULNASOFT_PREFIX}/var/cache/khulnasoft-lab")"
KHULNASOFT_WEB_DIR="$(config_option "global" "web files directory" "${KHULNASOFT_PREFIX}/usr/share/khulnasoft-lab/web")"
KHULNASOFT_LOG_DIR="$(config_option "global" "log directory" "${KHULNASOFT_PREFIX}/var/log/khulnasoft-lab")"
KHULNASOFT_USER_CONFIG_DIR="$(config_option "global" "config directory" "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab")"
KHULNASOFT_STOCK_CONFIG_DIR="$(config_option "global" "stock config directory" "${KHULNASOFT_PREFIX}/usr/lib/khulnasoft-lab/conf.d")"
KHULNASOFT_RUN_DIR="${KHULNASOFT_PREFIX}/var/run"
KHULNASOFT_CLAIMING_DIR="${KHULNASOFT_LIB_DIR}/cloud.d"

cat << OPTIONSEOF

    Permissions
    - khulnasoft-lab user             : ${KHULNASOFT_USER}
    - khulnasoft-lab group            : ${KHULNASOFT_GROUP}
    - root user                : ${ROOT_USER}

    Directories
    - khulnasoft-lab user config dir  : ${KHULNASOFT_USER_CONFIG_DIR}
    - khulnasoft-lab stock config dir : ${KHULNASOFT_STOCK_CONFIG_DIR}
    - khulnasoft-lab log dir          : ${KHULNASOFT_LOG_DIR}
    - khulnasoft-lab run dir          : ${KHULNASOFT_RUN_DIR}
    - khulnasoft-lab lib dir          : ${KHULNASOFT_LIB_DIR}
    - khulnasoft-lab web dir          : ${KHULNASOFT_WEB_DIR}
    - khulnasoft-lab cache dir        : ${KHULNASOFT_CACHE_DIR}

    Other
    - khulnasoft-lab port             : ${KHULNASOFT_PORT}

OPTIONSEOF

# -----------------------------------------------------------------------------
progress "Fix permissions of khulnasoft-lab directories (using user '${KHULNASOFT_USER}')"

if [ ! -d "${KHULNASOFT_RUN_DIR}" ]; then
  # this is needed if KHULNASOFT_PREFIX is not empty
  if ! run mkdir -p "${KHULNASOFT_RUN_DIR}"; then
    warning "Failed to create ${KHULNASOFT_RUN_DIR}, it must becreated by hand or the Khulnasoft-lab Agent will not be able to be started."
  fi
fi

# --- stock conf dir ----

[ ! -d "${KHULNASOFT_STOCK_CONFIG_DIR}" ] && mkdir -p "${KHULNASOFT_STOCK_CONFIG_DIR}"
[ -L "${KHULNASOFT_USER_CONFIG_DIR}/orig" ] && run rm -f "${KHULNASOFT_USER_CONFIG_DIR}/orig"
run ln -s "${KHULNASOFT_STOCK_CONFIG_DIR}" "${KHULNASOFT_USER_CONFIG_DIR}/orig"

# --- web dir ----

if [ ! -d "${KHULNASOFT_WEB_DIR}" ]; then
  echo >&2 "Creating directory '${KHULNASOFT_WEB_DIR}'"
  run mkdir -p "${KHULNASOFT_WEB_DIR}" || exit 1
fi
run find "${KHULNASOFT_WEB_DIR}" -type f -exec chmod 0664 {} \;
run find "${KHULNASOFT_WEB_DIR}" -type d -exec chmod 0775 {} \;

# --- data dirs ----

for x in "${KHULNASOFT_LIB_DIR}" "${KHULNASOFT_CACHE_DIR}" "${KHULNASOFT_LOG_DIR}"; do
  if [ ! -d "${x}" ]; then
    echo >&2 "Creating directory '${x}'"
    if ! run mkdir -p "${x}"; then
      warning "Failed to create ${x}, it must be created by hand or the Khulnasoft-lab Agent will not be able to be started."
    fi
  fi

  run chown -R "${KHULNASOFT_USER}:${KHULNASOFT_GROUP}" "${x}"
  #run find "${x}" -type f -exec chmod 0660 {} \;
  #run find "${x}" -type d -exec chmod 0770 {} \;
done

run chmod 755 "${KHULNASOFT_LOG_DIR}"

# --- claiming dir ----

if [ ! -d "${KHULNASOFT_CLAIMING_DIR}" ]; then
  echo >&2 "Creating directory '${KHULNASOFT_CLAIMING_DIR}'"
  if ! run mkdir -p "${KHULNASOFT_CLAIMING_DIR}"; then
    warning "failed to create ${KHULNASOFT_CLAIMING_DIR}, it will need to be created manually."
  fi
fi
run chown -R "${KHULNASOFT_USER}:${KHULNASOFT_GROUP}" "${KHULNASOFT_CLAIMING_DIR}"
run chmod 770 "${KHULNASOFT_CLAIMING_DIR}"

# --- plugins ----

if [ "$(id -u)" -eq 0 ]; then
  # find the admin group
  admin_group=
  test -z "${admin_group}" && get_group root > /dev/null 2>&1 && admin_group="root"
  test -z "${admin_group}" && get_group daemon > /dev/null 2>&1 && admin_group="daemon"
  test -z "${admin_group}" && admin_group="${KHULNASOFT_GROUP}"

  run chown "${KHULNASOFT_USER}:${admin_group}" "${KHULNASOFT_LOG_DIR}"
  run chown -R "root:${admin_group}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab"
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type d -exec chmod 0755 {} \;
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type f -exec chmod 0644 {} \;
  # shellcheck disable=SC2086
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type f -a -name \*.plugin -exec chown :${KHULNASOFT_GROUP} {} \;
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type f -a -name \*.plugin -exec chmod 0750 {} \;
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type f -a -name \*.sh -exec chmod 0755 {} \;

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1> /dev/null 2>&1; then
      run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"
      if run setcap cap_dac_read_search,cap_sys_ptrace+ep "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"; then
        # if we managed to setcap, but we fail to execute apps.plugin setuid to root
        "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin" -t > /dev/null 2>&1 && capabilities=1 || capabilities=0
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      # fix apps.plugin to be setuid to root
      run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"
    fi
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/debugfs.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/debugfs.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1> /dev/null 2>&1; then
      run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/debugfs.plugin"
      if run setcap cap_dac_read_search+ep "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/debugfs.plugin"; then
        # if we managed to setcap, but we fail to execute debugfs.plugin setuid to root
        "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/debugfs.plugin" -t > /dev/null 2>&1 && capabilities=1 || capabilities=0
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      # fix debugfs.plugin to be setuid to root
      run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/debugfs.plugin"
    fi
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/systemd-journal.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/systemd-journal.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1> /dev/null 2>&1; then
      run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/systemd-journal.plugin"
      if run setcap cap_dac_read_search+ep "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/systemd-journal.plugin"; then
        capabilities=1
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/systemd-journal.plugin"
    fi
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/logs-management.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/logs-management.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1> /dev/null 2>&1; then
      run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/logs-management.plugin"
      if run setcap cap_dac_read_search,cap_syslog+ep "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/logs-management.plugin"; then
        capabilities=1
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/logs-management.plugin"
    fi
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/perf.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/perf.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1>/dev/null 2>&1; then
      run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/perf.plugin"
      if run sh -c "setcap cap_perfmon+ep \"${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/perf.plugin\" || setcap cap_sys_admin+ep \"${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/perf.plugin\""; then
        capabilities=1
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/perf.plugin"
    fi
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/slabinfo.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/slabinfo.plugin"
    capabilities=0
    if ! iscontainer && command -v setcap 1>/dev/null 2>&1; then
      run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/slabinfo.plugin"
      if run setcap cap_dac_read_search+ep "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/slabinfo.plugin"; then
        capabilities=1
      fi
    fi

    if [ $capabilities -eq 0 ]; then
      run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/slabinfo.plugin"
    fi
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/freeipmi.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/freeipmi.plugin"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/freeipmi.plugin"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/nfacct.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/nfacct.plugin"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/nfacct.plugin"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/xenstat.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/xenstat.plugin"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/xenstat.plugin"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ioping" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ioping"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ioping"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf.plugin" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf.plugin"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf.plugin"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/cgroup-network" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/cgroup-network"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/cgroup-network"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/cgroup-network-helper.sh" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/cgroup-network-helper.sh"
    run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/cgroup-network-helper.sh"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/local-listeners" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/local-listeners"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/local-listeners"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ndsudo" ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ndsudo"
    run chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ndsudo"
  fi

else
  # non-privileged user installation
  run chown "${KHULNASOFT_USER}:${KHULNASOFT_GROUP}" "${KHULNASOFT_LOG_DIR}"
  run chown -R "${KHULNASOFT_USER}:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab"
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type f -exec chmod 0755 {} \;
  run find "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab" -type d -exec chmod 0755 {} \;
fi

[ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"

# -----------------------------------------------------------------------------

# govercomp compares go.d.plugin versions. Exit codes:
# 0 - version1 == version2
# 1 - version1 > version2
# 2 - version2 > version1
# 3 - error

# shellcheck disable=SC2086
govercomp() {
  # version in file:
  # - v0.14.0
  #
  # 'go.d.plugin -v' output variants:
  # - go.d.plugin, version: unknown
  # - go.d.plugin, version: v0.14.1
  # - go.d.plugin, version: v0.14.1-dirty
  # - go.d.plugin, version: v0.14.1-1-g4c5f98c
  # - go.d.plugin, version: v0.14.1-1-g4c5f98c-dirty

  # we need to compare only MAJOR.MINOR.PATCH part
  ver1=$(echo "$1" | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")
  ver2=$(echo "$2" | grep -E -o "[0-9]+\.[0-9]+\.[0-9]+")

  if [ ${#ver1} -eq 0 ] || [ ${#ver2} -eq 0 ]; then
    return 3
  fi

  num1=$(echo $ver1 | grep -o -E '\.' | wc -l)
  num2=$(echo $ver2 | grep -o -E '\.' | wc -l)

  if [ ${num1} -ne ${num2} ]; then
          return 3
  fi

  for i in $(seq 1 $((num1+1))); do
          x=$(echo $ver1 | cut -d'.' -f$i)
          y=$(echo $ver2 | cut -d'.' -f$i)
    if [ "${x}" -gt "${y}" ]; then
      return 1
    elif [ "${y}" -gt "${x}" ]; then
      return 2
    fi
  done

  return 0
}

should_install_go() {
  if [ -n "${KHULNASOFT_DISABLE_GO+x}" ]; then
    return 1
  fi

  version_in_file="$(cat packaging/go.d.version 2> /dev/null)"
  binary_version=$("${KHULNASOFT_PREFIX}"/usr/libexec/khulnasoft-lab/plugins.d/go.d.plugin -v 2> /dev/null)

  govercomp "$version_in_file" "$binary_version"
  case $? in
    0) return 1 ;; # =
    2) return 1 ;; # <
    *) return 0 ;; # >, error
  esac
}

install_go() {
  if ! should_install_go; then
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Installing go.d.plugin."

  # When updating this value, ensure correct checksums in packaging/go.d.checksums
  GO_PACKAGE_VERSION="$(cat packaging/go.d.version)"
  ARCH_MAP='
    i386::386
    i686::386
    x86_64::amd64
    aarch64::arm64
    armv64::arm64
    armv6l::arm
    armv7l::arm
    armv5tel::arm
  '

  progress "Install go.d.plugin"
  ARCH=$(uname -m)
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')

  for index in ${ARCH_MAP}; do
    KEY="${index%%::*}"
    VALUE="${index##*::}"
    if [ "$KEY" = "$ARCH" ]; then
      ARCH="${VALUE}"
      break
    fi
  done
  tmp="$(mktemp -d -t khulnasoft-lab-go-XXXXXX)"
  GO_PACKAGE_BASENAME="go.d.plugin-${GO_PACKAGE_VERSION}.${OS}-${ARCH}.tar.gz"

  if [ -z "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN}" ]; then
    download_go "https://github.com/khulnasoft-lab/go.d.plugin/releases/download/${GO_PACKAGE_VERSION}/${GO_PACKAGE_BASENAME}" "${tmp}/${GO_PACKAGE_BASENAME}"
  else
    progress "Using provided go.d tarball ${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN}"
    run cp "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN}" "${tmp}/${GO_PACKAGE_BASENAME}"
  fi

  if [ -z "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN_CONFIG}" ]; then
    download_go "https://github.com/khulnasoft-lab/go.d.plugin/releases/download/${GO_PACKAGE_VERSION}/config.tar.gz" "${tmp}/config.tar.gz"
  else
    progress "Using provided config file for go.d ${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN_CONFIG}"
    run cp "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_GO_PLUGIN_CONFIG}" "${tmp}/config.tar.gz"
  fi

  if [ ! -f "${tmp}/${GO_PACKAGE_BASENAME}" ] || [ ! -f "${tmp}/config.tar.gz" ] || [ ! -s "${tmp}/config.tar.gz" ] || [ ! -s "${tmp}/${GO_PACKAGE_BASENAME}" ]; then
    run_failed "go.d plugin download failed, go.d plugin will not be available"
    echo >&2 "Either check the error or consider disabling it by issuing '--disable-go' in the installer"
    echo >&2
    [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
    return 0
  fi

  grep "${GO_PACKAGE_BASENAME}\$" "${INSTALLER_DIR}/packaging/go.d.checksums" > "${tmp}/sha256sums.txt" 2> /dev/null
  grep "config.tar.gz" "${INSTALLER_DIR}/packaging/go.d.checksums" >> "${tmp}/sha256sums.txt" 2> /dev/null

  # Checksum validation
  if ! (cd "${tmp}" && safe_sha256sum -c "sha256sums.txt"); then

    echo >&2 "go.d plugin checksum validation failure."
    echo >&2 "Either check the error or consider disabling it by issuing '--disable-go' in the installer"
    echo >&2

    run_failed "go.d.plugin package files checksum validation failed. go.d.plugin will not be available."
    [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
    return 0
  fi

  # Install new files
  run rm -rf "${KHULNASOFT_STOCK_CONFIG_DIR}/go.d"
  run rm -rf "${KHULNASOFT_STOCK_CONFIG_DIR}/go.d.conf"
  run tar --no-same-owner -xf "${tmp}/config.tar.gz" -C "${KHULNASOFT_STOCK_CONFIG_DIR}/"
  run chown -R "${ROOT_USER}:${ROOT_GROUP}" "${KHULNASOFT_STOCK_CONFIG_DIR}"

  run tar --no-same-owner -xf "${tmp}/${GO_PACKAGE_BASENAME}"
  run mv "${GO_PACKAGE_BASENAME%.tar.gz}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/go.d.plugin"
  if [ "$(id -u)" -eq 0 ]; then
    run chown "root:${KHULNASOFT_GROUP}" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/go.d.plugin"
  fi
  run chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/go.d.plugin"
  rm -rf "${tmp}"

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

install_go

if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/go.d.plugin" ]; then
  if command -v setcap 1>/dev/null 2>&1; then
    run setcap "cap_net_admin+epi cap_net_raw=eip" "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/go.d.plugin"
  fi
fi

should_install_ebpf() {
  if [ "${KHULNASOFT_DISABLE_EBPF:=0}" -eq 1 ]; then
    run_failed "eBPF has been explicitly disabled, it will not be available in this install."
    return 1
  fi

  if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    if [ "${KHULNASOFT_DISABLE_EBPF:=1}" -eq 0 ]; then
      run_failed "Currently eBPF is only supported on Linux on X86_64."
    fi

    return 1
  fi

  # Check Kernel Config
  if ! run "${INSTALLER_DIR}"/packaging/check-kernel-config.sh; then
    warning "Kernel unsupported or missing required config (eBPF may not work on your system)"
  fi

  return 0
}

remove_old_ebpf() {
  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf_process.plugin" ]; then
    echo >&2 "Removing alpha eBPF collector."
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf_process.plugin"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/usr/lib/khulnasoft-lab/conf.d/ebpf_process.conf" ]; then
    echo >&2 "Removing alpha eBPF stock file"
    rm -f "${KHULNASOFT_PREFIX}/usr/lib/khulnasoft-lab/conf.d/ebpf_process.conf"
  fi

  if [ -f "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/ebpf_process.conf" ]; then
    echo >&2 "Renaming eBPF configuration file."
    mv "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/ebpf_process.conf" "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/ebpf.d.conf"
  fi

  # Added to remove eBPF programs with name pattern: NAME_VERSION.SUBVERSION.PATCH
  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/pkhulnasoft-lab_ebpf_process.3.10.0.o" ]; then
    echo >&2 "Removing old eBPF programs with patch."
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/rkhulnasoft-lab_ebpf"*.?.*.*.o
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/pkhulnasoft-lab_ebpf"*.?.*.*.o
  fi

  # Remove old eBPF program to store new eBPF program inside subdirectory
  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/pkhulnasoft-lab_ebpf_process.3.10.o" ]; then
    echo >&2 "Removing old eBPF programs installed in old directory."
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/rkhulnasoft-lab_ebpf"*.?.*.o
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/pkhulnasoft-lab_ebpf"*.?.*.o
  fi

  # Remove old eBPF programs that did not have "rhf" suffix
  if [ ! -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf.d/pkhulnasoft-lab_ebpf_process.3.10.rhf.o" ]; then
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/ebpf.d/"*.o
  fi

  # Remove old reject list from previous directory
  if [ -f "${KHULNASOFT_PREFIX}/usr/lib/khulnasoft-lab/conf.d/ebpf_kernel_reject_list.txt" ]; then
    echo >&2 "Removing old ebpf_kernel_reject_list.txt."
    rm -f "${KHULNASOFT_PREFIX}/usr/lib/khulnasoft-lab/conf.d/ebpf_kernel_reject_list.txt"
  fi

  # Remove old reset script
  if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/reset_khulnasoft-lab_trace.sh" ]; then
    echo >&2 "Removing old reset_khulnasoft-lab_trace.sh."
    rm -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/reset_khulnasoft-lab_trace.sh"
  fi
}

install_ebpf() {
  if ! should_install_ebpf; then
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Installing eBPF code."

  remove_old_ebpf

  progress "Installing eBPF plugin"

  # Detect libc
  libc="${EBPF_LIBC:-"$(detect_libc)"}"

  EBPF_VERSION="$(cat packaging/ebpf.version)"
  EBPF_TARBALL="khulnasoft-lab-kernel-collector-${libc}-${EBPF_VERSION}.tar.xz"

  tmp="$(mktemp -d -t khulnasoft-lab-ebpf-XXXXXX)"

  if ! fetch_and_verify "ebpf" \
    "https://github.com/khulnasoft-lab/kernel-collector/releases/download/${EBPF_VERSION}/${EBPF_TARBALL}" \
    "${EBPF_TARBALL}" \
    "${tmp}" \
    "${KHULNASOFT_LOCAL_TARBALL_OVERRIDE_EBPF}"; then
    run_failed "Failed to download eBPF collector package"
    echo 2>&" Removing temporary directory ${tmp} ..."
    rm -rf "${tmp}"

    [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
    return 1
  fi

  echo >&2 " Extracting ${EBPF_TARBALL} ..."
  tar --no-same-owner -xf "${tmp}/${EBPF_TARBALL}" -C "${tmp}"

  # chown everything to root:khulnasoft-lab before we start copying out of our package
  run chown -R root:khulnasoft-lab "${tmp}"

  if [ ! -d "${KHULNASOFT_PREFIX}"/usr/libexec/khulnasoft-lab/plugins.d/ebpf.d ]; then
    mkdir "${KHULNASOFT_PREFIX}"/usr/libexec/khulnasoft-lab/plugins.d/ebpf.d
    RET=$?
    if [ "${RET}" != "0" ]; then
      rm -rf "${tmp}"

      [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
      return 1
    fi
  fi

  run cp -a -v "${tmp}"/*khulnasoft-lab_ebpf_*.o "${KHULNASOFT_PREFIX}"/usr/libexec/khulnasoft-lab/plugins.d/ebpf.d

  rm -rf "${tmp}"

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

progress "eBPF Kernel Collector"
install_ebpf

should_install_fluentbit() {
  if [ "$(uname -s)" = "Darwin" ]; then
    return 1
  fi
  if [ "${ENABLE_LOGS_MANAGEMENT}" = 0 ]; then
    warning "khulnasoft-lab-installer.sh run with --disable-logsmanagement, Fluent-Bit installation is skipped."
    return 1
  elif [ "${FLUENT_BIT_BUILD_SUCCESS:=0}" -eq 0 ]; then
    run_failed "Fluent-Bit was not built successfully, Khulnasoft-lab Logs Management support will be disabled in this build."
    return 1
  elif [ ! -f fluent-bit/build/lib/libfluent-bit.so ]; then
    run_failed "libfluent-bit.so is missing, Khulnasoft-lab Logs Management support will be disabled in this build."
    return 1
  fi

  return 0
}

install_fluentbit() {
  if ! should_install_fluentbit; then
    enable_feature PLUGIN_LOGS_MANAGEMENT 0
    return 0
  fi

  [ -n "${GITHUB_ACTIONS}" ] && echo "::group::Installing Fluent-Bit."

  run chown "root:${KHULNASOFT_GROUP}" fluent-bit/build/lib
  run chmod 0644 fluent-bit/build/lib/libfluent-bit.so

  run cp -a -v fluent-bit/build/lib/libfluent-bit.so "${KHULNASOFT_PREFIX}"/usr/lib/khulnasoft-lab

  [ -n "${GITHUB_ACTIONS}" ] && echo "::endgroup::"
}

progress "Installing Fluent-Bit plugin"
install_fluentbit

# -----------------------------------------------------------------------------
progress "Telemetry configuration"

# Opt-out from telemetry program
if [ -n "${KHULNASOFT_DISABLE_TELEMETRY+x}" ]; then
  run touch "${KHULNASOFT_USER_CONFIG_DIR}/.opt-out-from-anonymous-statistics"
else
  printf "You can opt out from anonymous statistics via the --disable-telemetry option, or by creating an empty file %s \n\n" "${KHULNASOFT_USER_CONFIG_DIR}/.opt-out-from-anonymous-statistics"
fi

# -----------------------------------------------------------------------------
progress "Install khulnasoft-lab at system init"

# By default we assume the shutdown/startup of the Khulnasoft-lab Agent are effectively
# without any system supervisor/init like SystemD or SysV. So we assume the most
# basic startup/shutdown commands...
KHULNASOFT_STOP_CMD="${KHULNASOFT_PREFIX}/usr/sbin/khulnasoft-labcli shutdown-agent"
KHULNASOFT_START_CMD="${KHULNASOFT_PREFIX}/usr/sbin/khulnasoft-lab"

if grep -q docker /proc/1/cgroup > /dev/null 2>&1; then
  # If docker runs systemd for some weird reason, let the install proceed
  is_systemd_running="NO"
  if command -v pidof > /dev/null 2>&1; then
    is_systemd_running="$(pidof /usr/sbin/init || pidof systemd || echo "NO")"
  else
    is_systemd_running="$( (pgrep -q -f systemd && echo "1") || echo "NO")"
  fi

  if [ "${is_systemd_running}" = "1" ]; then
    echo >&2 "Found systemd within the docker container, running install_khulnasoft-lab_service() method"
    install_khulnasoft-lab_service || run_failed "Cannot install khulnasoft-lab init service."
  else
    echo >&2 "We are running within a docker container, will not be installing khulnasoft-lab service"
  fi
  echo >&2
else
  install_khulnasoft-lab_service || run_failed "Cannot install khulnasoft-lab init service."
fi

# -----------------------------------------------------------------------------
# check if we can re-start khulnasoft-lab

# TODO(paulfantom): Creation of configuration file should be handled by a build system. Additionally we shouldn't touch configuration files in /etc/khulnasoft-lab/...
started=0
if [ ${DONOTSTART} -eq 1 ]; then
  create_khulnasoft-lab_conf "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf"
else
  if ! restart_khulnasoft-lab "${KHULNASOFT_PREFIX}/usr/sbin/khulnasoft-lab" "${@}"; then
    fatal "Cannot start khulnasoft-lab!" I000D
  fi

  started=1
  run_ok "khulnasoft-lab started!"
  create_khulnasoft-lab_conf "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf" "http://localhost:${KHULNASOFT_PORT}/khulnasoft-lab.conf"
fi
run chmod 0644 "${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/khulnasoft-lab.conf"

if [ "$(uname)" = "Linux" ]; then
  # -------------------------------------------------------------------------
  progress "Check KSM (kernel memory deduper)"

  ksm_is_available_but_disabled() {
    cat << KSM1

${TPUT_BOLD}Memory de-duplication instructions${TPUT_RESET}

You have kernel memory de-duper (called Kernel Same-page Merging,
or KSM) available, but it is not currently enabled.

To enable it run:

    ${TPUT_YELLOW}${TPUT_BOLD}echo 1 >/sys/kernel/mm/ksm/run${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}echo 1000 >/sys/kernel/mm/ksm/sleep_millisecs${TPUT_RESET}

If you enable it, you will save 40-60% of khulnasoft-lab memory.

KSM1
  }

  ksm_is_not_available() {
    cat << KSM2

${TPUT_BOLD}Memory de-duplication not present in your kernel${TPUT_RESET}

It seems you do not have kernel memory de-duper (called Kernel Same-page
Merging, or KSM) available.

To enable it, you need a kernel built with CONFIG_KSM=y

If you can have it, you will save 40-60% of khulnasoft-lab memory.

KSM2
  }

  if [ -f "/sys/kernel/mm/ksm/run" ]; then
    if [ "$(cat "/sys/kernel/mm/ksm/run")" != "1" ]; then
      ksm_is_available_but_disabled
    fi
  else
    ksm_is_not_available
  fi
fi

if [ -f "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin" ]; then
  # -----------------------------------------------------------------------------
  progress "Check apps.plugin"

  if [ "$(id -u)" -ne 0 ]; then
    cat << SETUID_WARNING

${TPUT_BOLD}apps.plugin needs privileges${TPUT_RESET}

Since you have installed khulnasoft-lab as a normal user, to have apps.plugin collect
all the needed data, you have to give it the access rights it needs, by running
either of the following sets of commands:

To run apps.plugin with escalated capabilities:

    ${TPUT_YELLOW}${TPUT_BOLD}sudo chown root:${KHULNASOFT_GROUP} "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}sudo chmod 0750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}sudo setcap cap_dac_read_search,cap_sys_ptrace+ep "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"${TPUT_RESET}

or, to run apps.plugin as root:

    ${TPUT_YELLOW}${TPUT_BOLD}sudo chown root:${KHULNASOFT_GROUP} "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"${TPUT_RESET}
    ${TPUT_YELLOW}${TPUT_BOLD}sudo chmod 4750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/plugins.d/apps.plugin"${TPUT_RESET}

apps.plugin is performing a hard-coded function of data collection for all
running processes. It cannot be instructed from the khulnasoft-lab daemon to perform
any task, so it is pretty safe to do this.

SETUID_WARNING
  fi
fi

# -----------------------------------------------------------------------------
progress "Copy uninstaller"
if [ -f "${KHULNASOFT_PREFIX}"/usr/libexec/khulnasoft-lab-uninstaller.sh ]; then
  echo >&2 "Removing uninstaller from old location"
  rm -f "${KHULNASOFT_PREFIX}"/usr/libexec/khulnasoft-lab-uninstaller.sh
fi

sed "s|ENVIRONMENT_FILE=\"/etc/khulnasoft-lab/.environment\"|ENVIRONMENT_FILE=\"${KHULNASOFT_PREFIX}/etc/khulnasoft-lab/.environment\"|" packaging/installer/khulnasoft-lab-uninstaller.sh > "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/khulnasoft-lab-uninstaller.sh"
chmod 750 "${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/khulnasoft-lab-uninstaller.sh"

# -----------------------------------------------------------------------------
progress "Basic khulnasoft-lab instructions"

cat << END

khulnasoft-lab by default listens on all IPs on port ${KHULNASOFT_PORT},
so you can access it with:

  ${TPUT_CYAN}${TPUT_BOLD}http://this.machine.ip:${KHULNASOFT_PORT}/${TPUT_RESET}

To stop khulnasoft-lab run:

  ${TPUT_YELLOW}${TPUT_BOLD}${KHULNASOFT_STOP_CMD}${TPUT_RESET}

To start khulnasoft-lab run:

  ${TPUT_YELLOW}${TPUT_BOLD}${KHULNASOFT_START_CMD}${TPUT_RESET}

END
echo >&2 "Uninstall script copied to: ${TPUT_RED}${TPUT_BOLD}${KHULNASOFT_PREFIX}/usr/libexec/khulnasoft-lab/khulnasoft-lab-uninstaller.sh${TPUT_RESET}"
echo >&2

# -----------------------------------------------------------------------------
progress "Installing (but not enabling) the khulnasoft-lab updater tool"
install_khulnasoft-lab_updater || run_failed "Cannot install khulnasoft-lab updater tool."

# -----------------------------------------------------------------------------
progress "Wrap up environment set up"

# Save environment variables
echo >&2 "Preparing .environment file"
cat << EOF > "${KHULNASOFT_USER_CONFIG_DIR}/.environment"
# Created by installer
PATH="${PATH}"
CFLAGS="${CFLAGS}"
LDFLAGS="${LDFLAGS}"
MAKEOPTS="${MAKEOPTS}"
KHULNASOFT_TMPDIR="${TMPDIR}"
KHULNASOFT_PREFIX="${KHULNASOFT_PREFIX}"
KHULNASOFT_CMAKE_OPTIONS="${KHULNASOFT_CMAKE_OPTIONS}"
KHULNASOFT_ADDED_TO_GROUPS="${KHULNASOFT_ADDED_TO_GROUPS}"
INSTALL_UID="$(id -u)"
KHULNASOFT_GROUP="${KHULNASOFT_GROUP}"
REINSTALL_OPTIONS="${REINSTALL_OPTIONS}"
RELEASE_CHANNEL="${RELEASE_CHANNEL}"
IS_KHULNASOFT_STATIC_BINARY="${IS_KHULNASOFT_STATIC_BINARY}"
KHULNASOFT_LIB_DIR="${KHULNASOFT_LIB_DIR}"
EOF
run chmod 0644 "${KHULNASOFT_USER_CONFIG_DIR}/.environment"

echo >&2 "Setting khulnasoft-lab.tarball.checksum to 'new_installation'"
cat << EOF > "${KHULNASOFT_LIB_DIR}/khulnasoft-lab.tarball.checksum"
new_installation
EOF

print_deferred_errors

# -----------------------------------------------------------------------------
echo >&2
progress "We are done!"

if [ ${started} -eq 1 ]; then
  khulnasoft-lab_banner
  progress "is installed and running now!"
else
  khulnasoft-lab_banner
  progress "is installed now!"
fi

echo >&2 "  enjoy real-time performance and health monitoring..."
echo >&2
exit 0
