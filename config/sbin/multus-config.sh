#!/bin/bash

#Please see the repo readme here for more info, as this is quite a complicated concept, and best described elsewhere


# A script that will always poll a node's avaliability zone to see if there are any unassigned multus interfaces
# (such as if a new cluster is spun up, or if a new host is added to an existing cluster). If an unattached
# interface is found in the AZ our host is in, we attach it. 

#this is a very neat (if I do say so myself) bit of code that allows us to pull per-cluster config from the nodes
#and then populate a templated kubeconfig file. It makes this code totally standalone, and doesn't need cluster variables passing in

#this IP that is always localhost can return the following metadata
region=$(curl --silent http://169.254.169.254/latest/meta-data/placement/availability-zone) 
region=${region::-1} # remove the last char of the AZ to get the region
instance_node_name=$(curl --silent http://169.254.169.254/latest/meta-data/hostname).$region.compute.internal
availability_zone=$(curl --silent http://169.254.169.254/latest/meta-data/placement/availability-zone) #in 'eu-west-2a' format
instance_id=$(curl --silent http://169.254.169.254/latest/meta-data/instance-id) #as an 'id'

mkdir .kube
cluster_ca_cert=$(curl --silent http://169.254.169.254/latest/user-data | awk '{print $0 '\n'}' | grep B64_CLUSTER_CA=) # tried to use cut -d '=' here, but the cert can contain (or end with) `=`, so this broke it...
cluster_ca_cert="${cluster_ca_cert:15}"
cluster_api_server=$(curl --silent http://169.254.169.254/latest/user-data | awk '{print $0 '\n'}' | grep API_SERVER_URL= | cut -d '=' -f 2)
cluster_name=$(curl --silent http://169.254.169.254/latest/user-data | awk '{print $0 '\n'}' | grep bootstrap.sh | cut -d ' ' -f 2)

#take those values from above, and populate them into this config template
cat > .kube/config << EOF
apiVersion: v1
preferences: {}
kind: Config
clusters:
- cluster:
    server: $cluster_api_server
    certificate-authority-data: $cluster_ca_cert
  name: eks_cluster_$cluster_name
contexts:
- context:
    cluster: eks_cluster_$cluster_name
    user: user_$cluster_name
  name: eks_cluster_$cluster_name
current-context: eks_cluster_$cluster_name
users:
- name: user_$cluster_name
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "$cluster_name"
EOF

export KUBECONFIG=.kube/config


#a 'forever' loop
while [ 1 -lt 2 ]
do
    
    # Get the network interface for the current AZ that is tagged as for 'multus'. For now, just return the status as that's all we need
    interface_attachment_status=$(aws ec2 describe-network-interfaces --filters Name=tag:cluster,Values=$cluster_name Name=tag:multus,Values=true Name=tag:Zone,Values=$availability_zone --query NetworkInterfaces[0].Status --output text)
    printf "$(date):Found interface in $availability_zone with tag multus, and status of $interface_attachment_status\n"
    #status will be 'in-use' || 'available'

    if [[ $interface_attachment_status = "available" ]]; then # if it's attached, it reports 'in-use'

        printf "$(date):Interface is available, proceeding to attach to a host...\n"

        #time to attach the network interface for multus to our node object
        interface_to_attach=$(aws ec2 describe-network-interfaces --filters Name=tag:cluster,Values=$cluster_name Name=tag:multus,Values=true Name=tag:Zone,Values=$availability_zone --query NetworkInterfaces[*].NetworkInterfaceId --output text)
        printf "$(date):Found an interface in $availability_zone with ID $interface_to_attach. Attempting to attach to $instance_id...\n\n"
        aws ec2 attach-network-interface \
        --network-interface-id $interface_to_attach \
        --instance-id $instance_id \
        --device-index 2

        aws ec2 create-tags --resources $instance_id --tags Key=multus-network-attached,Value=true
        kubectl label nodes $instance_node_name cluster.custom.tags/multus-attached=true --overwrite #used for stateful set host placements
        #This will just return the MAC address of the interface, as found, based on:
        # interfaces attached to $this host, with 'multus' in the description
        interface_mac_address=$(aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$instance_id" "Name=description,Values=Multus*" --query NetworkInterfaces[*].MacAddress --output text)  
        #Now we have the MAC, we need to link that to the NIC on the node itself, so we can add the alias.
        #The alias so that the flux code can use a network name of 'multus' rather than having to be dynamic or different interfaces/eths
        interface_to_rename=$(ip -o link | grep $interface_mac_address | cut --delimiter ':' -f 2 | cut --delimiter ' ' -f 2)
        ip link set $interface_to_rename name multus #add a alias to make attached eth be called 'multus'

        printf "$(date):Interface was attached to $interface_to_rename, which has been renamed as 'multus':\n\n"
        printf "$(date):$(ip link show $interface_to_rename)\n"

    fi  
    
    # Following a reboot, or the deletion of the consumming pod, the interface will leave the namespace where it was in use
    # (such as a squid-proxy-az namespace), and will return to the host, ready to be reused. In this case, we just need to rename the interface
    # so that it's picked up by a network-attachment-definition, which will happen automatically
    if [[ $interface_attachment_status = "in-use" ]]; then #now we know it's in-use, we need to check if it's still on this host. If so, rename it for the network-deifition to pick up

        interface_mac_address=$(aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$instance_id" "Name=description,Values=Multus*" --query NetworkInterfaces[*].MacAddress --output text)  
        ip -o link | grep $interface_mac_address | grep -q -v multus
        #look to see if the MAC is on this host, and if it is, only proceed if the interface isn't renamed already...
        #the logic here in that, you can have an interface attached and renamed, but if it's not being used by a pod it will stay on the host and cause the 'following an event' section
        #of code to run. This way, we only run that code if it's not been renamed already

        if [ $? = 0 ]; then #now we know that the ENI is still on this host with the incorrect name, so rename it
        
            printf "$(date): Following an event (likely an instance reboot) the interface is now attached, but needs to be renamed. Renaming to multus now:"
            interface_to_rename=$(ip -o link | grep $interface_mac_address | cut --delimiter ':' -f 2 | cut --delimiter ' ' -f 2)
            ip link set $interface_to_rename name multus #add a alias to make attached eth be called 'multus'
            kubectl label nodes $instance_node_name cluster.custom.tags/multus-attached=true --overwrite #used for stateful set host placements

            printf "$(date):Interface was attached to $interface_to_rename, which has been renamed as 'multus':\n\n"
            printf "$(date):$(ip link show $interface_to_rename)\n"
        
        fi
    fi

    # If the MAC address of the multus ENI is NOT present on the current node, remove the mutlus-attached label/tag. Below output shows that the MAC is not
    # removed from the meta-data of the instance, even if it doesn't show up in 'ip' commands
    # aws ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=$instance_id" "Name=description,Values=Multus*" --query NetworkInterfaces[*].MacAddress --output text &&  curl --silent curl http://169.254.169.254/latest/meta-data/network/interfaces/macs
    #06:cd:12:53:8c:ae
    #06:08:d2:e6:e8:8e/ 
    #06:cd:12:53:8c:ae/
    
    curl --silent http://169.254.169.254/latest/meta-data/network/interfaces/macs | grep -q $interface_mac_address 
    #get the macs on this instance, then search to see if the multus mac is present. If not, remove the tag
    if [ $? != 0 ]; then
        #now check if it has the label, otherwise we'll end up spamming the log files...
        kubectl get nodes $instance_node_name --show-labels | grep -q multus-attached=true
        if [ $? = 0 ]; then 
            printf "$(date): removing the cluster.custom.tags/multus-attached label from $instance_id (AKA $instance_node_name) as it does not have the multus ENI assigned to it any more\n"
            kubectl label nodes $instance_node_name cluster.custom.tags/multus-attached- --overwrite #used for stateful set host placements
        fi
    fi

    printf "$(date): Interface is currently attached or in-use with the correct name - waiting for 10 minutes to poll again...\n\n"
    sleep 600s

done
