## Design logic and container purpose

In a nutshell (more detail to come, don't worry!) multus is a plugin that allows you to attach one or more extra NICs to a pod. In order for that to work, extra NIC(s) must be backed by a coresponding 'phyiscal' network on the node(s) in question. This `daemonSet` (DS) does is the link between the creation of those 'phyiscal' networks, and connecting them to an EKS node, so they're ready for use.

There are three moving parts that this DS is concerned with, as outlined in Table A below.

_Table A:_

Type   | Description | Link to DS
-------|-------------|-----------
`Tag`  | A metadata object of type key/value pair| Allows the DS to know which avaliablity zone (AZ) a `node` is in. Grants a tag that K8s uses to schedule pods to a `node` with the multus `ENI` attached
`Node` | A compute object within the EKS cluster. If you were referring to the old HyperV estate, you'd call this a `host`| Within an AZ, there will only be one multus `ENI` (even if there are many `nodes`). The DS will link that `ENI` to one `node` with a tag matching the `ENI`'s avaliability zone
`ENI`  | Elastic Network Interface. AKA the 'phyiscal' network adatptor that is attached to a `node`. This is created outside of multus (in our case, via the cluster creation TerraForm)| The DS will attach this to a `node` with the relevant `tags`

Table B outlines the relationship between an AZ, an `ENI` and `nodes`.

Each AZ will have an `ENI`.
That `ENI` can be bound to one `node` within the AZ.
That `node` is chosen at 'random'.
If there is no `node` in an AZ, the `ENI` is unused.

_Table B_

AZ  |Nodes|ENI|ENI binding
----|-----|---|---
AZ-A| Node-1 Node-2       |Multus-ENI-A | Bound to Node-2
AZ-B|                     |Multus-ENI-B | Unbound
AZ-C| Node-3 Node-4 Node-5|Multus-ENI-C | Bound to Node-4


## Wait, didn't AWS already do this?

Yes. But it's not very good. Next question?

In all seriousness, you can look at the AWS documentation here, and it does provide useful background about how to install it into a cluster (there are extra steps not covered in this repo), but the AWS solution doesn't scale for multiple AZs, among other problems.

https://github.com/aws-samples/cfn-nodegroup-for-multus-cni
https://github.com/aws-samples/eks-install-guide-for-multus

### What is mutlus?

Mutlus is a plugin for K8s (and recently (as of Oct' 2021)) adopted for use with EKS that allows you to attach one or more additional network interfaces to a pod. Examples where you might use this are:

- an SBC, where you have an internal and external interface
- a device that needs a static IP address for firewall rules (such as an outbound proxy).

### How does it work?

Multus works by defining a logical network within a K8s cluster (the `Network Attachment Definition` (`NAD`) that is covered later) along with some controller pods within a cluster.

Once a pod is configured to use the `NAD`, multus will assign it an IP matching the rules within the `NAD` (i.e., the relevant subnets, IP ranges etc).

## What does this repo do?

In order for the above to work, the `ENI` (as outlined in _Table A_) must be attached to a `node` in the correct AZ (as shown in _Table B_). The task of the DS within this repo is to make that attachment between `node` and `ENI`. 

To that objective, the DS will:

- poll to see if there is an `avaliable` `ENI` within an AZ
- if one is found that is `avaliable`, then the `ENI` is bound to the `node` on which the DS pod is running
- next, the EC2 instance (`node` is tagged as having `multus-network-attached: true` (so that K8s knows this `node` is suitable for scheduling pods needing the multus network)
- then the K8s `node` is tagged with `cluster.custom.tags/multus-attached=true` 
- the NIC on the `node` (not the same as the `ENI`, which is the AWS object - this is the device shown by the `ip` command) is renamed from something like `eth0` to `multus`. (This is because the `NAD` needs to reference an interface by name, and using something like `eth*` isn't predictable.


## What is needed in the cluster

While the creation of these objects is outside the scope of this readme, for multus to work the following are needed to be defined at a cluster level:

- one `ENI` per AZ with a suitable subnet
- tags for each `ENI` to define: multus:true/false & Tier: Private/Intra.

## What is needed in flux repo

There are components needed within the flux repo - some - like the multus controllers are defined using templated files from AWS (linked above), and some, like the `NAD` we define per-cluster. We will look into those that we define, now.

### Network Attachement Definitions (NAD)

A `NAD` is defined at a cluster level. 

Below is a sample `NAD`. Within it, you can see a few things mentioned earlier:
- the `"device": "multus"` string. Remember, one of the roles of the DS is to rename the interface from `eth*` to `multus`
- the `subnet` details, which need to match those defined in the VPC
- the AZ (appended to the end of the `name`) - this needs to match the AZ/subnet mapping as defined in the repo file one line above.

```
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: squid-proxy-multus-network-definition-az-a
  namespace: squid-proxy-multi-az
spec:
  config: '{
      "cniVersion": "0.3.0",
      "plugins": [
        {
          "type": "host-device",
          "device": "multus",
          "ipam": {
            "type": "host-local",
            "subnet": "10.231.4.0/29",
            "rangeStart": "10.231.4.4",
            "rangeEnd": "10.231.4.4",
            "gateway": "10.231.4.1"
          }
        },
        {
          "type": "sbr"
        }
      ]
    }'
```

### Link a pod to a NAD

Once we have a `NAD` and a pod, we need to link them which is done using the following syntax:

Notice:
- the `nodeSelector` defines a strict AZ
- the `multus-attached` node tag must be `true` (as outlined above)
- the `NAD` is referenced, making sure that the `NAD` and the AZ are in sync

```
    nodeSelector: 
      topology.kubernetes.io/zone: eu-west-2a
      cluster.custom.tags/multus-attached: "true"
    podAnnotations:
      k8s.v1.cni.cncf.io/networks: '[{
        "name": "squid-proxy-multus-network-definition-az-a"
      }]'
```

# Summary

To summise:

- multus allows for 1+ extra networks for a pod
- that network is backed by an `ENI`
- that `ENI` can only be attached to one `node` at a time
- pods wanting to use the multus network must be scheduled to run on the `node` attached to the `ENI`
- within K8s, a `NAD` is needed to define the properties of the multus network
- a pod is only scheduled to a `node` if it is tagged as in the correct AZ, and the `multus-attached` tag is `true`
