#!/bin/bash

# Corporate Firewall Certificate Importer
#
# Questions/Improvements: https://github.com/hmknapp/cfci/issues
#
# Gets certificates from common hosts and installs them in the system
# usage: ./cfci.sh [<host1> <host2> <host3> ...]

DEFAULT_HOSTS="
  mirror-master.debian.org\
  mirrors.rockylinux.org\
  nodejs.org\
  dl.yarnpkg.com\
  deb.nodesource.com\
  rpm.nodesource.com\
  registry.npmjs.org\
  registry-1.docker.io\
  auth.docker.io\
  apt.postgresql.org\
  apt-archive.postgresql.org\
  yum.postgresql.org\
  yum-archive.postgresql.org\
  www.postgresql.org\
  repo.mysql.com\
  packagist.org\
  repo1.maven.org\
  repo.maven.apache.org\
  repo.msys2.org\
  git-scm.com
"

# check for requirements
commands=(openssl csplit md5sum)
for cmd in "${commands[@]}"; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "Error: ${cmd} is not installed."
    exit 1
  fi
done

SUDOCMD=$(which sudo 2> /dev/null)
# if sudo does not exist check if superuser else exit (unless MinGW)
if ! command -v ${SUDOCMD} &> /dev/null; then
  SUDOCMD=""
  if [[ $(id -u) -ne 0 && -z ${MINGW_PREFIX} ]]; then
    echo "Error: this script requires root privileges."
    exit 1
  fi
fi

if [ $# -eq 0 ]; then
    HOSTS=${DEFAULT_HOSTS}
else
    HOSTS=$@
fi

tmpdir=$(mktemp -d)

for host in ${HOSTS}
do
  # get certificate
  echo -n "Getting certificates for ${host} "

  if [ -n "${HTTP_PROXY}" ]; then
    http_proxy=${HTTP_PROXY}
  fi

  # we need retries for some hosts for some reason sometimes :)
  _RETRIES=0
  _MAX_RETRIES=20
  _EXITCODE=1

  while [[ ${_RETRIES} -lt ${_MAX_RETRIES} ]];
  do
    # use http_proxy from env if available
    if [ -n "${HTTP_PROXY}" ]; then
      timeout 5 openssl s_client -showcerts -servername "${host}" -connect "${host}":443 -proxy ${http_proxy#http://} </dev/null 2>/dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${tmpdir}/${host}.crt"
    else
      timeout 5 openssl s_client -showcerts -servername "${host}" -connect "${host}":443 </dev/null 2>/dev/null | sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "${tmpdir}/${host}.crt"
    fi
    _EXITCODE=${PIPESTATUS[0]}
    [[ ${_EXITCODE} == 0 ]] && break
    _RETRIES=$((_RETRIES+1))
    echo -n .
    sleep 2
  done

  if [[ ${_EXITCODE} -eq 0 ]]; then
   echo " OK"
  else
   echo " Failed"
   rm "${tmpdir}/${host}.crt"
   continue
  fi
done

(
  cd ${tmpdir}
  for cert in *.crt; do
    csplit -f rh_ -b "%02d.crt" -z "${cert}" "/^-----BEGIN CERTIFICATE-----$/" "{*}" &>/dev/null
  done
  echo "Removing duplicate certificates"
  for cert in *.crt; do
    mv ${cert} $(md5sum "${cert}" | cut -d' ' -f1).crt
  done
)

echo -n "Installing certificates ..."

#Rocky/RHEL/Fedora, etc (or MinGW Windows)
if command -v update-ca-trust &> /dev/null; then
  if [[ -n ${MINGW_PREFIX} ]]; then
    cat "${tmpdir}"/*.crt >> "${MINGW_PREFIX}/ssl/certs"/ca-bundle.crt
  else
    ${SUDOCMD} cp "${tmpdir}"/*.crt /etc/pki/ca-trust/source/anchors
  fi
  ${SUDOCMD} update-ca-trust
fi

if command -v update-ca-certificates &> /dev/null; then
  ${SUDOCMD} cp "${tmpdir}"/*.crt /usr/local/share/ca-certificates/
  ${SUDOCMD} update-ca-certificates --fresh
fi
[[ $? -eq 0 ]] && echo " OK" || echo " Failed"

rm -rf "${tmpdir}"

echo "Done."
