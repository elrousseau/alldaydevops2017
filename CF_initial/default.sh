#!/bin/bash
#
# NOTE: this is a ruby template.
#
# The bootstrap log can be found at /var/log/cloud-init.log.

# We want to get traced output in logs and don't want to use undeclared
# variables.

set -o nounset -o xtrace

# We can't send /var/log/cloud-init.log (output is buffered and we cant get full
# log). This command will duplicate log file so we can upload it to S3 and see
# it in Jenkins.
exec > >(tee /tmp/cloud-init.log) 2>&1

CFN_WAIT_HANDLE='{{ ref('WaitConditionHandle') }}'
APP_NAME='{{ ENV['APP_NAME'] }}'
BUILD_ID='{{ ENV['BUILD_ID'] }}'
STACK_NAME='{{ ENV['STACK_NAME'] }}'
BUILD_CONFNAME='{{ ENV['JOB_NAME'].gsub(/[^a-zA-Z0-9]/,'_') }}'
INSTANCE_ID=`wget -q -O- http://169.254.169.254/latest/meta-data/instance-id`
INSTANCE_TYPE='{{ ref('InstanceType') }}'
ENVIRONMENT='{{ ref('Environment') }}'
HOSTNAME=${STACK_NAME}-${INSTANCE_ID}
ADDITIONAL_FACTS='{{ ENV['ADDITIONAL_FACTS'] }}'

function upload_log() {
  # Sending log to s3 bucket. It will be downloaded by instance_info.rb and
  # written to the Jenkins console.
  aws s3 cp /tmp/cloud-init.log s3://cfwdev-deployment/logs/${INSTANCE_ID}.log
  rm -f /tmp/cloud-init.log
}

function error() {
  # Function to exit correctly
  local PARENT_LINENO="$1"
  local MESSAGE="${2:-}"
  local CODE="${3:-1}"
  local ERROR_MESSAGE="Error on or near line ${PARENT_LINENO}${2:+: }${MESSAGE:-}; exiting with status ${CODE}"
  echo "$ERROR_MESSAGE"
  upload_log

  # This is an AWS API call that reports back to the newly created
  # cloudformation stack that this instance was NOT created successfully.
  /opt/aws/bin/cfn-signal -e "${CODE}" -r "${ERROR_MESSAGE}" "${CFN_WAIT_HANDLE}"
  exit ${CODE}
}

# We will exit if some command exit with not zero code.
trap 'error ${LINENO}' ERR

#Remove yum start.
rm -rf /etc/update-motd.d/70-available-updates

# Set permanent hostname
hostname ${HOSTNAME}
sed -i "s/HOSTNAME=.*/HOSTNAME=$HOSTNAME/" /etc/sysconfig/network
echo "127.0.0.1 $HOSTNAME" > /etc/hosts

# Creating custom facts (variable for puppet).
# This files will be loaded with facter_dot_d.rb fact from stdlib.
mkdir -p  /etc/facter/facts.d/
cat > /etc/facter/facts.d/facts.txt <<EOF
build_id=${BUILD_ID}
build_confname=${BUILD_CONFNAME}
instance_id=${INSTANCE_ID}
instance_environment=${ENVIRONMENT}
instance_type=${INSTANCE_TYPE}
stack_name=${STACK_NAME}
app_name=${APP_NAME}
$ADDITIONAL_FACTS
EOF

#Intall s3iam yum plugin to provide support of s3 based yum repo.
wget https://s3.amazonaws.com/cf-deployment/repo/s3iam.py -O /usr/lib/yum-plugins/s3iam.py -q
cat > /etc/yum/pluginconf.d/s3iam.conf <<EOF
[main]
enabled=1
EOF

#Installing our private repo
cat > /etc/yum.repos.d/cureforward.repo <<EOF
[book2meet]
name=book2meet
baseurl=http://cf-deployment.s3.amazonaws.com/repo/${ENVIRONMENT}/
failovermethod=priority
enabled=1
priority=5
gpgcheck=0
s3_enabled=1
EOF

# Disable builtin amzon repos. We want to use only our freazed repo.
sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/amzn-main.repo
sed -i 's/enabled=1/enabled=0/g' /etc/yum.repos.d/amzn-updates.repo



# Install puppet.
yum install puppet3 -y
mkdir -p /etc/puppet


# Downloading puppet manifests. This uses aws-cli so will work inside or outside
# EC2 provided credentials are present.
aws s3 cp s3://cf-deployment/puppet/${STACK_NAME}.tar.gz /tmp/puppet.tar.gz
tar -xzf /tmp/puppet.tar.gz -C /etc/puppet/
rm -rf /tmp/puppet.tar.gz

# Disable trap before puppet run. Puppet extended exit codes are not equal to 0 if success.
trap - ERR

# This is for parsing puppet log.
echo
echo -----Puppet log start here-----
puppet apply --verbose --detailed-exitcodes --color true /etc/puppet/manifests/${APP_NAME}.pp
EXIT_CODE=$?
echo -----End of puppet log-----

# Restore trap.
trap 'error ${LINENO}' ERR

# Handle puppet errors.
[ "$EXIT_CODE" -eq 0 -o "$EXIT_CODE" -eq 2 ] || {
  error ${LINENO} "Error while puppet execution."
}

upload_log
/opt/aws/bin/cfn-signal -r 'Server started' "${CFN_WAIT_HANDLE}"
