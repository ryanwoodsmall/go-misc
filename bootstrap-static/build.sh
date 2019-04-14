#!/bin/bash

#
# build a static up-to-date go dist for a few platforms
#
# XXX - should this be "gobootstrap" for the the recipe name?
# XXX - enable strip with ldflags?
# XXX - turn off debugging?
# XXX - https://github.com/golang/go/issues/9344
# XXX - get the dang size down...
# XXX - -w in ldflags omits dwarf symbol table
# XXX - -s in ldflags omits symbol table and debug information
# XXX - enable cgo for final stage?
# XXX - bzip2 or xz this bad boy
# XXX - include _${TIMESTAMP} in directory/archive?
#

set -eu

sname="${BASH_SOURCE[0]}"

if [[ ! $(uname -m) =~ x86_64 ]] ; then
	echo "${sname}: please run on amd64 (for now)"
	exit 1
fi

# prerequisite programs
prereqs=( 'bzip2' 'curl' 'gcc' 'gzip' 'xz' )
for prereq in ${prereqs[@]} ; do
	if ! $(hash "${prereq}" >/dev/null 2>&1) ; then
		echo "${sname}: ${prereq} not found"
		exit 1
	fi
done
# curl options
copts="-k -L -O"

# bootstrap go version in C
gobsver="1.4-bootstrap-20171003"
gobsdir="go${gobsver}"
gobsfile="go${gobsver}.tar.gz"
gobsfilesha256="f4ff5b5eb3a3cae1c993723f3eab519c5bae18866b5e5f96fe1102f0cb5c3e52"
# go intermediate and final build verison
gover="1.12.2"
godir="go${gover}"
gofile="go${gover}.src.tar.gz"
gofilesha256="af992580a4a609309c734d46fd4374fe3095961263e609d9b017e2dffc3b7b58"
# download
gobaseurl="https://dl.google.com/go"
gobsurl="${gobaseurl}/${gobsfile}"
gourl="${gobaseurl}/${gofile}"
# architectures
goarches=( '386' 'amd64' 'arm' 'arm64' )

# crosware stuff - build bootstrap stages in tmp and install in software
cwtop="/usr/local/crosware"
cwbuild="${cwtop}/builds"
cwdl="${cwtop}/downloads"
cwtmp="${cwtop}/tmp"
cwsw="${cwtop}/software"
rtdir="${cwsw}/go"

# random
godldir="${cwdl}/go"
vartmp="/var/tmp"

# create build/install directories
mkdir -p "${cwbuild}"
mkdir -p "${cwtmp}"
mkdir -p "${rtdir}"
mkdir -p "${godldir}"
mkdir -p "${vartmp}"

# download
pushd "${godldir}"
for url in "${gobsurl}" "${gourl}" ; do
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
env GO_LDFLAGS='-extldflags "-static"' CGO_ENABLED=0 bash make.bash
popd
# stage 2: second stage bootstrap (go -> go)
test -e go && rm -rf go
test -e "${godir}" && rm -rf "${godir}"
tar -zxf "${godldir}/${gofile}"
mv go "${godir}"
pushd "${godir}/src"
env GO_LDFLAGS='-extldflags "-static"' CGO_ENABLED=0 GOROOT_BOOTSTRAP="${cwbuild}/${gobsdir}" bash make.bash
popd
popd

# final builds
pushd "${rtdir}"
for goarch in ${goarches[@]} ; do
	goarchdir="${godir}-${goarch}"
	test -e go && rm -rf go
	test -e "${goarchdir}" && rm -rf "${goarchdir}"
	tar -zxf "${godldir}/${gofile}"
	mv go "${goarchdir}"
	pushd "${goarchdir}/src/"
	env GO_LDFLAGS='-extldflags "-static"' CGO_ENABLED=0 GOROOT_BOOTSTRAP="${cwbuild}/${godir}" GOOS='linux' GOARCH="${goarch}" bash make.bash
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
	tar -zcf "${cwtmp}/${goarchdir}.tar.gz" "${goarchdir}/"
done
popd
