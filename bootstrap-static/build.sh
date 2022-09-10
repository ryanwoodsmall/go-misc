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
#

set -eu

sname="${BASH_SOURCE[0]}"

if [[ ! $(uname -m) =~ x86_64 ]] ; then
	echo "${sname}: please run on amd64 (for now)" 1>&2
	exit 1
fi

# prerequisite programs
prereqs=( 'curl' 'gcc' 'gzip' 'nproc' 'tar' 'xz' )
for prereq in ${prereqs[@]} ; do
	if ! $(hash "${prereq}" >/dev/null 2>&1) ; then
		echo "${sname}: ${prereq} not found" 1>&2
		exit 1
	fi
done
# curl options
copts="-k -L -O"
# check for real xz, not busybox
if ! `xz --version 2>&1 | grep -qi 'xz utils'` ; then
	echo "${sname}: please install xz" 1>&2
	exit 2
fi

# bootstrap go version in C
gobsver="1.4-bootstrap-20171003"
gobsdir="go${gobsver}"
gobsfile="go${gobsver}.tar.gz"
gobsfilesha256="f4ff5b5eb3a3cae1c993723f3eab519c5bae18866b5e5f96fe1102f0cb5c3e52"
# go intermediate and final build verison
: ${gover:="1.19.1"}
gomajver="${gover%%.*}"
gominver="${gover#*.}"
gominver="${gominver%%.*}"
: ${gofilesha256:="27871baa490f3401414ad793fba49086f6c855b1c584385ed7771e1204c7e179"}
godir="go${gover}"
gofile="go${gover}.src.tar.gz"
# download
gobaseurl="https://dl.google.com/go"
gobsurl="${gobaseurl}/${gobsfile}"
gourl="${gobaseurl}/${gofile}"
# architectures
goarches=( '386' 'amd64' 'arm' 'arm64' 'riscv64' )
# XXX - need an extra opts for GOARM=6 on arm, blank on everything else

# crosware stuff - build bootstrap stages in tmp and install in software
cwtop="/usr/local/crosware"
cwbuild="${cwtop}/builds"
cwdl="${cwtop}/downloads"
cwtmp="${cwtop}/tmp"
cwsw="${cwtop}/software"
: ${rtdir:="${cwsw}/go${gomajver}${gominver}"}

# random
godldir="${cwdl}/go"
vartmp="/var/tmp"

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

# create build/install directories
mkdir -p "${cwbuild}"
mkdir -p "${cwtmp}"
mkdir -p "${rtdir}"
mkdir -p "${godldir}"
mkdir -p "${vartmp}"

# download
pushd "${godldir}"
for url in "${gobsurl}" "${gourl}" ; do
	boxecho "fetching ${url} in ${PWD}"
	curl ${copts} "${url}"
done
popd

# bootstrap
pushd "${cwbuild}"
# stage 1: 1.4 (in C)
test -e go && rm -rf go
test -e "${gobsdir}" && rm -rf "${gobsdir}"
tar -zxf "${godldir}/${gobsfile}"
mv go "${gobsdir}"
pushd "${gobsdir}/src/"
boxecho "building stage1 go1.4 in ${PWD}"
env GO_LDFLAGS='-extldflags "-static -s" -s -w' CGO_ENABLED=0 bash make.bash
popd
echo
# stage 2: second stage bootstrap (go -> go)
test -e go && rm -rf go
test -e "${godir}" && rm -rf "${godir}"
tar -zxf "${godldir}/${gofile}"
mv go "${godir}"
pushd "${godir}/src"
boxecho "building stage2 go${gover} in ${PWD}"
env GO_LDFLAGS='-extldflags "-static -s" -s -w' CGO_ENABLED=0 GOROOT_BOOTSTRAP="${cwbuild}/${gobsdir}" bash make.bash
popd
popd
echo

# final builds
pushd "${rtdir}"
for goarch in ${goarches[@]} ; do
	goarchdir="${godir}-${goarch}"
	goarchive="${cwtmp}/${goarchdir}.tar"
	test -e go && rm -rf go
	test -e "${goarchdir}" && rm -rf "${goarchdir}"
	tar -zxf "${godldir}/${gofile}"
	mv go "${goarchdir}"
	pushd "${goarchdir}/src/"
	boxecho "patching crypto/x509/root_linux.go with cert locations"
	cat crypto/x509/root_linux.go > crypto/x509/root_linux.go.ORIG
	sed -i 's|"/etc/ssl/cert.pem"|"/etc/ssl/cert.pem","'"${cwtop}/etc/ssl/cert.pem"'"|g' crypto/x509/root_linux.go
	sed -i 's|"/etc/ssl/certs"|"/etc/ssl/certs","'"${cwtop}/etc/ssl/certs"'"|g' crypto/x509/root_linux.go
	"${cwbuild}/${godir}/bin/gofmt" -w crypto/x509/root_linux.go
	#diff -Naur crypto/x509/root_linux.go{.ORIG,} || true
	boxecho "building final go${gover} for ${goarch} in ${PWD}"
	env GO_LDFLAGS='-extldflags "-static -s" -s -w' CGO_ENABLED=0 GOROOT_BOOTSTRAP="${cwbuild}/${godir}" GOOS='linux' GOARCH="${goarch}" bash make.bash
	popd
	pushd "${goarchdir}"
	rm -rf pkg/obj/go-build
	rm -rf pkg/bootstrap
	if [[ ! ${goarch} =~ amd64 ]] ; then
		rm -rf pkg/tool/linux_amd64
		rm -rf pkg/linux_amd64
		rm -f bin/go{,fmt}
		mv bin/linux_${goarch}/* bin/
		rmdir bin/linux_${goarch}
	fi
	popd
	boxecho "successfully built go${gover} for ${goarch}"
	echo "archiving ${goarchdir} to ${goarchive}"
	tar -cf "${goarchive}" "${goarchdir}/"
	pushd "$(dirname ${goarchive})"
	echo "using xz to compress ${goarchive} in ${PWD}"
	rm -f "${goarchive}.xz"
	xz --threads=$(nproc) -e -v -v "${goarchive}"
	echo "storing SHA-256 sum to ${goarchive}.xz.sha256"
	sha256sum "$(basename ${goarchive}.xz)" > "${goarchive}.xz.sha256"
	popd
	echo
done
popd
echo
