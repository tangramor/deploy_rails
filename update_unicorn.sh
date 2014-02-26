#! /bin/bash
# make sure to create your ssh key without password by using ssh-keygen
# and append your ~/.ssh/id_rsa.pub content on your local machine to 
# /www-data/.ssh/authorized_keys on remote servers (www-data is the user  
# to execute unicorn)
SERVER_IPS=(192.168.1.61 192.168.1.62)
SERVER_USERS=(www-data www-data)
RUBY_VERSION=2.0.0
RVM_PROFILE="/etc/profile.d/rvm.sh"

i=0
while [ $i -lt ${#SERVER_IPS[@]} ]
do
    echo ${SERVER_IPS[$i]}':'
    ssh -t ${SERVER_USERS[$i]}@${SERVER_IPS[$i]} "source $RVM_PROFILE && rvm use $RUBY_VERSION >/dev/null 2>/dev/null && /etc/init.d/unicorn update"
    let i++
done
