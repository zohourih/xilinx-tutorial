#!/bin/bash

my_error(){
    echo
    printf "ERROR: $1"
    echo 
    exit -1
}

OPTIND=1
jarvice_user=""
jarvice_apikey=""
while getopts "u:k:" opt; do
    case "$opt" in
        u)
            jarvice_user=$OPTARG
            ;;
        k)
            jarvice_apikey=$OPTARG
            ;;
    esac
done

[[ -z ${jarvice_user} ]] && my_error "JARVICE user not set"
[[ -z ${jarvice_apikey} ]] && my_error "JARVICE apikey not set"
workdir=$(mktemp -d)
retdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
cd ${workdir}

cat <<- EOF > ${workdir}/job.json
{
  "app": "xilinx-sdx_dev_2018_2_xdf",
  "staging": false,
  "checkedout": false,
  "application": {
    "command": "server",
    "geometry": "1904x943"
  },
  "machine": {
    "type": "n2",
    "nodes": 1
  },
  "vault": {
    "name": "drop.jarvice.com",
    "readonly": false,
    "force": false
  },
  "user": {
    "username": "${jarvice_user}",
    "apikey": "${jarvice_apikey}"
  }
}
EOF

jarvice_api="https://api.jarvice.com/jarvice"
rest_options="-H \"Content-Type: application/json\"" 
rest_options+="-X POST -d @${workdir}/job.json"
job=$(curl ${rest_options} "${jarvice_api}/submit" 2> /dev/null | jq -r .number)
echo Started JARVICE job: $job

rest_options="-H \"Content-Type: application/json\" -X GET"
rest_options+=" ${jarvice_api}/status?username=${jarvice_user}"
rest_options+="&apikey=${jarvice_apikey}&number=${job}"
while true; do
    status=$(curl ${rest_options} 2> /dev/null | jq -r .[].job_status)
    if [ "${status}" = "PROCESSING STARTING" ]; then
        break
    fi    
    sleep 15
done
sleep 5
rest_options="-H \"Content-Type: application/json\" -X GET"
rest_options+=" ${jarvice_api}/connect?username=${jarvice_user}"
rest_options+="&apikey=${jarvice_apikey}&number=${job}"
connect=$(curl ${rest_options} 2> /dev/null)
address=$(echo ${connect} | jq -r .address)
password=$(echo ${connect} | jq -r .password)

DSA="xilinx_u200_xdma_201820_1"
repo_path="SDAccel_Examples/getting_started/misc"
kernels="vadd vdotprod"
cat <<- 'EOF' > ${workdir}/run.sh
my_error(){
    printf "ERROR: $1"
    exit -1
}
set -e
OPTIND=1
DSA=""
repo_path=""
kernels=""
while getopts "d:r:k:" opt; do
    case "$opt" in
        d)
            DSA=$OPTARG
            ;;
        r)  
            repo_path=$OPTARG
            ;;
        k)
            kernels=$OPTARG
            ;;
    esac
done
[[ -z $DSA ]] && my_error "DSA not set\n"
[[ -z $repo_path ]] && my_error "repo_path not set\n"
[[ -z ${kernels} ]] && my_error "kernels not set\n"
retdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
workdir=$(mktemp -d)
cd ${workdir}
git clone --depth 1 https://github.com/Xilinx/SDAccel_Examples
source /opt/xilinx/xilinx-setup.sh
for kernel in ${kernels}; do
    make -C ${repo_path}/${kernel} DEVICES=${DSA} TARGETS=sw_emu
    cp ${repo_path}/${kernel}/xclbin/*.xclbin ${retdir}
    cp ${repo_path}/${kernel}/${kernel} ${retdir}
done
rm -rf ${workdir}
EOF
ssh_options="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
ssh-keygen -f ${workdir}/id_rsa -N "" 2>&1 > /dev/null
ssh_cmd="mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
echo "Enter this password at prompt: ${password}"
cat ${workdir}/id_rsa.pub | ssh ${ssh_options} nimbix@${address} ${ssh_cmd}

ssh_options+=" -i ${workdir}/id_rsa"
ssh_cmd="cat > /tmp/run.sh && chmod +x /tmp/run.sh;" 
ssh_cmd+="/tmp/run.sh -d ${DSA} -r ${repo_path} -k \"${kernels}\""
cat ${workdir}/run.sh | ssh ${ssh_options} nimbix@${address} ${ssh_cmd} 

scp_options="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
scp_options+=" -i ${workdir}/id_rsa"
scp ${scp_options} nimbix@${address}:/tmp/*.xclbin ${retdir} 
for kernel in ${kernels}; do
    scp ${scp_options} nimbix@${address}:/tmp/${kernel} ${retdir}
done

rest_options="-H \"Content-Type: application/json\" -X GET"
rest_options+=" ${jarvice_api}/shutdown?username=${jarvice_user}"
rest_options+="&apikey=${jarvice_apikey}&number=${job}"
curl ${rest_options} 2> /dev/null

rm -rf ${workdir}