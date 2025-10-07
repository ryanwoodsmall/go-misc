#!/bin/bash
#
# build a static up-to-date go dist for a few platforms
#

#
# XXX - rename to gostatic?
# XXX - turn off debugging?
# XXX - https://github.com/golang/go/issues/9344
# XXX - enable cgo for final stage?
# XXX - include _${TIMESTAMP} in directory/archive?
# XXX - look at using src/bootstrap.bash instead of custom
# XXX - include curl cert.pem in ${cwsw}/go/current/etc/ssl/cert.pem as fallback?
# XXX - at some point it'll be go 1.4->1.17.3+->1.2x.x->1.3x.x(?)->2.x.x, would be good to be prepared
#

set -eu

sname="${BASH_SOURCE[0]}"

function failexit() {
  while [[ ${#} -gt 0 ]] ; do
    printf '%s: %s\n' "${sname}" "${1}" 1>&2
    shift
  done
  exit 1
}

if [[ ! $(uname -m) =~ x86_64 ]] ; then
  failexit "please run on amd64 (for now)"
fi

# prerequisite programs
prereqs=( 'curl' 'gcc' 'gzip' 'nproc' 'tar' 'xz' )
for prereq in ${prereqs[@]} ; do
  if ! command -v "${prereq}" &>/dev/null ; then
    failexit "${prereq} not found"
  fi
done

# curl options
: ${copts:="-k -L -o"}

# check for real xz, not busybox
if ! `xz --version 2>&1 | grep -qi 'xz utils'` ; then
  failexit "please install xz"
fi

# versions
declare -a govers
govers+=( "1.4-bootstrap-20171003" )
govers+=( "1.19.13" )
govers+=( "1.21.13" )
govers+=( "1.23.12" )
govers+=( "1.25.2" )
: ${gofinalver:="${govers[-1]}"}

# files, urls
: ${godlbase:="https://go.dev/dl"}
declare -A godirh gofileh gofileurlh gofilesha256h
for v in ${govers[@]} ; do
  godirh["${v}"]="go${v}"
  gofileh["${v}"]="${godirh[${v}]}.src.tar.gz"
  gofileurlh["${v}"]="${godlbase}/${gofileh[${v}]}"
done
gofilesha256h["1.4-bootstrap-20171003"]="f4ff5b5eb3a3cae1c993723f3eab519c5bae18866b5e5f96fe1102f0cb5c3e52"
gofilesha256h["1.19.13"]="ccf36b53fb0024a017353c3ddb22c1f00bc7a8073c6aac79042da24ee34434d3"
gofilesha256h["1.21.13"]="71fb31606a1de48d129d591e8717a63e0c5565ffba09a24ea9f899a13214c34d"
gofilesha256h["1.23.12"]="e1cce9379a24e895714a412c7ddd157d2614d9edbe83a84449b6e1840b4f1226"
gofilesha256h["1.25.2"]="3711140cfb87fce8f7a13f7cd860df041e6c12f7610f40cac6ec6fa2b65e96e4"
# 1.4 special handling
gofileh['1.4-bootstrap-20171003']="${godirh['1.4-bootstrap-20171003']}.tar.gz"
gofileurlh['1.4-bootstrap-20171003']="${godlbase}/${gofileh['1.4-bootstrap-20171003']}"

: ${gover:="${gofinalver}"}
gomajver="${gover%%.*}"
gominver="${gover#*.}"
gominver="${gominver%%.*}"
: ${godir:="go${gover}"}
: ${gofile:="go${gover}.src.tar.gz"}
: ${gofileurl:="${godlbase}/${gofile}"}
: ${gofilesha256:="${gofilesha256h[${gover}]}"}

# architectures
goarches=( '386' 'amd64' 'arm' 'arm64' 'riscv64' )
# XXX - need an extra opts for GOARM=6 on arm, blank on everything else

# crosware stuff - build bootstrap stages in tmp and install in software
cwtop="/usr/local/crosware"
cwbuild="${cwtop}/builds"
cwdl="${cwtop}/downloads"
cwtmp="${cwtop}/tmp"
cwgotmp="${cwtmp}/go"
cwsw="${cwtop}/software"
: ${rtdir:="${cwsw}/go${gomajver}${gominver}"}

# random
: ${godldir:="${cwdl}/go"}
: ${vartmp:="/var/tmp"}

# surround a string in a box
# XXX - tb="++++$(echo ${@} | sed 's/./,/g')"
function boxecho() {
  local len="$(($(echo -n ${@} | wc -c)+4))"
  local i=0
  for i in $(seq 1 ${len}) ; do echo -n "+" ; done
  echo
  echo "+ ${@} +"
  for i in $(seq 1 ${len}) ; do echo -n "+" ; done
  echo
}

# fetch/check function
function fetchcheck() {
  if [[ ${#} != 3 ]] ; then
    failexit 'provide: ${url} ${downloadfile} ${checksum}'
  fi
  mkdir -p "$(dirname -- ${2})"
  if [[ -e "${2}" ]] ; then
    if sha256sum "${2}" | awk '{print $1}' | grep -qi "^${3}$" ; then
      printf '%s: %s exists and matched checksum\n' "${sname}" "${2}"
      return
    fi
  fi
  printf '%s: %s\n' "${sname}" "downloading ${1} to ${2}"
  curl ${copts} "${2}" "${1}"
  printf '%s: %s\n' "${sname}" "checking SHA-256 sum of ${2}"
  sha256sum "${2}" | awk '{print $1}' | grep -qi "^${3}$" || failexit "could not download/checksum ${1} to ${2}"
}

# bootstrap build
bspv=""
function gobsbuild() {
  if [[ ${#} -ne 1 ]] ; then
    failexit 'provide one known bootstrap version'
  fi
  local v="${1}"
  local gbe=''
  pushd "${cwbuild}" &>/dev/null
  local d="${godirh[${v}]}"
  test -e go && rm -rf go
  test -e "${d}" && rm -rf "${d}"
  tar -zxf "${godldir}/${gofileh[${v}]}"
  mv go "${d}"
  pushd "${d}/src/" &>/dev/null
  boxecho "building go ${v} in ${PWD}"
  test -z "${bspv}" || export gbe="GOROOT_BOOTSTRAP=${cwbuild}/${godirh[${bspv}]}"
  env GO_LDFLAGS='-extldflags "-static -s" -s -w' CGO_ENABLED=0 ${gbe} bash make.bash
  popd &>/dev/null
  popd &>/dev/null
  rm -rf go
  export bspv="${v}"
  echo
}

# create build/install directories
mkdir -p "${cwbuild}"
mkdir -p "${cwtmp}"
mkdir -p "${cwgotmp}"
mkdir -p "${rtdir}"
mkdir -p "${godldir}"
mkdir -p "${vartmp}"

# downloads
boxecho "+++++ DOWNLOAD +++++"
for v in ${govers[@]} ; do
  fetchcheck "${gofileurlh[${v}]}" "${godldir}/${gofileh[${v}]}" "${gofilesha256h[${v}]}"
done
fetchcheck "${gofileurl}" "${godldir}/${gofile}" "${gofilesha256}"
echo

# bootstraps
boxecho "+++++ BOOTSTRAP +++++"
pushd "${cwbuild}" &>/dev/null
for ((i = 0 ; i < ${#govers[@]} ; i++)) ; do
  boxecho "+++ STAGE ${i} +++"
  gobsbuild "${govers[${i}]}"
  fbsv="${bspv}"
done
popd &>/dev/null
echo

# final builds
pushd "${rtdir}" &>/dev/null
for goarch in ${goarches[@]} ; do
  boxecho "building final go${gover} for ${goarch} in ${PWD}"
  goarchdir="${godir}-${goarch}"
  goarchive="${cwgotmp}/${goarchdir}.tar"
  test -e go && rm -rf go
  test -e "${goarchdir}" && rm -rf "${goarchdir}"
  tar -zxf "${godldir}/${gofile}"
  mv go "${goarchdir}"
  pushd "${goarchdir}/src/" &>/dev/null
  boxecho "patching crypto/x509/root_linux.go with cert locations"
  cat crypto/x509/root_linux.go > crypto/x509/root_linux.go.ORIG
  sed -i 's|"/etc/ssl/cert.pem"|"/etc/ssl/cert.pem","'"${cwtop}/etc/ssl/cert.pem"'"|g' crypto/x509/root_linux.go
  sed -i 's|"/etc/ssl/certs"|"/etc/ssl/certs","'"${cwtop}/etc/ssl/certs"'"|g' crypto/x509/root_linux.go
  "${cwbuild}/${godirh[${fbsv}]}/bin/gofmt" -w crypto/x509/root_linux.go
  #diff -Naur crypto/x509/root_linux.go{.ORIG,} || true
  env GO_LDFLAGS='-extldflags "-static -s" -s -w' CGO_ENABLED=0 GOROOT_BOOTSTRAP="${cwbuild}/${godirh[${fbsv}]}" GOOS='linux' GOARCH="${goarch}" bash make.bash
  popd &>/dev/null
  pushd "${goarchdir}" &>/dev/null
  rm -rf pkg/obj/go-build
  rm -rf pkg/bootstrap
  if [[ ! ${goarch} =~ amd64 ]] ; then
    rm -rf pkg/tool/linux_amd64
    rm -rf pkg/linux_amd64
    rm -f bin/go{,fmt}
    mv bin/linux_${goarch}/* bin/
    rmdir bin/linux_${goarch}
  fi
  popd &>/dev/null
  boxecho "successfully built go${gover} for ${goarch}"
  echo "archiving ${goarchdir} to ${goarchive}"
  tar -cf "${goarchive}" "${goarchdir}/"
  pushd "$(dirname ${goarchive})" &>/dev/null
  echo "using xz to compress ${goarchive} in ${PWD}"
  rm -f "${goarchive}.xz"
  xz --threads=$(nproc) -e -v -v "${goarchive}"
  echo "storing SHA-256 sum to ${goarchive}.xz.sha256"
  sha256sum "$(basename ${goarchive}.xz)" > "${goarchive}.xz.sha256"
  popd &>/dev/null
  echo
done
popd &>/dev/null
echo


# vim: set ft=bash:
