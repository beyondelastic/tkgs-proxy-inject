#!/bin/bash
set -e

source env.sh

nextip(){
    IP=$1
    IP_HEX=$(printf '%.2X%.2X%.2X%.2X\n' `echo $IP | sed -e 's/\./ /g'`)
    NEXT_IP_HEX=$(printf %.8X `echo $(( 0x$IP_HEX + 1 ))`)
    NEXT_IP=$(printf '%d.%d.%d.%d\n' `echo $NEXT_IP_HEX | sed -r 's/(..)/0x\1 /g'`)
    echo "$NEXT_IP"
}


export REG_CERT=$(echo "$REG_CERT" | base64 -w 0)

#get the cluster id
CLUSTER=$(dcli com vmware vcenter cluster list --names ${VSPHERE_CLUSTER} +formatter yaml | sed -n -e 's/^.*cluster: //p')
NETWORK=$(dcli com vmware vcenter namespacemanagement clusters get --cluster ${CLUSTER} | sed -n -e 's/^.*network_provider: //p' | tail -n1)
#get all supervisor ips, there may be a better way?
echo "getting supervisor vm creds"

/usr/lib/vmware-wcp/decryptK8Pwd.py > ./sv-info

cat ./sv-info | grep ${CLUSTER} -A2 > ./${CLUSTER}-info

sv_ip=$(cat ./${CLUSTER}-info | sed -n -e 's/^.*IP: //p')
sv_pass=$(cat ./${CLUSTER}-info| sed -n -e 's/^.*PWD: //p')

#loop over each sv and upload the image tar
set +e

NUM=5
ip=${sv_ip}
for i in $(seq 1 $NUM);
do
echo "copying image tar to ${ip}"
sshpass -p "${sv_pass}" scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ./proxy-inject.tar.gz root@"${ip}":./proxy-inject.tar.gz >> /dev/null
if [ $? -eq 0 ] ;
then      
      echo "copied image tar successfully"
else
      echo "error copying image tar to supervisor node ${ip}"
      exit 2
fi
echo "importing image into local registry"
sshpass -p "${sv_pass}" ssh -t -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  root@"${ip}"  << EOF
docker load -i proxy-inject.tar.gz
docker tag proxy-inject:1.2.0 localhost:5002/vmware/proxy-inject:1.2.0
docker push localhost:5002/vmware/proxy-inject:1.2.0
EOF
if [ $? -eq 0 ] ;
then      
      echo "image loaded successfully"
else
      echo "error loading image into to supervisor node ${ip}"
      exit 2
fi
echo "cleanup image tar"
sshpass -p "${sv_pass}" ssh -t -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  root@"${ip}"  << EOF
rm ./proxy-inject.tar.gz
EOF
ip=$(nextip $ip)
done

manifest=./manifest-nsxt.yml
if [ "${NETWORK}" = "VSPHERE_NETWORK" ];
then
echo "using VDS networking"
manifest=./manifest-vds.yml
fi

echo "injecting environment vars into manifest file"
envsubst < ${manifest} > newman.yml

echo "copying manifest file to supervisor node ${sv_ip}"
sshpass -p "${sv_pass}" scp -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ./newman.yml root@"${sv_ip}":./manifest.yml >> /dev/null
if [ $? -eq 0 ] ;
then      
      echo "manifest copied sucessfully"
else
      echo "error copying manifest into to supervisor node ${ip}"
      exit 2
fi



echo "creating k8s deployment in namespace ${DEPLOY_NS}"
sshpass -p "${sv_pass}" ssh -t -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  root@"${sv_ip}"  << EOF
kubectl apply -f manifest.yml
EOF
if [ $? -eq 0 ] ;
then      
      echo "manifest applied successfully"
else
      echo "error applying manifest"
      exit 2
fi
