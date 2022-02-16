FROM ubuntu

#Download relevant installers
RUN apt-get update 1>/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y unzip wget curl iproute2 less --fix-missing 1>/dev/null

# Install aws-iam-authenticator 
RUN wget --quiet https://amazon-eks.s3.us-west-2.amazonaws.com/1.21.2/2021-07-05/bin/linux/amd64/aws-iam-authenticator -O /usr/local/bin/aws-iam-authenticator \
&& chmod 755 /usr/local/bin/aws-iam-authenticator

# Install kubectl command line 
RUN wget --quiet https://dl.k8s.io/release/v1.22.1/bin/linux/amd64/kubectl -O /usr/local/bin/kubectl \
&& chmod 755 /usr/local/bin/kubectl

# Install AWS CLI
RUN wget --quiet https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -O /tmp/awscli-exe-linux-x86_64.zip \
&& unzip /tmp/awscli-exe-linux-x86_64.zip -d /tmp/ 1>/dev/null \
&& chmod +x /tmp/aws/install \
&& /tmp/aws/install \
&& chmod +x /usr/local/bin/aws \
&& rm -rf /tmp/aws \
&& apt-get purge unzip wget -y

COPY config/sbin/ /sbin/
RUN chmod u+x /sbin/entrypoint.sh && chmod u+x /sbin/multus-config.sh 

ENTRYPOINT [ "/sbin/entrypoint.sh" ]